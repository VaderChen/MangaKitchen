import Foundation
import MLX
import MLXLMCommon
import MangaKitchenCore

private final class MLXLMInputBox: @unchecked Sendable {
    let value: LMInput

    init(_ value: LMInput) {
        self.value = value
    }
}

enum MLXGenerationProtocol: Sendable, Equatable {
    case standard
    case harmony
    case gemma4

    var requiresTokenAwareGeneration: Bool {
        self != .standard
    }

    static func detect(in directoryURL: URL) -> Self {
        let fileNames = [
            "config.json",
            "tokenizer_config.json",
            "chat_template.jinja",
            "generation_config.json"
        ]
        let contents = fileNames.compactMap { fileName in
            try? String(
                contentsOf: directoryURL.appendingPathComponent(fileName),
                encoding: .utf8
            )
        }.joined(separator: "\n").lowercased()
        let directoryName = directoryURL.lastPathComponent.lowercased()

        if contents.contains("gpt_oss") || contents.contains("gpt-oss") {
            return .harmony
        }
        if contents.contains("gemma4")
            || contents.contains("gemma-4")
            || directoryName.contains("gemma-4")
            || directoryName.contains("gemma4") {
            return .gemma4
        }
        return .standard
    }
}

enum MLXProtocolTokenGenerator {
    static func generate(
        protocol generationProtocol: MLXGenerationProtocol,
        container: ModelContainer,
        input: LMInput,
        parameters: GenerateParameters,
        progressStart: Double,
        progressEnd: Double,
        phase: String,
        startsInFinalChannel: Bool = false,
        progress: @escaping InferenceProgress,
        log: @escaping RuntimeLogHandler
    ) async throws -> String {
        let boxedInput = MLXLMInputBox(input)
        let output = try await container.perform { context in
            let generationStart = Date()
            var iterator = try TokenIterator(
                input: boxedInput.value,
                model: context.model,
                parameters: parameters
            )
            var tokenIDs: [Int] = []
            tokenIDs.reserveCapacity(parameters.maxTokens ?? 512)
            let maximumTokens = max(parameters.maxTokens ?? 512, 1)
            let protocolStopTokenIDs = Self.tokenIDs(
                for: generationProtocol == .harmony ? ["<|return|>"] : ["<turn|>"],
                tokenizer: context.tokenizer
            )
            let harmonyEndTokenIDs = Self.tokenIDs(
                for: ["<|end|>"],
                tokenizer: context.tokenizer
            )
            let configuredStopTokenIDs = context.configuration.eosTokenIds.union(
                Self.tokenIDs(
                    for: context.configuration.extraEOSTokens,
                    tokenizer: context.tokenizer
                )
            )
            var protocolWindow = ""
            var sawFinalChannel = startsInFinalChannel
            var firstTokenLatency: Double?

            defer { Stream().synchronize() }

            while let token = iterator.next() {
                try Task.checkCancellation()
                tokenIDs.append(token)
                if firstTokenLatency == nil {
                    firstTokenLatency = Date().timeIntervalSince(generationStart)
                    log(
                        .info,
                        "Generation Metrics",
                        "phase=\(phase) firstTokenLatency=\(firstTokenLatency ?? 0)"
                    )
                }

                if let tokenText = context.tokenizer.convertIdToToken(token) {
                    protocolWindow += tokenText
                    if protocolWindow.count > 256 {
                        protocolWindow.removeFirst(protocolWindow.count - 256)
                    }
                }
                switch generationProtocol {
                case .harmony:
                    if protocolWindow.contains("<|channel|>final") {
                        sawFinalChannel = true
                    }
                case .standard, .gemma4:
                    break
                }

                let tokenText = context.tokenizer.convertIdToToken(token) ?? ""
                let isProtocolStop = protocolStopTokenIDs.contains(token)
                    || (generationProtocol == .harmony && tokenText == "<|return|>")
                    || (generationProtocol == .gemma4 && tokenText == "<turn|>")
                let isHarmonyEnd = harmonyEndTokenIDs.contains(token)
                    || tokenText == "<|end|>"
                let isConfiguredStop = configuredStopTokenIDs.contains(token)
                    || token == context.tokenizer.unknownTokenId
                let shouldStop: Bool
                switch generationProtocol {
                case .standard:
                    shouldStop = isConfiguredStop
                case .harmony:
                    shouldStop = isProtocolStop
                        || (isHarmonyEnd && sawFinalChannel)
                        || (isConfiguredStop && !isHarmonyEnd && sawFinalChannel)
                case .gemma4:
                    shouldStop = isProtocolStop
                        || (isConfiguredStop && !isProtocolStop)
                }
                if shouldStop {
                    break
                }

                let fraction = min(Double(tokenIDs.count) / Double(maximumTokens), 1)
                progress(progressStart + fraction * (progressEnd - progressStart))
            }

            let generateTime = max(Date().timeIntervalSince(generationStart), 0.000_001)
            log(
                .info,
                "Generation Metrics",
                "phase=\(phase) generationTokens=\(tokenIDs.count) "
                    + "tokensPerSecond=\(Double(tokenIDs.count) / generateTime)"
            )
            progress(progressEnd)
            return context.tokenizer.decode(tokenIds: tokenIDs)
        }
        return output
    }

    private static func tokenIDs(
        for values: Set<String>,
        tokenizer: Tokenizer
    ) -> Set<Int> {
        Set(values.compactMap { value in
            guard let tokenID = tokenizer.convertTokenToId(value),
                  tokenizer.convertIdToToken(tokenID) == value else {
                return nil
            }
            return tokenID
        })
    }
}
