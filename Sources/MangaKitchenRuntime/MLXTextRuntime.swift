import Foundation
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import MangaKitchenCore
import Tokenizers

/// 本機 Hugging Face MLX 純文字模型 runtime。目前先提供模型載入與文字生成
/// 能力，翻譯管線將在另一步透過 `TextGenerating` 接入。
actor MLXTextRuntime: TextGenerating {
    let info: LoadedModelInfo

    private let modelDirectory: URL
    private let generation: ModelManifest.Generation
    private let thinkingEnabled: Bool
    private let log: RuntimeLogHandler
    private let reasoningStream: RuntimeReasoningStreamHandler
    private var container: ModelContainer?

    init(
        directoryURL: URL,
        manifest: ModelManifest,
        thinkingEnabled: Bool = false,
        log: @escaping RuntimeLogHandler = { _, _, _ in },
        reasoningStream: @escaping RuntimeReasoningStreamHandler = { _ in }
    ) throws {
        guard manifest.backend == .mlxSwift else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .textToText else {
            throw ModelRuntimeError.unsupportedBackendCapability(
                .mlxSwift,
                manifest.capability
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ModelRuntimeError.modelFileNotFound(directoryURL)
        }

        modelDirectory = directoryURL
        generation = manifest.generation ?? ModelManifest.Generation()
        self.thinkingEnabled = thinkingEnabled
        self.log = log
        self.reasoningStream = reasoningStream
        info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
    }

    func prepare(progress: @escaping InferenceProgress) async throws {
        _ = try await loadContainer(progress: progress)
    }

    func generateText(
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ModelRuntimeError.featureNotFound("text-to-text prompt")
        }
        let reasoningID = thinkingEnabled ? UUID() : nil
        var reasoningDidFinish = false
        if let reasoningID {
            reasoningStream(.started(id: reasoningID))
        }
        defer {
            if let reasoningID, !reasoningDidFinish {
                reasoningStream(.finished(id: reasoningID))
            }
        }

        progress(0.01)
        log(
            .info,
            "Text Model",
            "Starting \(info.displayName) generation; prompt=\(trimmedPrompt.count) characters, thinking=\(thinkingEnabled ? "enabled" : "disabled")."
        )
        let container = try await loadContainer(progress: progress)
        try Task.checkCancellation()
        progress(0.48)
        // Qwen3 系列的 chat template 在未指定時預設開啟 thinking。結構化翻譯不需要
        // 思考內容，且模型可能把整個 token 額度耗在 <think> 而沒有輸出 JSON；
        // 使用者啟用時也只要求輕度思考。
        let input = UserInput(
            chat: [.user(trimmedPrompt)],
            additionalContext: [
                "enable_thinking": thinkingEnabled,
                "reasoning_effort": "low"
            ]
        )
        let prepared = try await container.prepare(input: input)
        progress(0.55)

        let configuredTokenLimit = min(max(generation.maxTokens, 128), 8_192)
        let requestedMaxTokens = maximumOutputTokens.map {
            min($0, configuredTokenLimit)
        } ?? configuredTokenLimit
        // Thinking 第一段固定為短額度；完整 JSON 的額度留給後續
        // non-thinking finalization，避免 reasoning 占滿整個翻譯輸出上限。
        let maxTokens = thinkingEnabled
            ? min(512, configuredTokenLimit)
            : max(requestedMaxTokens, 128)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: min(max(generation.temperature, 0), 2),
            topP: min(max(generation.topP, 0.05), 1),
            repetitionPenalty: max(generation.repetitionPenalty, 1),
            repetitionContextSize: 128
        )
        let stream = try await container.generate(input: prepared, parameters: parameters)
        let expectedChunks = min(maxTokens, 512)
        var output = ""
        var chunks = 0
        var lastRepetitionCheck = 0
        var stoppedOnRepetition = false
        for await event in stream {
            try Task.checkCancellation()
            guard case let .chunk(text) = event else { continue }
            output += text
            if let reasoningID {
                reasoningStream(.updated(
                    id: reasoningID,
                    text: VLMStructuredResponseDecoder.streamedReasoningText(from: output)
                ))
            }
            chunks += 1
            progress(min(0.99, 0.55 + Double(chunks) / Double(expectedChunks) * 0.44))
            if chunks - lastRepetitionCheck >= 32, output.count > 400 {
                lastRepetitionCheck = chunks
                if Self.isRepeatingTail(output) {
                    stoppedOnRepetition = true
                    break
                }
            }
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if stoppedOnRepetition {
            output = Self.repairedTruncatedArray(output)
            log(.warning, "Text Model", "Stopped a repeating output loop and repaired the JSON tail.")
        }
        if let reasoningID {
            reasoningStream(.finished(id: reasoningID))
            reasoningDidFinish = true
        }
        if thinkingEnabled,
           !VLMStructuredResponseDecoder.hasCompleteStructuredFinalAnswer(output) {
            log(
                .warning,
                "Text Model",
                "Thinking ended without complete JSON; finalizing with the same loaded model and thinking disabled."
            )
            let finalInput = UserInput(
                chat: [
                    .user(VLMStructuredResponseDecoder.nonThinkingFinalizationPrompt(
                        originalPrompt: trimmedPrompt,
                        reasoningResponse: output
                    ))
                ],
                additionalContext: ["enable_thinking": false]
            )
            let finalPrepared = try await container.prepare(input: finalInput)
            let finalParameters = GenerateParameters(
                maxTokens: max(requestedMaxTokens, min(512, configuredTokenLimit)),
                temperature: 0,
                topP: 1,
                repetitionPenalty: max(generation.repetitionPenalty, 1),
                repetitionContextSize: 128
            )
            let finalStream = try await container.generate(
                input: finalPrepared,
                parameters: finalParameters
            )
            var finalOutput = ""
            for await event in finalStream {
                try Task.checkCancellation()
                guard case let .chunk(text) = event else { continue }
                finalOutput += text
                progress(0.99)
            }
            output = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !output.isEmpty else {
            log(.error, "Text Model", "The model returned an empty response.")
            throw MLXTextRuntimeError.emptyResponse
        }
        log(
            .debug,
            "Text Model Response",
            "characters=\(output.count), rawOutput=omitted"
        )
        progress(1)
        return output
    }

    private static func isRepeatingTail(_ output: String) -> Bool {
        let sampleLength = 90
        guard output.count > sampleLength * 3 else { return false }
        let needle = String(output.suffix(sampleLength))
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var occurrences = 0
        var searchRange = output.startIndex..<output.endIndex
        while let found = output.range(of: needle, range: searchRange) {
            occurrences += 1
            if occurrences >= 3 { return true }
            guard found.upperBound < output.endIndex else { break }
            searchRange = found.upperBound..<output.endIndex
        }
        return false
    }

    private static func repairedTruncatedArray(_ output: String) -> String {
        guard output.contains("["), let lastObjectEnd = output.lastIndex(of: "}") else {
            return output
        }
        var repaired = String(output[...lastObjectEnd])
        let openCount = repaired.filter { $0 == "[" }.count
        let closeCount = repaired.filter { $0 == "]" }.count
        repaired += String(repeating: "]", count: max(0, openCount - closeCount))
        return repaired
    }

    private func loadContainer(
        progress: @escaping InferenceProgress
    ) async throws -> ModelContainer {
        if let container {
            progress(0.45)
            return container
        }
        progress(0.01)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        progress(0.45)
        container = loaded
        return loaded
    }
}

enum MLXTextRuntimeError: LocalizedError, Sendable {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "MLX 文生文模型沒有回傳內容。"
        }
    }
}
