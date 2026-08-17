import Foundation

public typealias InferenceProgress = @Sendable (Double) -> Void
public typealias PagePipelineProgress = @Sendable (PageProcessingStage, Double) -> Void
public typealias PagePipelineActivity = @Sendable (PageProcessingActivity) -> Void

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

public protocol PageTextRecognizing: Sendable {
    func recognizeText(
        in imageURL: URL,
        languageCodes: [String],
        readingDirection: ReadingDirection
    ) async throws -> [DialogueRegion]
}

/// 以影像語意補足並分類工作流要處理的主要文字區域。
/// 實作必須將既有 OCR、影像語意與封閉區域候選合併及去重後輸出；失敗時
/// 呼叫端必須讓本階段失敗，不可把未完成的局部結果當成完整清單。
public protocol SemanticRegionDetecting: Sendable {
    func detectRegions(
        pageURL: URL,
        existingRegions: [DialogueRegion],
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
}

/// 使用整頁影像語境校正 OCR 誤字；只修正辨識結果，不翻譯或改寫內容。
public protocol OCRTextRefining: Sendable {
    func refineOCRText(
        regions: [DialogueRegion],
        pageURL: URL,
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
}

/// 將 OCR 的粗略區域收斂成實際文字筆畫附近的多邊形集合。
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
        outputURL: URL,
        preferGenerativeModel: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [String]
}

public protocol DialogueTypesetting: Sendable {
    func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL
    ) async throws
}

public protocol ModelManaging: Sendable {
    func loadModel(at directoryURL: URL) async throws -> LoadedModelInfo
    func unloadModel(capability: ModelCapability) async
    func loadedModels() async -> [LoadedModelInfo]
}
