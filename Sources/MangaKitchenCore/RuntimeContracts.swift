import CoreGraphics
import Foundation

public typealias InferenceProgress = @Sendable (Double) -> Void
public typealias PagePipelineProgress = @Sendable (PageProcessingStage, Double) -> Void
public typealias PagePipelineActivity = @Sendable (PageProcessingActivity) -> Void
public typealias PageRegionProgress = @Sendable (Int, Int) -> Void

public enum RuntimeLogLevel: String, Codable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Runtime 只回報記憶體內的診斷訊息；是否顯示與保留筆數由 App 層決定。
public typealias RuntimeLogHandler = @Sendable (
    RuntimeLogLevel,
    String,
    String
) -> Void

/// Thinking 的即時內容只供當前處理 DLG 顯示，不屬於診斷 LOG，
/// 也不得寫入偏好設定或專案檔。
public enum RuntimeReasoningStreamEvent: Sendable {
    case started(id: UUID)
    case updated(id: UUID, text: String)
    case finished(id: UUID)
}

public typealias RuntimeReasoningStreamHandler = @Sendable (
    RuntimeReasoningStreamEvent
) -> Void

/// 純文字生成模型；不接受圖片，可作為後續本機翻譯引擎。
public protocol TextGenerating: Sendable {
    func generateText(
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String
}

public extension TextGenerating {
    func generateText(
        prompt: String,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        try await generateText(
            prompt: prompt,
            maximumOutputTokens: nil,
            progress: progress
        )
    }
}

public protocol ImageToTextGenerating: Sendable {
    func generateText(
        imageURL: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String
}

public extension ImageToTextGenerating {
    func generateText(
        imageURL: URL,
        prompt: String,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        try await generateText(
            imageURL: imageURL,
            prompt: prompt,
            maximumOutputTokens: nil,
            progress: progress
        )
    }
}

public protocol ImageToImageGenerating: Sendable {
    func generateImage(
        inputURL: URL,
        maskURL: URL?,
        prompt: String,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws
}

public protocol ImageColorizing: Sendable {
    func colorize(
        inputURL: URL,
        maskURL: URL?,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws
}

public protocol ImageSuperResolving: Sendable {
    func superResolve(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws
}

/// 從影像候選建立供像素遮罩精修使用的區域。
public protocol SemanticRegionDetecting: Sendable {
    func detectRegions(
        pageURL: URL,
        sourceLanguageCodes: [String],
        fineScanEnabled: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
}

/// 在既有遮罩區域內分類並轉錄原文，不得更動區域 ID、遮罩或人工筆劃。
public protocol RegionTextRecognizing: Sendable {
    func recognizeRegions(
        pageURL: URL,
        regions: [DialogueRegion],
        sourceLanguageCodes: [String],
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
}

/// 單一文字行的定位結果，不包含轉錄文字，也不直接修改專案區域。
public struct TextLocalizationResult: Codable, Hashable, Sendable {
    public var confidence: Double
    public var polygon: [NormalizedPoint]
    public var bounds: NormalizedRect

    public init(
        confidence: Double,
        polygon: [NormalizedPoint],
        bounds: NormalizedRect
    ) {
        self.confidence = min(max(confidence, 0), 1)
        self.polygon = polygon.map { $0.clamped() }
        self.bounds = bounds.clamped()
    }
}

/// 只負責在傳入影像中產生文字行座標的本機模型；主流程只會傳入已確認的對話框裁切。
///
/// 結果是獨立候選；呼叫端必須明確選擇定位來源後才能把它轉成專案區域，
/// 不得在 OCR、翻譯或遮罩階段暗中重跑定位。
public protocol LocalTextLocating: Sendable {
    var modelID: String { get }

    func locateText(in image: CGImage) async throws -> [TextLocalizationResult]
}

/// 未來「對話框外狀聲字」流程的獨立候選，不得混入 `DialogueRegion` 或對話遮罩。
public struct SoundEffectLocalizationResult: Codable, Hashable, Sendable {
    public var confidence: Double
    public var polygon: [NormalizedPoint]
    public var bounds: NormalizedRect

    public init(
        confidence: Double,
        polygon: [NormalizedPoint],
        bounds: NormalizedRect
    ) {
        self.confidence = min(max(confidence, 0), 1)
        self.polygon = polygon.map { $0.clamped() }
        self.bounds = bounds.clamped()
    }
}

/// 預留給未來狀聲字處理的獨立 detector。
///
/// 它只掃描既有對話區域之外的畫面；目前主 Pipeline 不持有也不呼叫此契約。
public protocol SoundEffectRegionDetecting: Sendable {
    func detectSoundEffects(
        pageURL: URL,
        excluding dialogueRegions: [DialogueRegion],
        progress: @escaping InferenceProgress
    ) async throws -> [SoundEffectLocalizationResult]
}

/// 以原生本機模型辨識一個已由步驟二定位的對話文字裁切。
///
/// 實作只回傳該模型自己的候選結果；呼叫端必須保留模型 ID、信心與文字行資料，
/// 且不得藉此改動區域或遮罩。是否將候選採用為正式原文，由上層流程明確決定。
public protocol LocalOCRRecognizing: Sendable {
    var modelID: String { get }

    func recognize(
        crop: CGImage,
        bounds: NormalizedRect
    ) async throws -> OCRModelResult
}

/// 將封閉區域或 Agent 粗框收斂成實際文字筆畫附近的多邊形集合。
public protocol DialogueMaskRefining: Sendable {
    func refineMasks(
        sourceURL: URL,
        regions: [DialogueRegion]
    ) async throws -> [DialogueRegion]
}

public protocol RegionTranslating: Sendable {
    func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        readingDirection: ReadingDirection,
        qualityOptions: TranslationQualityOptions,
        activity: @escaping PagePipelineActivity,
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
}

public protocol DialogueMaskGenerating: Sendable {
    func generateMask(
        sourceURL: URL,
        regions: [DialogueRegion],
        expansion: Double,
        outputURL: URL
    ) async throws
}

public protocol PageBackgroundRestoring: Sendable {
    func restoreBackground(
        sourceURL: URL,
        maskURL: URL,
        regions: [DialogueRegion],
        fillColorHex: String,
        outputURL: URL,
        preferGenerativeModel: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [String]
}

public protocol DialogueTypesetting: Sendable {
    func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL,
        renderScale: Double
    ) async throws
}

public extension DialogueTypesetting {
    func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL
    ) async throws {
        try await typeset(
            backgroundURL: backgroundURL,
            regions: regions,
            outputURL: outputURL,
            renderScale: 1
        )
    }
}

public protocol ModelManaging: Sendable {
    func loadModel(at directoryURL: URL) async throws -> LoadedModelInfo
    func unloadModel(capability: ModelCapability) async
    func loadedModels() async -> [LoadedModelInfo]
}
