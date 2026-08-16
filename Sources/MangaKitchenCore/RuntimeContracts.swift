import Foundation

public typealias InferenceProgress = @Sendable (Double) -> Void
public typealias PagePipelineProgress = @Sendable (PageProcessingStage, Double) -> Void

public protocol ImageToTextGenerating: Sendable {
    func generateText(imageURL: URL, prompt: String, progress: @escaping InferenceProgress) async throws -> String
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
