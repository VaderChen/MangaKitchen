import Foundation
import MangaKitchenCore

/// 使用圖生文模型與整頁影像語境，對 Vision OCR 結果做一次忠實校正。
/// 校正只處理錯字、漏字、閱讀順序與標點，不負責翻譯或文風改寫。
public actor VLMOCRTextRefinementService: OCRTextRefining {
    private static let maximumRegionsPerRequest = 12

    private struct PromptRegion: Encodable {
        var id: UUID
        var bounds: NormalizedRect
        var ocrText: String
    }

    private struct RefinementItem: Decodable {
        var id: UUID
        var refinedText: String
    }

    private let model: any ImageToTextGenerating

    public init(model: any ImageToTextGenerating) {
        self.model = model
    }

    public func refineOCRText(
        regions: [DialogueRegion],
        pageURL: URL,
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }

        let languageHint = sourceLanguageCodes.isEmpty
            ? "unknown; infer it from the page"
            : sourceLanguageCodes.joined(separator: ", ")

        let batches = stride(from: 0, to: regions.count, by: Self.maximumRegionsPerRequest).map {
            Array(regions[$0..<min($0 + Self.maximumRegionsPerRequest, regions.count)])
        }
        let batchCount = max(1, batches.count)
        var indexed: [UUID: String] = [:]

        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let payload = batch.map {
                PromptRegion(
                    id: $0.id,
                    bounds: $0.bounds,
                    ocrText: $0.rawSourceText ?? $0.sourceText
                )
            }
            let data = try JSONEncoder().encode(payload)
            guard let regionJSON = String(data: data, encoding: .utf8) else {
                throw OCRTextRefinementError.promptEncodingFailed
            }
            let batchIndex = index
            let response = try await model.generateText(
                imageURL: pageURL,
                prompt: Self.prompt(languageHint: languageHint, regionsJSON: regionJSON),
                maximumOutputTokens: 1_536,
                progress: { value in
                    let local = min(max(value, 0), 1)
                    progress((Double(batchIndex) + local) / Double(batchCount))
                }
            )
            for item in try Self.decode(response) {
                let text = item.refinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { indexed[item.id] = text }
            }
            progress(Double(index + 1) / Double(batchCount))
        }

        let missingCount = regions.reduce(into: 0) { count, region in
            if indexed[region.id] == nil { count += 1 }
        }
        guard missingCount == 0 else {
            throw OCRTextRefinementError.missingRegions(missingCount)
        }

        progress(1)
        return regions.map { region in
            var refined = region
            refined.rawSourceText = region.rawSourceText ?? region.sourceText
            refined.sourceText = indexed[region.id] ?? region.sourceText
            refined.ocrTextRefined = true
            return refined
        }
    }

    private static func prompt(languageHint: String, regionsJSON: String) -> String {
        """
        You are proofreading OCR transcriptions from one comic page.
        Inspect the image and correct each ocrText using the matching normalized bounds.
        Likely source language codes: \(languageHint).

        Rules:
        - Preserve the original language, meaning, wording, speaker voice, punctuation, and sound effects.
        - Correct recognition errors, missing characters, duplicated characters, and reading order only.
        - Do not translate, paraphrase, embellish, censor, summarize, or explain.
        - Keep meaningful line breaks. Remove line breaks that are only artifacts of vertical OCR columns.
        - If the image is ambiguous, keep the supplied ocrText instead of guessing.
        - Return one item for every input UUID and never change a UUID.

        Return only a valid JSON array in this exact shape:
        [{"id":"UUID","refinedText":"faithfully corrected source text"}]

        Input regions:
        \(regionsJSON)
        """
    }

    private static func decode(_ response: String) throws -> [RefinementItem] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([RefinementItem].self, from: data) {
            return decoded
        }
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw OCRTextRefinementError.invalidModelResponse
        }
        do {
            return try JSONDecoder().decode([RefinementItem].self, from: data)
        } catch {
            throw OCRTextRefinementError.invalidModelResponse
        }
    }
}

public enum OCRTextRefinementError: LocalizedError, Sendable {
    case promptEncodingFailed
    case invalidModelResponse
    case noMatchingRegion
    case missingRegions(Int)

    public var errorDescription: String? {
        switch self {
        case .promptEncodingFailed: "無法建立 OCR 校正 Prompt。"
        case .invalidModelResponse: "圖生文模型沒有回傳指定的 OCR 校正 JSON 格式。"
        case .noMatchingRegion: "OCR 校正結果未包含任何相符的文字區域。"
        case let .missingRegions(count): "OCR 校正缺少 \(count) 個文字區域，未寫入不完整結果。"
        }
    }
}
