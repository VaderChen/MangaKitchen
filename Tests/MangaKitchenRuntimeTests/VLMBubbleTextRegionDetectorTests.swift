import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class VLMBubbleTextRegionDetectorTests: XCTestCase {
    private actor StubGroundingModel: ImageToTextGenerating {
        private(set) var prompts: [String] = []

        func generateText(
            imageURL _: URL,
            prompt: String,
            maximumOutputTokens _: Int?,
            progress: @escaping InferenceProgress
        ) async throws -> String {
            prompts.append(prompt)
            progress(1)
            return #"[{"bbox_2d":[250,250,750,750]}]"#
        }
    }

    func testVLMLocalizerOnlyCreatesRegionsFromConfirmedBubbleCrops() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bubbleSegmenter = try MangaBubbleSegmentationCoreMLRuntime(
            modelURL: root
                .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models")
                .appendingPathComponent("MangaBubbleSegmentation.mlpackage")
        )
        let model = StubGroundingModel()
        let detector = VLMBubbleTextRegionDetector(
            model: model,
            bubbleSegmenter: bubbleSegmenter
        )
        let regions = try await detector.detectRegions(
            pageURL: root.appendingPathComponent("Samples/Gemini_Image_002.jpeg"),
            sourceLanguageCodes: ["ja-JP"],
            fineScanEnabled: false,
            progress: { _ in }
        )

        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(regions.allSatisfy { region in
            region.bubbleBounds != nil
                && region.bounds.width > 0
                && region.bounds.height > 0
                && region.sourceText.isEmpty
        })
        let prompts = await model.prompts
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy {
            $0.contains("Do not include sound effects")
                && $0.contains("Do not transcribe, translate, classify")
        })
    }
}
