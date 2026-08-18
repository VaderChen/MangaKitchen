import Foundation

/// 每張漫畫圖片對應一份可攜式 `.str` JSON 文件。
/// 文件只保存相對路徑與正規化座標，不保存工作機器的絕對路徑。
public struct ComicStringTable: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var sourceRelativePath: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var targetLanguageCode: String
    public var updatedAt: Date
    public var entries: [ComicStringEntry]

    public init(
        schemaVersion: Int = 1,
        sourceRelativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        targetLanguageCode: String,
        updatedAt: Date = Date(),
        entries: [ComicStringEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRelativePath = sourceRelativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.targetLanguageCode = targetLanguageCode
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public init(page: ComicPage, targetLanguageCode: String) {
        self.init(
            sourceRelativePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            targetLanguageCode: targetLanguageCode,
            entries: page.regions.enumerated().map { index, region in
                ComicStringEntry(order: index, region: region)
            }
        )
    }

    public var regions: [DialogueRegion] {
        entries.sorted { $0.order < $1.order }.map(\.region)
    }
}

public struct ComicStringEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var order: Int
    public var bounds: NormalizedRect
    public var bubbleBounds: NormalizedRect?
    public var bubbleMaskPolygons: [[NormalizedPoint]]?
    public var bubbleLayoutBounds: NormalizedRect?
    public var detectedWritingDirection: WritingDirection?
    public var rawSourceText: String?
    public var sourceText: String
    public var ocrTextRefined: Bool
    public var translatedText: String
    public var translationAnchor: NormalizedPoint?
    public var translationBounds: NormalizedRect?
    public var confidence: Double
    public var style: DialogueStyle
    public var automaticMaskEnabled: Bool
    public var maskPolygons: [[NormalizedPoint]]?
    public var maskRefinementApplied: Bool
    public var maskCoverageRatio: Double?
    public var maskCoverageComplete: Bool
    public var maskStrokes: [MaskStroke]

    public init(order: Int, region: DialogueRegion) {
        id = region.id
        self.order = order
        bounds = region.bounds
        bubbleBounds = region.bubbleBounds
        bubbleMaskPolygons = region.bubbleMaskPolygons.isEmpty ? nil : region.bubbleMaskPolygons
        bubbleLayoutBounds = region.bubbleLayoutBounds
        detectedWritingDirection = region.detectedWritingDirection == .automatic
            ? nil
            : region.detectedWritingDirection
        rawSourceText = region.rawSourceText
        sourceText = region.sourceText
        ocrTextRefined = region.ocrTextRefined
        translatedText = region.translatedText
        translationAnchor = region.translationAnchor
        translationBounds = region.translationBounds
        confidence = region.confidence
        style = region.style
        automaticMaskEnabled = region.automaticMaskEnabled
        maskPolygons = region.maskPolygons.isEmpty ? nil : region.maskPolygons
        maskRefinementApplied = region.maskRefinementApplied
        maskCoverageRatio = region.maskCoverageRatio
        maskCoverageComplete = region.maskCoverageComplete
        maskStrokes = region.maskStrokes
    }

    public var region: DialogueRegion {
        DialogueRegion(
            id: id,
            bounds: bounds,
            bubbleBounds: bubbleBounds,
            bubbleMaskPolygons: bubbleMaskPolygons ?? [],
            bubbleLayoutBounds: bubbleLayoutBounds,
            detectedWritingDirection: detectedWritingDirection ?? .automatic,
            rawSourceText: rawSourceText,
            sourceText: sourceText,
            ocrTextRefined: ocrTextRefined,
            translatedText: translatedText,
            translationAnchor: translationAnchor,
            translationBounds: translationBounds,
            confidence: confidence,
            style: style,
            automaticMaskEnabled: automaticMaskEnabled,
            maskPolygons: maskPolygons ?? [],
            maskRefinementApplied: maskRefinementApplied,
            maskCoverageRatio: maskCoverageRatio,
            maskCoverageComplete: maskCoverageComplete,
            maskStrokes: maskStrokes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case order
        case bounds
        case bubbleBounds
        case bubbleMaskPolygons
        case bubbleLayoutBounds
        case detectedWritingDirection
        case rawSourceText
        case sourceText
        case ocrTextRefined
        case translatedText
        case translationAnchor
        case translationBounds
        case confidence
        case style
        case automaticMaskEnabled
        case maskPolygons
        case maskRefinementApplied
        case maskCoverageRatio
        case maskCoverageComplete
        case maskStrokes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        order = try values.decode(Int.self, forKey: .order)
        bounds = try values.decode(NormalizedRect.self, forKey: .bounds)
        bubbleBounds = try values.decodeIfPresent(NormalizedRect.self, forKey: .bubbleBounds)
        bubbleMaskPolygons = try values.decodeIfPresent(
            [[NormalizedPoint]].self,
            forKey: .bubbleMaskPolygons
        )
        bubbleLayoutBounds = try values.decodeIfPresent(
            NormalizedRect.self,
            forKey: .bubbleLayoutBounds
        )
        detectedWritingDirection = try values.decodeIfPresent(
            WritingDirection.self,
            forKey: .detectedWritingDirection
        )
        rawSourceText = try values.decodeIfPresent(String.self, forKey: .rawSourceText)
        sourceText = try values.decode(String.self, forKey: .sourceText)
        ocrTextRefined = try values.decodeIfPresent(Bool.self, forKey: .ocrTextRefined) ?? false
        translatedText = try values.decode(String.self, forKey: .translatedText)
        translationAnchor = try values.decodeIfPresent(
            NormalizedPoint.self,
            forKey: .translationAnchor
        )?.clamped()
        translationBounds = try values.decodeIfPresent(
            NormalizedRect.self,
            forKey: .translationBounds
        )?.clamped()
        confidence = try values.decode(Double.self, forKey: .confidence)
        style = try values.decode(DialogueStyle.self, forKey: .style)
        automaticMaskEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .automaticMaskEnabled
        ) ?? true
        maskPolygons = try values.decodeIfPresent(
            [[NormalizedPoint]].self,
            forKey: .maskPolygons
        )
        maskRefinementApplied = try values.decodeIfPresent(
            Bool.self,
            forKey: .maskRefinementApplied
        ) ?? false
        maskCoverageRatio = try values.decodeIfPresent(
            Double.self,
            forKey: .maskCoverageRatio
        ).map { min(max($0, 0), 1) }
        maskCoverageComplete = try values.decodeIfPresent(
            Bool.self,
            forKey: .maskCoverageComplete
        ) ?? false
        maskStrokes = try values.decodeIfPresent([MaskStroke].self, forKey: .maskStrokes) ?? []
    }
}
