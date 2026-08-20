import Foundation

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case imageToText
    case imageToImage
    case superResolution
}

public enum ModelBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case coreML
    case mlxSwift
    case externalRuntime
}

public enum ImageCompositingBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case gpu
    case cpu
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
    case superResolving
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

public enum PageProcessingActivity: String, Codable, CaseIterable, Hashable, Sendable {
    case preparingPage
    case detectingEnclosures
    case preparingTextModel
    case detectingRegions
    case mergingRegions
    case refiningPixelMask
    case generatingMask
    case renderingMaskPreview
    case applyingGlossary
    case translatingRegions
    case preparingTranslationPreview
    case restoringBackground
    case typesettingTranslation
    case superResolving
    case savingOutput
}

public enum DialogueFontWeight: String, Codable, CaseIterable, Hashable, Sendable {
    case regular
    case bold
}

public enum DialogueTextAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case start
    case center
    case end
}

public struct DialogueStyle: Codable, Hashable, Sendable {
    public var fontName: String
    /// nil 代表由排版器在最小與最大字級之間自動配適。
    public var fontSize: Double?
    public var fontWeight: DialogueFontWeight
    public var minimumFontSize: Double
    public var maximumFontSize: Double
    public var writingDirection: WritingDirection
    public var textColorHex: String
    public var textAlignment: DialogueTextAlignment
    public var strokeColorHex: String
    public var strokeWidth: Double
    public var opacity: Double
    public var rotationDegrees: Double
    public var isVisible: Bool

    public static func normalizedHexColor(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.first == "#" else { return fallback }
        let digits = normalized.dropFirst()
        guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isHexDigit }) else {
            return fallback
        }
        if digits.count == 3 {
            return "#" + digits.map { "\($0)\($0)" }.joined()
        }
        return normalized
    }

    public init(
        fontName: String = "PingFang TC",
        fontSize: Double? = nil,
        fontWeight: DialogueFontWeight = .regular,
        minimumFontSize: Double = 9,
        maximumFontSize: Double = 40,
        writingDirection: WritingDirection = .automatic,
        textColorHex: String = "#111111",
        textAlignment: DialogueTextAlignment = .center,
        strokeColorHex: String = "#FFFFFF",
        strokeWidth: Double = 0,
        opacity: Double = 1,
        rotationDegrees: Double = 0,
        isVisible: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.minimumFontSize = minimumFontSize
        self.maximumFontSize = maximumFontSize
        self.writingDirection = writingDirection
        self.textColorHex = Self.normalizedHexColor(textColorHex, fallback: "#111111")
        self.textAlignment = textAlignment
        self.strokeColorHex = Self.normalizedHexColor(strokeColorHex, fallback: "#FFFFFF")
        self.strokeWidth = min(max(strokeWidth, 0), 20)
        self.opacity = min(max(opacity, 0), 1)
        self.rotationDegrees = min(max(rotationDegrees, -180), 180)
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case fontName
        case fontSize
        case fontWeight
        case minimumFontSize
        case maximumFontSize
        case writingDirection
        case textColorHex
        case textAlignment
        case strokeColorHex
        case strokeWidth
        case opacity
        case rotationDegrees
        case isVisible
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? "PingFang TC"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize)
        fontWeight = try values.decodeIfPresent(DialogueFontWeight.self, forKey: .fontWeight)
            ?? .regular
        minimumFontSize = try values.decodeIfPresent(Double.self, forKey: .minimumFontSize) ?? 9
        maximumFontSize = try values.decodeIfPresent(Double.self, forKey: .maximumFontSize) ?? 40
        writingDirection = try values.decodeIfPresent(WritingDirection.self, forKey: .writingDirection)
            ?? .automatic
        textColorHex = Self.normalizedHexColor(
            try values.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#111111",
            fallback: "#111111"
        )
        textAlignment = try values.decodeIfPresent(DialogueTextAlignment.self, forKey: .textAlignment)
            ?? .center
        strokeColorHex = Self.normalizedHexColor(
            try values.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#FFFFFF",
            fallback: "#FFFFFF"
        )
        strokeWidth = min(max(try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0, 0), 20)
        opacity = min(max(try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1, 0), 1)
        rotationDegrees = min(
            max(try values.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0, -180),
            180
        )
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
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

public enum TranslationLengthMode: String, Codable, CaseIterable, Hashable, Sendable {
    case faithful
    case balanced
    case compact
}

public enum TranslationQAFlag: String, Codable, CaseIterable, Hashable, Sendable {
    case missingTranslation
    case glossaryMismatch
    case numberMismatch
    case excessiveLength
    case modelUncertain
    case sourceTextLeak
    case reviewAdjusted
}

public struct TranslationQualityOptions: Codable, Hashable, Sendable {
    public var usePageContext: Bool
    public var reviewPassEnabled: Bool
    public var qualityCheckEnabled: Bool
    public var preserveLiteralTranslation: Bool
    public var lengthMode: TranslationLengthMode
    public var styleGuide: String

    public init(
        usePageContext: Bool = true,
        reviewPassEnabled: Bool = false,
        qualityCheckEnabled: Bool = true,
        preserveLiteralTranslation: Bool = true,
        lengthMode: TranslationLengthMode = .balanced,
        styleGuide: String = ""
    ) {
        self.usePageContext = usePageContext
        self.reviewPassEnabled = reviewPassEnabled
        self.qualityCheckEnabled = qualityCheckEnabled
        self.preserveLiteralTranslation = preserveLiteralTranslation
        self.lengthMode = lengthMode
        self.styleGuide = String(styleGuide.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
    }
}

public struct DialogueRegion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// VLM／Agent 找到的來源文字區域，也是譯文的預設排版錨點。
    public var bounds: NormalizedRect
    /// 對話框內緣；已知時自動遮罩與譯文都不得超出。
    /// nil 代表尚未偵測到對話框，此時遮罩只依 maskExpansion 由文字向外擴張。
    public var bubbleBounds: NormalizedRect?
    /// 對話框的實際形狀，以軸對齊矩形集合表示，座標以左上角為原點。
    /// 分割模型能給出形狀時才有值；空陣列代表只知道 `bubbleBounds` 這個矩形。
    /// 圓形對話框的矩形框四角其實是畫面內容，用形狀裁切才不會把人物捲進遮罩。
    public var bubbleMaskPolygons: [[NormalizedPoint]]
    /// 完全落在對話框形狀內的最大矩形，譯文排版的預設安全範圍。
    /// 與 `bubbleBounds` 分開：後者同時是遮罩搜尋邊界，縮小它會讓貼著弧線的字漏遮。
    public var bubbleLayoutBounds: NormalizedRect?
    /// 由字形排列量出來的書寫方向，`automatic` 代表量不出來。
    /// 與 `style.writingDirection` 分開：那是使用者偏好，會被 `defaultStyle` 覆寫；
    /// 這是對這張圖的觀測結果，只在使用者選 automatic 時用來決定實際排版方向。
    public var detectedWritingDirection: WritingDirection
    /// VLM、Agent 或人工最初提供的文字，人工修改 sourceText 時不覆寫。
    public var rawSourceText: String?
    /// 供詞表比對與翻譯使用的來源文字。
    public var sourceText: String
    /// 相容舊 `.str` 的完成標記；新流程代表來源文字已由 VLM、Agent 或人工確認。
    public var ocrTextRefined: Bool
    /// 忠實保留語意的直譯稿；最終排版仍使用 translatedText。
    public var literalTranslatedText: String?
    public var translatedText: String
    public var speakerID: String?
    public var tone: String?
    public var translationConfidence: Double?
    public var translationQAFlags: [TranslationQAFlag]
    public var translationAnchor: NormalizedPoint?
    public var translationBounds: NormalizedRect?
    public var confidence: Double
    public var style: DialogueStyle
    public var automaticMaskEnabled: Bool
    /// 自動遮罩的多邊形集合；每個多邊形至少三點，座標以左上角為原點。
    public var maskPolygons: [[NormalizedPoint]]
    /// true 代表封閉區域或 Agent 粗框已經像素級文字元件精修。
    public var maskRefinementApplied: Bool
    /// 像素精修保留下來的前景筆畫比例；nil 代表尚未執行自動覆蓋檢查。
    public var maskCoverageRatio: Double?
    /// true 代表目前搜尋範圍沒有截斷文字，且前景筆畫覆蓋率已通過門檻。
    public var maskCoverageComplete: Bool
    public var maskStrokes: [MaskStroke]

    public init(
        id: UUID = UUID(),
        bounds: NormalizedRect,
        bubbleBounds: NormalizedRect? = nil,
        bubbleMaskPolygons: [[NormalizedPoint]] = [],
        bubbleLayoutBounds: NormalizedRect? = nil,
        detectedWritingDirection: WritingDirection = .automatic,
        rawSourceText: String? = nil,
        sourceText: String,
        ocrTextRefined: Bool = false,
        literalTranslatedText: String? = nil,
        translatedText: String = "",
        speakerID: String? = nil,
        tone: String? = nil,
        translationConfidence: Double? = nil,
        translationQAFlags: [TranslationQAFlag] = [],
        translationAnchor: NormalizedPoint? = nil,
        translationBounds: NormalizedRect? = nil,
        confidence: Double,
        style: DialogueStyle = DialogueStyle(),
        automaticMaskEnabled: Bool = true,
        maskPolygons: [[NormalizedPoint]] = [],
        maskRefinementApplied: Bool = false,
        maskCoverageRatio: Double? = nil,
        maskCoverageComplete: Bool = false,
        maskStrokes: [MaskStroke] = []
    ) {
        self.id = id
        self.bounds = bounds
        self.bubbleBounds = bubbleBounds?.clamped()
        self.bubbleMaskPolygons = bubbleMaskPolygons
        self.bubbleLayoutBounds = bubbleLayoutBounds?.clamped()
        self.detectedWritingDirection = detectedWritingDirection
        self.rawSourceText = rawSourceText
        self.sourceText = sourceText
        self.ocrTextRefined = ocrTextRefined
        self.literalTranslatedText = literalTranslatedText
        self.translatedText = translatedText
        self.speakerID = speakerID
        self.tone = tone
        self.translationConfidence = translationConfidence.map { min(max($0, 0), 1) }
        self.translationQAFlags = Array(Set(translationQAFlags)).sorted { $0.rawValue < $1.rawValue }
        self.translationAnchor = translationAnchor?.clamped()
        self.translationBounds = translationBounds?.clamped()
        self.confidence = confidence
        self.style = style
        self.automaticMaskEnabled = automaticMaskEnabled
        self.maskPolygons = maskPolygons
            .map { $0.map { $0.clamped() } }
            .filter { $0.count >= 3 }
        self.maskRefinementApplied = maskRefinementApplied
        self.maskCoverageRatio = maskCoverageRatio.map { min(max($0, 0), 1) }
        self.maskCoverageComplete = maskCoverageComplete
        self.maskStrokes = maskStrokes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bounds
        case bubbleBounds
        case bubbleMaskPolygons
        case bubbleLayoutBounds
        case detectedWritingDirection
        case rawSourceText
        case sourceText
        case ocrTextRefined
        case literalTranslatedText
        case translatedText
        case speakerID
        case tone
        case translationConfidence
        case translationQAFlags
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
        bounds = try values.decode(NormalizedRect.self, forKey: .bounds)
        bubbleBounds = try values.decodeIfPresent(NormalizedRect.self, forKey: .bubbleBounds)?.clamped()
        bubbleMaskPolygons = try values.decodeIfPresent(
            [[NormalizedPoint]].self, forKey: .bubbleMaskPolygons
        ) ?? []
        bubbleLayoutBounds = try values.decodeIfPresent(
            NormalizedRect.self, forKey: .bubbleLayoutBounds
        )?.clamped()
        detectedWritingDirection = try values.decodeIfPresent(
            WritingDirection.self, forKey: .detectedWritingDirection
        ) ?? .automatic
        rawSourceText = try values.decodeIfPresent(String.self, forKey: .rawSourceText)
        sourceText = try values.decode(String.self, forKey: .sourceText)
        ocrTextRefined = try values.decodeIfPresent(Bool.self, forKey: .ocrTextRefined) ?? false
        literalTranslatedText = try values.decodeIfPresent(String.self, forKey: .literalTranslatedText)
        translatedText = try values.decode(String.self, forKey: .translatedText)
        speakerID = try values.decodeIfPresent(String.self, forKey: .speakerID)
        tone = try values.decodeIfPresent(String.self, forKey: .tone)
        translationConfidence = try values.decodeIfPresent(
            Double.self,
            forKey: .translationConfidence
        ).map { min(max($0, 0), 1) }
        translationQAFlags = try values.decodeIfPresent(
            [TranslationQAFlag].self,
            forKey: .translationQAFlags
        ) ?? []
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
        automaticMaskEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticMaskEnabled) ?? true
        maskPolygons = try values.decodeIfPresent(
            [[NormalizedPoint]].self,
            forKey: .maskPolygons
        )?.map { $0.map { $0.clamped() } }.filter { $0.count >= 3 } ?? []
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

public struct ComicPage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var index: Int
    public var title: String
    public var sourceURL: URL
    /// 來源目錄下的相對路徑；用於避免同名檔案互相覆蓋。
    public var relativeSourcePath: String?
    public var backgroundURL: URL?
    /// 步驟三超解析後的乾淨背景；原尺寸 `backgroundURL` 保留作為遮罩預覽。
    public var superResolvedBackgroundURL: URL?
    public var maskURL: URL?
    public var stringTableURL: URL?
    public var translationPreviewURL: URL?
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
        self.superResolvedBackgroundURL = nil
        self.maskURL = nil
        self.stringTableURL = nil
        self.translationPreviewURL = nil
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
    /// 傳統去字修補使用的固定底紙顏色；可由專案設定或滴管更新。
    public var eraseColorHex: String
    public var useImageToImageRestoration: Bool
    public var preserveUntranslatedRegions: Bool
    /// 精細掃描：封閉區域偵測不到的地方（白底上的開口氣泡、無框台詞），
    /// 額外以網格逐塊送給圖生文模型辨識。會顯著增加每頁推論次數。
    public var fineScanEnabled: Bool
    public var translationQuality: TranslationQualityOptions

    public init(
        sourceLanguageCodes: [String] = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"],
        targetLanguageCode: String = TargetLanguageResolver.automaticCode,
        readingDirection: ReadingDirection = .rightToLeft,
        defaultStyle: DialogueStyle = DialogueStyle(),
        maskExpansion: Double = 0.035,
        eraseColorHex: String = "#FFFFFF",
        useImageToImageRestoration: Bool = false,
        preserveUntranslatedRegions: Bool = false,
        fineScanEnabled: Bool = false,
        translationQuality: TranslationQualityOptions = TranslationQualityOptions()
    ) {
        self.sourceLanguageCodes = sourceLanguageCodes
        self.targetLanguageCode = targetLanguageCode
        self.readingDirection = readingDirection
        self.defaultStyle = defaultStyle
        self.maskExpansion = maskExpansion
        self.eraseColorHex = DialogueStyle.normalizedHexColor(
            eraseColorHex,
            fallback: "#FFFFFF"
        )
        self.useImageToImageRestoration = useImageToImageRestoration
        self.preserveUntranslatedRegions = preserveUntranslatedRegions
        self.fineScanEnabled = fineScanEnabled
        self.translationQuality = translationQuality
    }

    /// 實際交給翻譯器、詞表與 Agent 的目標語言；手動選擇時維持原值。
    public var resolvedTargetLanguageCode: String {
        TargetLanguageResolver.resolve(targetLanguageCode)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLanguageCodes
        case targetLanguageCode
        case readingDirection
        case defaultStyle
        case maskExpansion
        case eraseColorHex
        case useImageToImageRestoration
        case preserveUntranslatedRegions
        case fineScanEnabled
        case translationQuality
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProcessingOptions()
        sourceLanguageCodes = try values.decodeIfPresent(
            [String].self, forKey: .sourceLanguageCodes
        ) ?? defaults.sourceLanguageCodes
        targetLanguageCode = try values.decodeIfPresent(
            String.self, forKey: .targetLanguageCode
        ) ?? defaults.targetLanguageCode
        readingDirection = try values.decodeIfPresent(
            ReadingDirection.self, forKey: .readingDirection
        ) ?? defaults.readingDirection
        defaultStyle = try values.decodeIfPresent(
            DialogueStyle.self, forKey: .defaultStyle
        ) ?? defaults.defaultStyle
        maskExpansion = try values.decodeIfPresent(
            Double.self, forKey: .maskExpansion
        ) ?? defaults.maskExpansion
        eraseColorHex = DialogueStyle.normalizedHexColor(
            try values.decodeIfPresent(String.self, forKey: .eraseColorHex)
                ?? defaults.eraseColorHex,
            fallback: defaults.eraseColorHex
        )
        useImageToImageRestoration = try values.decodeIfPresent(
            Bool.self, forKey: .useImageToImageRestoration
        ) ?? defaults.useImageToImageRestoration
        preserveUntranslatedRegions = try values.decodeIfPresent(
            Bool.self, forKey: .preserveUntranslatedRegions
        ) ?? defaults.preserveUntranslatedRegions
        // 舊專案沒有這個欄位；預設關閉，不會突然變慢。
        fineScanEnabled = try values.decodeIfPresent(
            Bool.self, forKey: .fineScanEnabled
        ) ?? defaults.fineScanEnabled
        translationQuality = try values.decodeIfPresent(
            TranslationQualityOptions.self,
            forKey: .translationQuality
        ) ?? defaults.translationQuality
    }
}

public struct PageDetectionResult: Codable, Hashable, Sendable {
    public var regions: [DialogueRegion]
    public var maskURL: URL
    /// 非致命的偵測問題；此時 regions 仍是可用的 VLM／Agent 結果。
    public var warnings: [String]

    public init(regions: [DialogueRegion], maskURL: URL, warnings: [String] = []) {
        self.regions = regions
        self.maskURL = maskURL
        self.warnings = warnings
    }
}
