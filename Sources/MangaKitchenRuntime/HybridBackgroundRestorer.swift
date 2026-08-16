import Foundation
import MangaKitchenCore

public actor HybridBackgroundRestorer: PageBackgroundRestoring {
    private let models: ModelRuntimeHub
    private let fallback: MetalBubbleCleaner

    public init(models: ModelRuntimeHub, metal: MetalContext) throws {
        self.models = models
        self.fallback = try MetalBubbleCleaner(metal: metal)
    }

    public func restoreBackground(
        sourceURL: URL,
        maskURL: URL,
        regions: [DialogueRegion],
        outputURL: URL,
        preferGenerativeModel: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [String] {
        if preferGenerativeModel, await models.isLoaded(.imageToImage) {
            do {
                try await models.generateImage(
                    inputURL: sourceURL,
                    maskURL: maskURL,
                    prompt: Self.inpaintingPrompt,
                    outputURL: outputURL,
                    progress: progress
                )
                return []
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await fallback.clean(
                    sourceURL: sourceURL,
                    maskURL: maskURL,
                    outputURL: outputURL,
                    progress: progress
                )
                return ["圖生圖背景修復失敗，已改用 Metal 鄰域修補：\(error.localizedDescription)"]
            }
        }

        try await fallback.clean(
            sourceURL: sourceURL,
            maskURL: maskURL,
            outputURL: outputURL,
            progress: progress
        )
        return preferGenerativeModel
            ? ["未載入圖生圖模型，本頁已使用 Metal 鄰域修補。"]
            : []
    }

    private static let inpaintingPrompt = """
    Picture 1 is the original comic page. If Picture 2 is present, it is a binary mask whose white
    areas cover existing letters. Remove only those letters. Reconstruct the speech-balloon paper,
    borders, screentone, and nearby line art continuously. Return an image without new text, symbols,
    characters, objects, or watermarks. Preserve everything outside the white mask exactly.
    """
}
