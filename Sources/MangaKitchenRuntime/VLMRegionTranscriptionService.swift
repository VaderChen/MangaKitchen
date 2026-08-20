import CoreGraphics
import Foundation
import MangaKitchenCore

public actor VLMRegionTranscriptionService: RegionTextRecognizing {
    private struct TranscriptItem: Decodable {
        var index: Int
        var text: String
        var kind: String
        var direction: String?
    }

    private let model: any ImageToTextGenerating

    public init(model: any ImageToTextGenerating) {
        self.model = model
    }

    public func recognizeRegions(
        pageURL: URL,
        regions: [DialogueRegion],
        sourceLanguageCodes: [String],
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }
        let source = try CGImageIO.load(from: pageURL)
        let languageHint = sourceLanguageCodes.isEmpty
            ? "unknown; infer it from the crop"
            : sourceLanguageCodes.joined(separator: ", ")
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Transcript-Crops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let pendingRegions = regions.filter {
            $0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !pendingRegions.isEmpty else {
            progress(1)
            return regions
        }
        regionProgress(0, pendingRegions.count)

        var recognizedByID: [UUID: DialogueRegion] = [:]
        for region in regions where !region.sourceText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            recognizedByID[region.id] = region
        }
        let regionCount = max(1, pendingRegions.count)
        for (offset, region) in pendingRegions.enumerated() {
            try Task.checkCancellation()
            do {
                let cropURL = temporaryDirectoryURL
                    .appendingPathComponent(String(format: "crop-%03d.png", offset + 1))
                try Self.writeCrop(source: source, region: region, to: cropURL)
                var item: TranscriptItem?
                for attempt in 0..<VLMStructuredResponseDecoder.maximumAttempts {
                    try Task.checkCancellation()
                    let response = try await model.generateText(
                        imageURL: cropURL,
                        prompt: Self.prompt(languageHint: languageHint, attempt: attempt),
                        maximumOutputTokens: 512,
                        progress: { value in
                            let local = VLMStructuredResponseDecoder.mappedProgress(
                                attempt: attempt,
                                value: value
                            )
                            progress((Double(offset) + local) / Double(regionCount))
                        }
                    )
                    let decodedItems = VLMStructuredResponseDecoder.decodeArrays(
                        TranscriptItem.self,
                        from: response
                    )
                    for returnedItems in decodedItems {
                        if let matchedItem = returnedItems.first(where: { $0.index == 1 }) {
                            item = matchedItem
                            break
                        }
                    }
                    if item != nil { break }
                }
                guard let item else {
                    throw VLMRegionTranscriptionError.invalidModelResponse
                }
                let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isAcceptedKind(kind), !text.isEmpty, !Self.isSoundEffectTranscript(text) {
                    var recognized = region
                    recognized.rawSourceText = text
                    recognized.sourceText = text
                    recognized.ocrTextRefined = true
                    recognized.detectedWritingDirection = item.direction
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .flatMap(WritingDirection.init(rawValue:))
                        ?? recognized.detectedWritingDirection
                    recognizedByID[recognized.id] = recognized
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單一區域無法裁切、辨識或解析時保留原區域，繼續處理下一區。
            }
            regionProgress(offset + 1, pendingRegions.count)
            progress(Double(offset + 1) / Double(regionCount))
        }
        return regions.map { recognizedByID[$0.id] ?? $0 }
    }

    private static func isAcceptedKind(_ kind: String) -> Bool {
        ["dialogue", "caption", "title"].contains(kind)
    }

    private static func isSoundEffectTranscript(_ text: String) -> Bool {
        let normalized = text.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
        return normalized.hasPrefix("sfx:")
            || normalized.hasPrefix("sfx：")
            || normalized.hasPrefix("soundeffect:")
    }

    private static func prompt(languageHint: String, attempt: Int) -> String {
        """
        You are proofreading one cropped candidate region from a comic page. It may contain
        dialogue, a narration caption, a title, artwork, an empty area, or a sound effect.
        Likely source language codes: \(languageHint).

        Return exactly one item:
        - dialogue: speech or thought;
        - caption: narration or inner monologue;
        - title: an explicit chapter, episode, or panel title;
        - ignore: artwork, empty decoration, sound effect, action sound, credit, username,
          watermark, publisher mark, advertisement, or page number.

        Rules:
        - Transcribe accepted text exactly in its original language and never translate it.
        - Combine all lines or vertical columns belonging to this crop in source reading order.
        - direction is vertical for top-to-bottom columns, otherwise horizontal.
        - Stylised onomatopoeia and action sounds are always ignore, even when legible.
        - Do not return coordinates, bounding boxes, masks, explanations, or Markdown.
        - For ignore, return an empty text string.

        Return only a syntactically valid JSON array in this exact shape:
        [{"index":1,"text":"source text","kind":"dialogue","direction":"vertical"}]
        \(VLMStructuredResponseDecoder.retryInstruction(attempt: attempt))
        """
    }

    private static func writeCrop(source: CGImage, region: DialogueRegion, to outputURL: URL) throws {
        let visibleBounds = region.bubbleBounds
            .map { $0.union(with: region.bounds) }
            ?? region.bounds
        let sourceRect = expandedPixelRect(
            for: visibleBounds,
            sourceWidth: source.width,
            sourceHeight: source.height
        )
        guard let crop = source.cropping(to: sourceRect) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(crop, to: outputURL)
    }

    private static func expandedPixelRect(
        for bounds: NormalizedRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let horizontalPosition = bounds.x * Double(sourceWidth)
        let verticalPosition = bounds.y * Double(sourceHeight)
        let width = bounds.width * Double(sourceWidth)
        let height = bounds.height * Double(sourceHeight)
        let padding = max(8, min(width, height) * 0.1)
        return CGRect(
            x: floor(max(0, horizontalPosition - padding)),
            y: floor(max(0, verticalPosition - padding)),
            width: ceil(
                min(Double(sourceWidth), horizontalPosition + width + padding)
                    - max(0, horizontalPosition - padding)
            ),
            height: ceil(
                min(Double(sourceHeight), verticalPosition + height + padding)
                    - max(0, verticalPosition - padding)
            )
        ).intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
    }
}

public enum VLMRegionTranscriptionError: LocalizedError, Sendable {
    case invalidModelResponse

    public var errorDescription: String? {
        switch self {
        case .invalidModelResponse:
            "圖生文模型沒有回傳區域原文 JSON 格式。"
        }
    }
}
