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
    public var sourceText: String
    public var translatedText: String
    public var confidence: Double
    public var style: DialogueStyle
    public var automaticMaskEnabled: Bool
    public var maskStrokes: [MaskStroke]

    public init(order: Int, region: DialogueRegion) {
        id = region.id
        self.order = order
        bounds = region.bounds
        sourceText = region.sourceText
        translatedText = region.translatedText
        confidence = region.confidence
        style = region.style
        automaticMaskEnabled = region.automaticMaskEnabled
        maskStrokes = region.maskStrokes
    }

    public var region: DialogueRegion {
        DialogueRegion(
            id: id,
            bounds: bounds,
            sourceText: sourceText,
            translatedText: translatedText,
            confidence: confidence,
            style: style,
            automaticMaskEnabled: automaticMaskEnabled,
            maskStrokes: maskStrokes
        )
    }
}
