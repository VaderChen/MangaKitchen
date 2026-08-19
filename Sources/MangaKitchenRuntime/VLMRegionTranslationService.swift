import Foundation
import MangaKitchenCore

public actor VLMRegionTranslationService: RegionTranslating {
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
        regionProgress: @escaping PageRegionProgress,
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

        let regionCount = regions.count
        var translatedRegions: [DialogueRegion] = []
        translatedRegions.reserveCapacity(regionCount)

        for (index, region) in regions.enumerated() {
            try Task.checkCancellation()
            regionProgress(index + 1, regionCount)
            progress(Double(index) / Double(regionCount))
            do {
                let translatedText = try await translateRegion(
                    region,
                    pageURL: pageURL,
                    targetLanguageCode: targetLanguageCode,
                    glossaryJSON: glossaryJSON,
                    progress: { value in
                        progress((Double(index) + value) / Double(regionCount))
                    }
                )
                var translated = region
                translated.translatedText = translatedText
                translatedRegions.append(translated)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單一區域失敗時保留原先可用的譯文，讓其餘區域繼續處理。
                translatedRegions.append(region)
            }
            progress(Double(index + 1) / Double(regionCount))
        }

        regionProgress(regionCount, regionCount)
        progress(1)
        return translatedRegions
    }

    private func translateRegion(
        _ region: DialogueRegion,
        pageURL: URL,
        targetLanguageCode: String,
        glossaryJSON: String,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        let payload = [PromptRegion(id: region.id, sourceText: region.sourceText)]
        let data = try JSONEncoder().encode(payload)
        guard let regionJSON = String(data: data, encoding: .utf8) else {
            throw TranslationRuntimeError.promptEncodingFailed
        }

        for attempt in 0..<VLMStructuredResponseDecoder.maximumAttempts {
            try Task.checkCancellation()
            let response = try await model.generateText(
                imageURL: pageURL,
                prompt: Self.prompt(
                    targetLanguageCode: targetLanguageCode,
                    glossaryJSON: glossaryJSON,
                    regionsJSON: regionJSON,
                    attempt: attempt
                ),
                maximumOutputTokens: 2_048,
                progress: { value in
                    let local = VLMStructuredResponseDecoder.mappedProgress(
                        attempt: attempt,
                        value: value
                    )
                    progress(local)
                }
            )
            let decodedCandidates = VLMStructuredResponseDecoder.decodeArrays(
                TranslationItem.self,
                from: response
            )
            if let item = decodedCandidates
                .flatMap({ $0 })
                .first(where: { $0.id == region.id }),
               !item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw TranslationRuntimeError.invalidModelResponse
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
