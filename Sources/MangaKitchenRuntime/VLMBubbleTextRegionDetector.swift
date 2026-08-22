import CoreGraphics
import Foundation
import MangaKitchenCore

/// 嚴格遵循「找對話框 → 在框內用 VLM 定位文字」的步驟二 detector。
///
/// VLM 只接收已由氣泡模型確認的裁切，回傳 0...1000 文字座標；不轉錄、不翻譯，
/// 也不掃描對話框外的狀聲字或畫面文字。
public actor VLMBubbleTextRegionDetector: SemanticRegionDetecting {
    private let model: any ImageToTextGenerating
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime

    public init(
        model: any ImageToTextGenerating,
        bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime
    ) {
        self.model = model
        self.bubbleSegmenter = bubbleSegmenter
    }

    public func detectRegions(
        pageURL: URL,
        sourceLanguageCodes: [String],
        fineScanEnabled _: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        let source = try CGImageIO.load(from: pageURL)
        progress(0.03)
        let bubbles = try bubbleSegmenter.detectBubbles(in: source)
        progress(0.18)
        guard !bubbles.isEmpty else {
            progress(1)
            return []
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-VLM-Text-Location-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let languageHint = sourceLanguageCodes.isEmpty
            ? "unknown"
            : sourceLanguageCodes.joined(separator: ", ")
        var regions: [DialogueRegion] = []
        regions.reserveCapacity(bubbles.count)

        for (index, bubble) in bubbles.enumerated() {
            try Task.checkCancellation()
            do {
                let crop = try Self.crop(source: source, bounds: bubble.bounds)
                let cropURL = temporaryDirectory
                    .appendingPathComponent(String(format: "bubble-%03d.png", index + 1))
                try CGImageIO.writePNG(crop.image, to: cropURL)

                var resolvedLines: [TextLocalizationResult]?
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
                            progress(
                                0.18
                                    + (Double(index) + local)
                                        / Double(bubbles.count) * 0.82
                            )
                        }
                    )
                    guard let boxes = VLMStructuredResponseDecoder.decodeArrays(
                        VLMGroundingBox.self,
                        from: response
                    ).first else {
                        continue
                    }
                    // 空陣列代表這個已偵測框內沒有可定位的對話文字。
                    if boxes.isEmpty { break }
                    guard let pageRectangles = VLMTextGrounding.pageRectangles(
                        modelBoxes: boxes.map(\.coordinates),
                        cropRect: crop.rectangle,
                        imageWidth: source.width,
                        imageHeight: source.height,
                        clippingBounds: bubble.bounds,
                        // 恢復舊版的安全餘裕：VLM 座標常貼著字形外緣，4% 對
                        // 粗體、濁點與日文濁音不足；像素遮罩仍會在下一步收窄。
                        paddingFraction: 0.08
                    ) else {
                        continue
                    }
                    let lines = pageRectangles
                        .filter { Self.isInsideBubble($0, bubble: bubble) }
                        .map { bounds in
                            TextLocalizationResult(
                                confidence: 0.75,
                                polygon: Self.rectanglePolygon(bounds),
                                bounds: bounds
                            )
                        }
                    guard !lines.isEmpty else { continue }
                    resolvedLines = lines
                    break
                }

                guard let resolvedLines else { continue }
                let groups = PPOCRTextRegionDetector.groupedTextLines(resolvedLines)
                let candidates = groups.compactMap { lines
                    -> (bounds: NormalizedRect, confidence: Double)? in
                    guard let first = lines.first else { return nil }
                    let bounds = lines.dropFirst().reduce(first.bounds) {
                        $0.union(with: $1.bounds)
                    }
                    let confidence = lines.map(\.confidence).reduce(0, +)
                        / Double(lines.count)
                    return (bounds, confidence)
                }
                let primaryLayoutGroupIndex: Int? = bubble.layoutBounds.flatMap {
                    layoutBounds -> Int? in
                    let best = candidates.indices.max { lhs, rhs in
                        Self.intersectionArea(candidates[lhs].bounds, layoutBounds)
                            < Self.intersectionArea(candidates[rhs].bounds, layoutBounds)
                    }
                    guard let best,
                          Self.intersectionArea(candidates[best].bounds, layoutBounds) > 0 else {
                        return nil
                    }
                    return best
                }
                for (groupIndex, candidate) in candidates.enumerated() {
                    let layoutBounds: NormalizedRect?
                    if candidates.count == 1 || groupIndex == primaryLayoutGroupIndex {
                        layoutBounds = bubble.layoutBounds
                    } else {
                        let localLayout = candidate.bounds
                            .expanded(by: 0.4)
                            .intersection(with: bubble.bounds)
                        layoutBounds = localLayout.width > 0 && localLayout.height > 0
                            ? localLayout
                            : candidate.bounds
                    }
                    regions.append(DialogueRegion(
                        bounds: candidate.bounds,
                        bubbleBounds: bubble.bounds,
                        bubbleMaskPolygons: bubble.maskPolygons,
                        bubbleLayoutBounds: layoutBounds,
                        sourceText: "",
                        confidence: candidate.confidence,
                        automaticMaskEnabled: false
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單框定位失敗時略過該框，不回退掃描氣泡外畫面。
            }
            progress(0.18 + Double(index + 1) / Double(bubbles.count) * 0.82)
        }
        progress(1)
        return regions
    }

    private static func prompt(languageHint: String, attempt: Int) -> String {
        """
        This image is one speech balloon already confirmed by a comic balloon detector.
        Locate only the dialogue glyphs inside this balloon. Likely source languages: \(languageHint).

        Rules:
        - Inspect the entire balloon before answering. Missing any dialogue glyph is an invalid result.
        - Return one tight box for every horizontal text line or vertical text column. Include all
          columns from right to left, all rows from top to bottom, short edge columns, punctuation-only
          lines and small kana. Never stop after the first or most prominent line/column.
        - When several lines or columns belong to one dialogue, return every box in the same JSON array.
        - Coordinates use [left, top, right, bottom] on a 0...1000 scale.
        - Exclude the balloon border, panel art, speed lines, characters, page numbers and decorations.
        - Do not include sound effects or stylised onomatopoeia.
        - Do not transcribe, translate, classify or explain the text.
        - If there is no dialogue text, return an empty JSON array.

        \(VLMStructuredResponseDecoder.finalJSONInstruction)
        Return this JSON shape:
        [{"bbox_2d":[100,100,900,900]}]
        \(VLMStructuredResponseDecoder.retryInstruction(attempt: attempt))
        """
    }

    private static func crop(
        source: CGImage,
        bounds: NormalizedRect
    ) throws -> (image: CGImage, rectangle: CGRect) {
        let width = Double(source.width)
        let height = Double(source.height)
        let rectangle = CGRect(
            x: floor(bounds.minX * width),
            y: floor(bounds.minY * height),
            width: ceil(bounds.maxX * width) - floor(bounds.minX * width),
            height: ceil(bounds.maxY * height) - floor(bounds.minY * height)
        ).intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard rectangle.width >= 1, rectangle.height >= 1,
              let image = source.cropping(to: rectangle) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return (image, rectangle)
    }

    private static func isInsideBubble(
        _ textBounds: NormalizedRect,
        bubble: BubbleDetection
    ) -> Bool {
        guard !bubble.maskPolygons.isEmpty else { return true }
        let center = NormalizedPoint(x: textBounds.centerX, y: textBounds.centerY)
        return bubble.maskPolygons.contains { polygon in
            guard let first = polygon.first else { return false }
            let rectangle = polygon.dropFirst().reduce(
                NormalizedRect(x: first.x, y: first.y, width: 0, height: 0)
            ) { bounds, point in
                bounds.union(with: NormalizedRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            return center.x >= rectangle.minX && center.x <= rectangle.maxX
                && center.y >= rectangle.minY && center.y <= rectangle.maxY
        }
    }

    private static func rectanglePolygon(_ bounds: NormalizedRect) -> [NormalizedPoint] {
        [
            NormalizedPoint(x: bounds.minX, y: bounds.minY),
            NormalizedPoint(x: bounds.maxX, y: bounds.minY),
            NormalizedPoint(x: bounds.maxX, y: bounds.maxY),
            NormalizedPoint(x: bounds.minX, y: bounds.maxY)
        ]
    }

    private static func intersectionArea(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Double {
        let intersection = lhs.intersection(with: rhs)
        return intersection.width * intersection.height
    }
}
