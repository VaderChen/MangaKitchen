import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class PPOCRTextDetectionRuntimeTests: XCTestCase {
    func testTouchingBalloonLinesRemainSeparateOCRRegions() {
        let graduation = textLine(
            x: 0.4128, y: 0.0976,
            width: 0.0368, height: 0.0895
        )
        let reunion = textLine(
            x: 0.3437, y: 0.1563,
            width: 0.0376, height: 0.1166
        )

        let groups = PPOCRTextRegionDetector.groupedTextLines([graduation, reunion])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.count), [1, 1])
    }

    func testAlignedVerticalColumnsInOneBalloonStayGrouped() {
        let rightColumn = textLine(
            x: 0.40, y: 0.10,
            width: 0.035, height: 0.15
        )
        let leftColumn = textLine(
            x: 0.36, y: 0.105,
            width: 0.034, height: 0.14
        )

        let groups = PPOCRTextRegionDetector.groupedTextLines([rightColumn, leftColumn])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testBundledMediumDetectorFindsKnownJapaneseDialogue() async throws {
        let root = projectRoot()
        let modelURL = root
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/TextLocalization")
            .appendingPathComponent("ppocrv6-medium-det-736x480-macos14.mlpackage")
        let source = try CGImageIO.load(
            from: root.appendingPathComponent("Samples/Gemini_Image_002.jpeg")
        )
        let runtime = try PPOCRTextDetectionRuntime(modelURL: modelURL)
        let results = try await runtime.locateText(in: source)

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { result in
            result.confidence >= 0 && result.confidence <= 1
                && result.bounds.minX >= 0 && result.bounds.maxX <= 1
                && result.bounds.minY >= 0 && result.bounds.maxY <= 1
                && result.bounds.width > 0 && result.bounds.height > 0
                && result.polygon.count == 4
        })

        // 人工校對的「あれは…！」文字行中心；確認 Core ML 輸出已正確反算回原頁。
        let expectedCenter = NormalizedPoint(
            x: 1_452.0 / Double(source.width),
            y: 273.0 / Double(source.height)
        )
        XCTAssertTrue(results.contains { result in
            result.bounds.minX <= expectedCenter.x
                && result.bounds.maxX >= expectedCenter.x
                && result.bounds.minY <= expectedCenter.y
                && result.bounds.maxY >= expectedCenter.y
        })
    }

    func testRegionAdapterOnlyReturnsTextInsideConfirmedBubbles() async throws {
        let root = projectRoot()
        let detectorModelURL = root
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/TextLocalization")
            .appendingPathComponent("ppocrv6-medium-det-736x480-macos14.mlpackage")
        let bubbleModelURL = root
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models")
            .appendingPathComponent("MangaBubbleSegmentation.mlpackage")
        let locator = try PPOCRTextDetectionRuntime(modelURL: detectorModelURL)
        let bubbleSegmenter = try MangaBubbleSegmentationCoreMLRuntime(
            modelURL: bubbleModelURL
        )
        let detector = PPOCRTextRegionDetector(
            locator: locator,
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
                && region.maskPolygons.isEmpty
        })
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func textLine(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> TextLocalizationResult {
        let bounds = NormalizedRect(x: x, y: y, width: width, height: height)
        return TextLocalizationResult(
            confidence: 0.9,
            polygon: [
                NormalizedPoint(x: bounds.minX, y: bounds.minY),
                NormalizedPoint(x: bounds.maxX, y: bounds.minY),
                NormalizedPoint(x: bounds.maxX, y: bounds.maxY),
                NormalizedPoint(x: bounds.minX, y: bounds.maxY)
            ],
            bounds: bounds
        )
    }
}
