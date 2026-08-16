import Foundation

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case imageToText
    case imageToImage
}

public enum ModelBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case coreML
    case mlxSwift
    case externalRuntime
}

public struct LoadedModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var capability: ModelCapability
    public var backend: ModelBackend
    public var location: URL

    public init(
        id: String,
        displayName: String,
        capability: ModelCapability,
        backend: ModelBackend,
        location: URL
    ) {
        self.id = id
        self.displayName = displayName
        self.capability = capability
        self.backend = backend
        self.location = location
    }
}

public enum ReadingDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case rightToLeft
    case leftToRight
    case topToBottom
}

public enum WritingDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case horizontal
    case vertical
}

public enum PageProcessingStage: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case scanned
    case detectingText
    case maskReady
    case translationReady
    case composing

    // 保留舊工作區資料與既有進度顯示相容性。
    case recognizing
    case translating
    case masking
    case restoringBackground
    case typesetting
    case completed
    case failed
}

public struct DialogueStyle: Codable, Hashable, Sendable {
    public var fontName: String
    /// nil 代表由排版器在最小與最大字級之間自動配適。
    public var fontSize: Double?
    public var minimumFontSize: Double
    public var maximumFontSize: Double
    public var writingDirection: WritingDirection
    public var textColorHex: String

    public init(
        fontName: String = "PingFang TC",
        fontSize: Double? = nil,
        minimumFontSize: Double = 9,
        maximumFontSize: Double = 40,
        writingDirection: WritingDirection = .automatic,
        textColorHex: String = "#111111"
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.minimumFontSize = minimumFontSize
        self.maximumFontSize = maximumFontSize
        self.writingDirection = writingDirection
        self.textColorHex = textColorHex
    }
}

public enum MaskStrokeMode: String, Codable, CaseIterable, Hashable, Sendable {
    case add
    case erase
}

/// 使用正規化座標保存畫筆軌跡，避免遮罩編輯綁定目前預覽尺寸。
public struct MaskStroke: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var mode: MaskStrokeMode
    public var points: [NormalizedPoint]
    /// 相對於圖片短邊的筆刷直徑，範圍 0...1。
    public var diameter: Double

    public init(
        id: UUID = UUID(),
        mode: MaskStrokeMode,
        points: [NormalizedPoint],
        diameter: Double
    ) {
        self.id = id
        self.mode = mode
        self.points = points.map { $0.clamped() }
        self.diameter = min(max(diameter, 0.001), 1)
    }
}

public struct DialogueRegion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var bounds: NormalizedRect
    public var sourceText: String
    public var translatedText: String
    public var confidence: Double
    public var style: DialogueStyle
    public var automaticMaskEnabled: Bool
    public var maskStrokes: [MaskStroke]

    public init(
        id: UUID = UUID(),
        bounds: NormalizedRect,
        sourceText: String,
        translatedText: String = "",
        confidence: Double,
        style: DialogueStyle = DialogueStyle(),
        automaticMaskEnabled: Bool = true,
        maskStrokes: [MaskStroke] = []
    ) {
        self.id = id
        self.bounds = bounds
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.confidence = confidence
        self.style = style
        self.automaticMaskEnabled = automaticMaskEnabled
        self.maskStrokes = maskStrokes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bounds
        case sourceText
        case translatedText
        case confidence
        case style
        case automaticMaskEnabled
        case maskStrokes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        bounds = try values.decode(NormalizedRect.self, forKey: .bounds)
        sourceText = try values.decode(String.self, forKey: .sourceText)
        translatedText = try values.decode(String.self, forKey: .translatedText)
        confidence = try values.decode(Double.self, forKey: .confidence)
        style = try values.decode(DialogueStyle.self, forKey: .style)
        automaticMaskEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticMaskEnabled) ?? true
        maskStrokes = try values.decodeIfPresent([MaskStroke].self, forKey: .maskStrokes) ?? []
    }
}

public struct ComicPage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var index: Int
    public var title: String
    public var sourceURL: URL
    /// 來源目錄下的相對路徑；用於避免同名檔案互相覆蓋。
    public var relativeSourcePath: String?
    public var backgroundURL: URL?
    public var maskURL: URL?
    public var stringTableURL: URL?
    public var outputURL: URL?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var regions: [DialogueRegion]
    public var stage: PageProcessingStage
    public var progress: Double
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        sourceURL: URL,
        relativeSourcePath: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        regions: [DialogueRegion] = [],
        stage: PageProcessingStage = .pending,
        progress: Double = 0
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.sourceURL = sourceURL
        self.relativeSourcePath = relativeSourcePath
        self.backgroundURL = nil
        self.maskURL = nil
        self.stringTableURL = nil
        self.outputURL = nil
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.regions = regions
        self.stage = stage
        self.progress = progress
        self.errorMessage = nil
    }
}

public struct ProcessingOptions: Codable, Hashable, Sendable {
    public var sourceLanguageCodes: [String]
    public var targetLanguageCode: String
    public var readingDirection: ReadingDirection
    public var defaultStyle: DialogueStyle
    public var maskExpansion: Double
    public var useImageToImageRestoration: Bool
    public var preserveUntranslatedRegions: Bool

    public init(
        sourceLanguageCodes: [String] = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"],
        targetLanguageCode: String = "zh-Hant",
        readingDirection: ReadingDirection = .rightToLeft,
        defaultStyle: DialogueStyle = DialogueStyle(),
        maskExpansion: Double = 0.18,
        useImageToImageRestoration: Bool = true,
        preserveUntranslatedRegions: Bool = false
    ) {
        self.sourceLanguageCodes = sourceLanguageCodes
        self.targetLanguageCode = targetLanguageCode
        self.readingDirection = readingDirection
        self.defaultStyle = defaultStyle
        self.maskExpansion = maskExpansion
        self.useImageToImageRestoration = useImageToImageRestoration
        self.preserveUntranslatedRegions = preserveUntranslatedRegions
    }
}

public struct PageProcessingResult: Codable, Hashable, Sendable {
    public var regions: [DialogueRegion]
    public var maskURL: URL
    public var backgroundURL: URL
    public var outputURL: URL
    public var warnings: [String]

    public init(
        regions: [DialogueRegion],
        maskURL: URL,
        backgroundURL: URL,
        outputURL: URL,
        warnings: [String] = []
    ) {
        self.regions = regions
        self.maskURL = maskURL
        self.backgroundURL = backgroundURL
        self.outputURL = outputURL
        self.warnings = warnings
    }
}

public struct PageDetectionResult: Codable, Hashable, Sendable {
    public var regions: [DialogueRegion]
    public var maskURL: URL

    public init(regions: [DialogueRegion], maskURL: URL) {
        self.regions = regions
        self.maskURL = maskURL
    }
}

public struct PageCompositionResult: Codable, Hashable, Sendable {
    public var maskURL: URL
    public var backgroundURL: URL
    public var outputURL: URL
    public var warnings: [String]

    public init(
        maskURL: URL,
        backgroundURL: URL,
        outputURL: URL,
        warnings: [String] = []
    ) {
        self.maskURL = maskURL
        self.backgroundURL = backgroundURL
        self.outputURL = outputURL
        self.warnings = warnings
    }
}
