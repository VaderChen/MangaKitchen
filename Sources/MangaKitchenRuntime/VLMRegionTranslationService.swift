import Foundation
import MangaKitchenCore

public actor VLMRegionTranslationService: RegionTranslating {
    private static let maximumRegionsPerRequest = 12

    private struct PromptRegion: Encodable {
        var id: UUID
        var sourceText: String
    }

    private struct TranslationItem: Decodable {
        var id: UUID
        var translatedText: String
    }

    private let model: any ImageToTextGenerating

    public init(model: any ImageToTextGenerating) {
        self.model = model
    }

    public func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }

        let glossaryData = try JSONEncoder().encode(glossaryTerms)
        guard let glossaryJSON = String(data: glossaryData, encoding: .utf8) else {
            throw TranslationRuntimeError.promptEncodingFailed
        }

        let batches = stride(from: 0, to: regions.count, by: Self.maximumRegionsPerRequest).map {
            Array(regions[$0..<min($0 + Self.maximumRegionsPerRequest, regions.count)])
        }
        let batchCount = max(1, batches.count)
        var indexed: [UUID: String] = [:]

        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let payload = batch.map { PromptRegion(id: $0.id, sourceText: $0.sourceText) }
            let data = try JSONEncoder().encode(payload)
            guard let regionJSON = String(data: data, encoding: .utf8) else {
                throw TranslationRuntimeError.promptEncodingFailed
            }
            let prompt = Self.prompt(
                targetLanguageCode: targetLanguageCode,
                glossaryJSON: glossaryJSON,
                regionsJSON: regionJSON,
                attempt: 0
            )
            let batchIndex = index
            let expectedIDs = Set(batch.map(\.id))
            var batchResults: [UUID: String] = [:]
            var receivedDecodableResponse = false

            for attempt in 0..<VLMStructuredResponseDecoder.maximumAttempts {
                try Task.checkCancellation()
                let retryPrompt = attempt == 0 ? prompt : Self.prompt(
                    targetLanguageCode: targetLanguageCode,
                    glossaryJSON: glossaryJSON,
                    regionsJSON: regionJSON,
                    attempt: attempt
                )
                let response = try await model.generateText(
                    imageURL: pageURL,
                    prompt: retryPrompt,
                    maximumOutputTokens: 2_048,
                    progress: { value in
                        let local = VLMStructuredResponseDecoder.mappedProgress(
                            attempt: attempt,
                            value: value
                        )
                        progress((Double(batchIndex) + local) / Double(batchCount))
                    }
                )
                let decodedCandidates = VLMStructuredResponseDecoder.decodeArrays(
                    TranslationItem.self,
                    from: response
                )
                if !decodedCandidates.isEmpty { receivedDecodableResponse = true }
                for items in decodedCandidates {
                    for item in items where expectedIDs.contains(item.id) {
                        let text = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { batchResults[item.id] = text }
                    }
                }
                if expectedIDs.isSubset(of: Set(batchResults.keys)) { break }
            }

            let missingCount = expectedIDs.subtracting(batchResults.keys).count
            guard missingCount == 0 else {
                if receivedDecodableResponse {
                    throw TranslationRuntimeError.missingTranslations(missingCount)
                }
                throw TranslationRuntimeError.invalidModelResponse
            }
            indexed.merge(batchResults) { _, new in new }
            progress(Double(index + 1) / Double(batchCount))
        }

        let missingCount = regions.reduce(into: 0) { count, region in
            if indexed[region.id] == nil { count += 1 }
        }
        guard missingCount == 0 else {
            throw TranslationRuntimeError.missingTranslations(missingCount)
        }

        progress(1)
        return regions.map { region in
            var translated = region
            translated.translatedText = indexed[region.id] ?? region.translatedText
            return translated
        }
    }

    private static func prompt(
        targetLanguageCode: String,
        glossaryJSON: String,
        regionsJSON: String,
        attempt: Int
    ) -> String {
        """
        You are translating speech balloons, captions, and sound effects on one comic page.
        Translate every sourceText into the language identified by BCP-47 code "\(targetLanguageCode)".
        Each sourceText has already been transcribed or confirmed. Do not re-transcribe or rewrite it.
        Use the image only as context for speaker, tone, gender, ambiguity, and sound effects.
        Keep names and terminology consistent. Be concise enough to fit the original region.
        The terminology array below is authoritative. Whenever a sourceTerm occurs in a sourceText,
        use its preferredTranslation exactly; never invent an alternative spelling or translation.
        Terminology for this page and target language:
        \(glossaryJSON)
        Do not add explanations. Return only a valid JSON array in this exact shape:
        [{"id":"UUID","translatedText":"translated text"}]
        Keep every UUID unchanged and return one item for every input item.
        Input regions:
        \(regionsJSON)
        \(VLMStructuredResponseDecoder.retryInstruction(attempt: attempt))
        """
    }
}

public enum TranslationRuntimeError: LocalizedError, Sendable {
    case promptEncodingFailed
    case invalidModelResponse
    case noMatchingTranslation
    case missingTranslations(Int)

    public var errorDescription: String? {
        switch self {
        case .promptEncodingFailed: "無法建立漫畫翻譯 Prompt。"
        case .invalidModelResponse: "圖生文模型沒有回傳指定的翻譯 JSON 格式。"
        case .noMatchingTranslation: "模型回傳內容未包含任何相符的對話區域。"
        case let .missingTranslations(count): "模型缺少 \(count) 個對話區域的翻譯，未寫入不完整結果。"
        }
    }
}
