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
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }

        let payload = regions.map { PromptRegion(id: $0.id, sourceText: $0.sourceText) }
        let data = try JSONEncoder().encode(payload)
        guard let regionJSON = String(data: data, encoding: .utf8) else {
            throw TranslationRuntimeError.promptEncodingFailed
        }
        let glossaryData = try JSONEncoder().encode(glossaryTerms)
        guard let glossaryJSON = String(data: glossaryData, encoding: .utf8) else {
            throw TranslationRuntimeError.promptEncodingFailed
        }

        let prompt = Self.prompt(
            targetLanguageCode: targetLanguageCode,
            glossaryJSON: glossaryJSON,
            regionsJSON: regionJSON
        )
        let response = try await model.generateText(
            imageURL: pageURL,
            prompt: prompt,
            progress: progress
        )
        let translations = try Self.decodeTranslations(response)
        let indexed = Dictionary(uniqueKeysWithValues: translations.map { ($0.id, $0.translatedText) })

        guard regions.contains(where: { indexed[$0.id]?.isEmpty == false }) else {
            throw TranslationRuntimeError.noMatchingTranslation
        }

        return regions.map { region in
            var translated = region
            if let text = indexed[region.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                translated.translatedText = text
            }
            return translated
        }
    }

    private static func prompt(
        targetLanguageCode: String,
        glossaryJSON: String,
        regionsJSON: String
    ) -> String {
        """
        You are translating speech balloons, captions, and sound effects on one comic page.
        Translate every sourceText into the language identified by BCP-47 code "\(targetLanguageCode)".
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
        """
    }

    private static func decodeTranslations(_ response: String) throws -> [TranslationItem] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([TranslationItem].self, from: data) {
            return decoded
        }

        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw TranslationRuntimeError.invalidModelResponse
        }
        do {
            return try JSONDecoder().decode([TranslationItem].self, from: data)
        } catch {
            throw TranslationRuntimeError.invalidModelResponse
        }
    }
}

public enum TranslationRuntimeError: LocalizedError, Sendable {
    case promptEncodingFailed
    case invalidModelResponse
    case noMatchingTranslation

    public var errorDescription: String? {
        switch self {
        case .promptEncodingFailed: "無法建立漫畫翻譯 Prompt。"
        case .invalidModelResponse: "圖生文模型沒有回傳指定的翻譯 JSON 格式。"
        case .noMatchingTranslation: "模型回傳內容未包含任何相符的對話區域。"
        }
    }
}
