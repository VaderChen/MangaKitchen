import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

/// 集中解析 App bundle 內建模型，避免 GUI 與 MCP 各自建立一份 Core ML runtime。
enum BundledModelFactory {
    static func bubbleSegmenter() -> MangaBubbleSegmentationCoreMLRuntime? {
        guard let modelURL = Bundle.module.url(
            forResource: "MangaBubbleSegmentation",
            withExtension: "mlpackage",
            subdirectory: "Models"
        ) else {
            return nil
        }
        return try? MangaBubbleSegmentationCoreMLRuntime(modelURL: modelURL)
    }

    static func textLocalizationRuntime() -> PPOCRTextDetectionRuntime? {
        guard let modelURL = Bundle.module.url(
            forResource: "ppocrv6-medium-det-736x480-macos14",
            withExtension: "mlpackage",
            subdirectory: "Models/TextLocalization"
        ) else {
            return nil
        }
        return try? PPOCRTextDetectionRuntime(modelURL: modelURL)
    }

    /// 預設優先使用 Medium recognizer；資源不可用時回退 Small。
    static func ocrRuntime() -> PPOCRRecognitionRuntime? {
        let candidates = [
            (
                modelID: "ppocrv6-medium-rec",
                modelResource: "ppocrv6-medium-rec-macos14",
                characterResource: "ppocrv6-medium-rec-characters"
            ),
            (
                modelID: "ppocrv6-small-rec",
                modelResource: "ppocrv6-small-rec-macos14",
                characterResource: "ppocrv6-small-rec-characters"
            )
        ]

        for candidate in candidates {
            guard let modelURL = Bundle.module.url(
                forResource: candidate.modelResource,
                withExtension: "mlpackage",
                subdirectory: "Models/OCR"
            ), let characterURL = Bundle.module.url(
                forResource: candidate.characterResource,
                withExtension: "json",
                subdirectory: "Models/OCR"
            ), let characters = try? PPOCRCharacterList.load(from: characterURL),
            let runtime = try? PPOCRRecognitionRuntime(
                modelURL: modelURL,
                modelID: candidate.modelID,
                characters: characters
            ) else {
                continue
            }
            return runtime
        }
        return nil
    }
}
