import Foundation
import MangaKitchenCore

public actor HybridBackgroundRestorer: PageBackgroundRestoring {
    private let models: ModelRuntimeHub
    private let gpuFallback: MetalBubbleCleaner
    private let cpuFallback = CPUBubbleCleaner()
    private var compositingBackend: ImageCompositingBackend

    public init(
        models: ModelRuntimeHub,
        metal: MetalContext,
        compositingBackend: ImageCompositingBackend = .cpu
    ) throws {
        self.models = models
        self.gpuFallback = try MetalBubbleCleaner(metal: metal)
        self.compositingBackend = compositingBackend
    }

    public func setCompositingBackend(_ backend: ImageCompositingBackend) {
        compositingBackend = backend
    }

    public func restoreBackground(
        sourceURL: URL,
        maskURL: URL,
        regions: [DialogueRegion],
        fillColorHex: String,
        outputURL: URL,
        preferGenerativeModel: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [String] {
        var warnings: [String] = []
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
                warnings.append("圖生圖背景修復失敗：\(error.localizedDescription)")
            }
        } else if preferGenerativeModel {
            warnings.append("未載入圖生圖模型。")
        }

        let configuredFillColor = ProcessingOptions.normalizedEraseColor(
            fillColorHex,
            fallback: ProcessingOptions.automaticEraseColor
        )
        if configuredFillColor != ProcessingOptions.automaticEraseColor {
            // 專案已指定底紙顏色時直接精確填色，不再讓 CPU／Metal 猜測紙面亮度。
            try await cpuFallback.clean(
                sourceURL: sourceURL,
                maskURL: maskURL,
                regions: regions,
                fillColorHex: configuredFillColor,
                outputURL: outputURL,
                progress: progress
            )
            warnings.append("本頁已使用專案抹除底色修補。")
            return warnings
        }

        switch compositingBackend {
        case .cpu:
            try await cpuFallback.clean(
                sourceURL: sourceURL,
                maskURL: maskURL,
                regions: regions,
                outputURL: outputURL,
                progress: progress
            )
            warnings.append("本頁已使用 CPU 主色修補。")

        case .gpu:
            do {
                try await gpuFallback.clean(
                    sourceURL: sourceURL,
                    maskURL: maskURL,
                    outputURL: outputURL,
                    progress: { progress($0 * 0.75) }
                )
                // Metal 完成大量像素修補後，再依文字區域統一底色；避免每個
                // 像素的局部取樣差異在大片白底上形成顆粒。
                try await cpuFallback.clean(
                    sourceURL: outputURL,
                    maskURL: maskURL,
                    regions: regions,
                    outputURL: outputURL,
                    progress: { progress(0.75 + $0 * 0.25) }
                )
                warnings.append("本頁已使用 GPU／Metal 鄰域修補。")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await cpuFallback.clean(
                    sourceURL: sourceURL,
                    maskURL: maskURL,
                    regions: regions,
                    outputURL: outputURL,
                    progress: progress
                )
                warnings.append("GPU 合成失敗，已自動改用 CPU：\(error.localizedDescription)")
            }
        }
        return warnings
    }

    private static let inpaintingPrompt = """
    Picture 1 is the original comic page. If Picture 2 is present, it is a binary mask whose white
    areas cover existing letters. Remove only those letters. Reconstruct the speech-balloon paper,
    borders, screentone, and nearby line art continuously. Return an image without new text, symbols,
    characters, objects, or watermarks. Preserve everything outside the white mask exactly.
    """
}
