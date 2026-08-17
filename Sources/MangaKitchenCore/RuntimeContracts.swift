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

/// 從封閉區域候選辨識、分類並轉錄工作流要處理的主要文字區域。
/// 失敗時呼叫端必須讓本階段失敗，不可把未完成的局部結果當成完整清單。
public protocol SemanticRegionDetecting: Sendable {
    func detectRegions(
        pageURL: URL,
        sourceLanguageCodes: [String],
        fineScanEnabled: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion]
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
