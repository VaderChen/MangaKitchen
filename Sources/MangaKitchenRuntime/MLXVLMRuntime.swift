import Foundation
import ImageIO
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import MangaKitchenCore
import Tokenizers
import UniformTypeIdentifiers

private final class VLMGenerationInputBox: @unchecked Sendable {
    let dflashInput: LMInput
    let standardInput: LMInput

    init(_ input: LMInput) {
        dflashInput = input
        standardInput = LMInput(
            text: .init(tokens: input.text.tokens, mask: input.text.mask),
            image: input.image,
            video: input.video,
            audio: input.audio)
    }
}

/// 執行本機 Hugging Face MLX VLM 目錄；矩陣運算由 MLX 的 Metal 後端處理。
actor MLXVLMRuntime: ImageToTextGenerating {
    let info: LoadedModelInfo

    private let modelDirectory: URL
    private let ggufWeightsURL: URL?
    private let mmprojURL: URL?
    private let generation: ModelManifest.Generation
    private let ggufQuantizationGroupSize: Int
    private let ggufQuantizationProfile: GGUFQuantizationProfile
    private let thinkingEnabled: Bool
    private let generationProtocol: MLXGenerationProtocol
    private let dflashEnabled: Bool
    private let dflashBlockSize: Int
    private let log: RuntimeLogHandler
    private let reasoningStream: RuntimeReasoningStreamHandler
    private var container: ModelContainer?
    private var dflashDrafter: (any DFlashDrafterModel)?

    init(
        directoryURL: URL,
        manifest: ModelManifest,
        ggufQuantizationGroupSize: Int = 64,
        ggufQuantizationProfile: GGUFQuantizationProfile = .quality,
        thinkingEnabled: Bool = false,
        dflashEnabled: Bool = false,
        dflashBlockSize: Int = 5,
        log: @escaping RuntimeLogHandler = { _, _, _ in },
        reasoningStream: @escaping RuntimeReasoningStreamHandler = { _ in }
    ) throws {
        guard manifest.backend == .mlxSwift else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .imageToText else {
            throw ModelRuntimeError.unsupportedBackendCapability(.mlxSwift, manifest.capability)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelRuntimeError.modelFileNotFound(directoryURL)
        }

        self.modelDirectory = directoryURL
        let ggufWeightsURL = try MLXGGUFModelSource.weightURL(
            in: directoryURL,
            manifest: manifest
        )
        let mmprojURL = try MLXGGUFModelSource.mmprojURL(
            in: directoryURL,
            manifest: manifest
        )
        if manifest.weightsFormat == .gguf {
            guard ggufWeightsURL != nil else {
                throw ModelRuntimeError.modelFileNotFound(directoryURL)
            }
            guard let mmprojURL else {
                throw MLXGGUFLoaderError.missingMultimodalProjector(
                    directoryURL.appendingPathComponent("mmproj-F16.gguf")
                )
            }
            self.mmprojURL = mmprojURL
        } else {
            self.mmprojURL = mmprojURL
        }
        self.ggufWeightsURL = ggufWeightsURL
        self.generation = manifest.generation ?? ModelManifest.Generation()
        self.ggufQuantizationGroupSize = ggufQuantizationGroupSize
        self.ggufQuantizationProfile = ggufQuantizationProfile
        self.thinkingEnabled = thinkingEnabled
        self.generationProtocol = MLXGenerationProtocol.detect(in: directoryURL)
        self.dflashEnabled = dflashEnabled
        self.dflashBlockSize = min(max(dflashBlockSize, 2), 256)
        self.log = log
        self.reasoningStream = reasoningStream
        self.info = LoadedModelInfo(
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
        imageURL: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw MLXVLMRuntimeError.missingInputFile(imageURL)
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
        let preparedImage = try Self.preparedImageURL(
            from: imageURL,
            maximumPixelSize: min(max(generation.maximumImageDimension, 512), 4_096)
        )
        defer {
            if preparedImage.isTemporary {
                try? FileManager.default.removeItem(at: preparedImage.url)
            }
        }

        progress(0.01)
        let container = try await loadContainer(progress: progress)
        try Task.checkCancellation()
        progress(0.48)

        // Qwen3.5／3.8 的 chat template 預設會開啟 thinking，模型因而先輸出長篇
        // 分析文字而不是結構化 JSON。翻譯／OCR／定位都要求機器可解析回覆，
        // 必須和純文字 runtime 一樣明確控制 thinking；啟用時也只使用輕度思考。
        let input = UserInput(
            chat: [.user(prompt, images: [.url(preparedImage.url)])],
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
        var result = ""
        if generationProtocol.requiresTokenAwareGeneration {
            result = try await MLXProtocolTokenGenerator.generate(
                protocol: generationProtocol,
                container: container,
                input: prepared,
                parameters: parameters,
                progressStart: 0.55,
                progressEnd: 0.99,
                phase: "initial",
                progress: progress,
                log: log
            )
            if let reasoningID {
                reasoningStream(.updated(
                    id: reasoningID,
                    text: VLMStructuredResponseDecoder.streamedReasoningText(from: result)
                ))
            }
        } else {
            let stream = try await generateStream(
                container: container,
                input: prepared,
                parameters: parameters)
            let generationStart = Date()
            let expectedChunks = min(maxTokens, 512)
            var chunks = 0
            var didLogFirstToken = false
            var lastRepetitionCheck = 0
            var stoppedOnRepetition = false

            for await event in stream {
                try Task.checkCancellation()
                if let info = event.info {
                    log(
                        .info,
                        "Generation Metrics",
                        "promptTokens=\(info.promptTokenCount) generationTokens=\(info.generationTokenCount) "
                            + "promptTokensPerSecond=\(info.promptTokensPerSecond) "
                            + "tokensPerSecond=\(info.tokensPerSecond)"
                    )
                }
                if case let .chunk(text) = event {
                    if !didLogFirstToken, !text.isEmpty {
                        didLogFirstToken = true
                        log(
                            .info,
                            "Generation Metrics",
                            "phase=initial firstTokenLatency=\(Date().timeIntervalSince(generationStart))"
                        )
                    }
                    result += text
                    if let reasoningID {
                        reasoningStream(.updated(
                            id: reasoningID,
                            text: VLMStructuredResponseDecoder.streamedReasoningText(from: result)
                        ))
                    }
                    chunks += 1
                    progress(min(0.99, 0.55 + Double(chunks) / Double(expectedChunks) * 0.44))
                    if chunks - lastRepetitionCheck >= 32, result.count > 400 {
                        lastRepetitionCheck = chunks
                        if Self.isRepeatingTail(result) {
                            stoppedOnRepetition = true
                            break
                        }
                    }
                }
            }
            if stoppedOnRepetition {
                result = Self.repairedTruncatedArray(result)
            }
        }

        var output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reasoningID {
            reasoningStream(.finished(id: reasoningID))
            reasoningDidFinish = true
        }
        if thinkingEnabled,
           !VLMStructuredResponseDecoder.hasCompleteStructuredFinalAnswer(output) {
            log(
                .warning,
                "Image Model",
                "Thinking ended without complete JSON; finalizing with the same loaded model and thinking disabled."
            )
            let finalInput = UserInput(
                chat: [
                    .user(
                        VLMStructuredResponseDecoder.nonThinkingFinalizationPrompt(
                            originalPrompt: prompt,
                            reasoningResponse: output
                        ),
                        images: [.url(preparedImage.url)]
                    )
                ],
                additionalContext: [
                    "enable_thinking": false,
                    "mangakitchen_force_final_channel": generationProtocol == .harmony
                ]
            )
            let finalPrepared = try await container.prepare(input: finalInput)
            let finalParameters = GenerateParameters(
                maxTokens: max(requestedMaxTokens, min(512, configuredTokenLimit)),
                temperature: 0,
                topP: 1,
                repetitionPenalty: max(generation.repetitionPenalty, 1),
                repetitionContextSize: 128
            )
            if generationProtocol.requiresTokenAwareGeneration {
                output = try await MLXProtocolTokenGenerator.generate(
                    protocol: generationProtocol,
                    container: container,
                    input: finalPrepared,
                    parameters: finalParameters,
                    progressStart: 0.99,
                    progressEnd: 0.99,
                    phase: "finalization",
                    startsInFinalChannel: generationProtocol == .harmony,
                    progress: progress,
                    log: log
                )
            } else {
                let finalStream = try await generateStream(
                    container: container,
                    input: finalPrepared,
                    parameters: finalParameters)
                let finalGenerationStart = Date()
                var finalOutput = ""
                var didLogFinalFirstToken = false
                for await event in finalStream {
                    try Task.checkCancellation()
                    if let info = event.info {
                        log(
                            .info,
                            "Generation Metrics",
                            "promptTokens=\(info.promptTokenCount) generationTokens=\(info.generationTokenCount) "
                                + "promptTokensPerSecond=\(info.promptTokensPerSecond) "
                                + "tokensPerSecond=\(info.tokensPerSecond)"
                        )
                    }
                    if case let .chunk(text) = event {
                        if !didLogFinalFirstToken, !text.isEmpty {
                            didLogFinalFirstToken = true
                            log(
                                .info,
                                "Generation Metrics",
                                "phase=finalization firstTokenLatency=\(Date().timeIntervalSince(finalGenerationStart))"
                            )
                        }
                        finalOutput += text
                        progress(0.99)
                    }
                }
                output = finalOutput
            }
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !output.isEmpty else { throw MLXVLMRuntimeError.emptyResponse }
        progress(1)
        return output
    }

    /// output 末段是否已經在重複自己。取尾端一小段當樣本，若它在整段裡出現
    /// 三次以上，就判定進入迴圈。
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

    /// 中途停止會留下未閉合的 JSON 陣列。截到最後一個完整物件再補上 ]，
    /// 讓既有的解碼器仍能取用已經產生的內容，而不是整批作廢。
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

    private func loadContainer(progress: @escaping InferenceProgress) async throws -> ModelContainer {
        if let container {
            progress(0.45)
            return container
        }
        progress(0.01)
        let loaded: ModelContainer
        if let ggufWeightsURL, let mmprojURL {
            loaded = try await MLXGGUFModelLoader.loadVLMContainer(
                from: modelDirectory,
                weightURL: ggufWeightsURL,
                mmprojURL: mmprojURL,
                quantizationGroupSize: ggufQuantizationGroupSize,
                quantizationProfile: ggufQuantizationProfile
            )
        } else {
            loaded = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        }
        dflashDrafter = await DFlashDraftRuntimeLoader.loadIfEnabled(
            enabled: dflashEnabled,
            targetDirectory: modelDirectory,
            targetDisplayName: info.displayName,
            container: loaded,
            log: log
        )
        progress(0.45)
        container = loaded
        return loaded
    }

    private func generateStream(
        container: ModelContainer,
        input: LMInput,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        let inputs = VLMGenerationInputBox(input)
        guard let dflashDrafter else {
            return try await container.generate(
                input: inputs.standardInput,
                parameters: parameters)
        }
        guard parameters.maxKVSize == nil,
              parameters.kvBits == nil,
              parameters.kvScheme == nil else {
            log(
                .warning,
                "DFlash",
                "Target KV Cache configuration is incompatible; using standard generation for \(info.displayName)."
            )
            return try await container.generate(
                input: inputs.standardInput,
                parameters: parameters)
        }

        do {
            return try await container.generate(
                input: inputs.dflashInput,
                parameters: parameters,
                dflashDrafter: dflashDrafter,
                blockSize: dflashBlockSize)
        } catch let error as DFlashError {
            log(
                .warning,
                "DFlash",
                "DFlash generation is unavailable for \(info.displayName); using standard generation: \(error.localizedDescription)"
            )
            return try await container.generate(
                input: inputs.standardInput,
                parameters: parameters)
        }
    }

    private static func preparedImageURL(
        from sourceURL: URL,
        maximumPixelSize: Int
    ) throws -> (url: URL, isTemporary: Bool) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        guard max(width.intValue, height.intValue) > maximumPixelSize else {
            return (sourceURL, false)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-vlm-\(UUID().uuidString)")
            .appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        return (temporaryURL, true)
    }
}

enum MLXVLMRuntimeError: LocalizedError, Sendable {
    case missingInputFile(URL)
    case invalidImage(URL)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case let .missingInputFile(url): "找不到圖生文輸入圖片：\(url.path)"
        case let .invalidImage(url): "圖生文模型無法讀取圖片：\(url.path)"
        case .emptyResponse: "MLX 圖生文模型沒有回傳內容。"
        }
    }
}
