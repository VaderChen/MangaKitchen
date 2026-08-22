import CoreGraphics
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class PPOCRRecognitionRuntimeTests: XCTestCase {
    func testBundledPPRecognizerRunsWithNativeCoreML() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelURL = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/OCR")
            .appendingPathComponent("ppocrv6-small-rec-macos14.mlpackage")
        let charactersURL = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/OCR")
            .appendingPathComponent("ppocrv6-small-rec-characters.json")
        let characters = try PPOCRCharacterList.load(from: charactersURL)
        let runtime = try PPOCRRecognitionRuntime(
            modelURL: modelURL,
            characters: characters
        )

        guard let context = CGContext(
            data: nil,
            width: 80,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ), let image = context.makeImage() else {
            XCTFail("無法建立 OCR 測試圖片")
            return
        }
        let result = try await runtime.recognize(
            crop: image,
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )

        XCTAssertEqual(result.modelID, "ppocrv6-small-rec")
        XCTAssertEqual(result.lines.isEmpty, result.text.isEmpty)
    }

    func testBundledPPRecognizerReadsVerticalJapaneseCrop() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelDirectory = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/OCR")
        let characters = try PPOCRCharacterList.load(
            from: modelDirectory.appendingPathComponent("ppocrv6-small-rec-characters.json")
        )
        let modelURL = modelDirectory.appendingPathComponent("ppocrv6-small-rec-macos14.mlpackage")
        let source = try CGImageIO.load(
            from: projectRoot.appendingPathComponent("Samples/Gemini_Image_002.jpeg")
        )
        guard let crop = source.cropping(to: CGRect(x: 1420, y: 139, width: 71, height: 256)) else {
            XCTFail("無法裁切直排 OCR 測試區域")
            return
        }
        let runtime = try PPOCRRecognitionRuntime(
            modelURL: modelURL,
            characters: characters
        )
        let result = try await runtime.recognize(
            crop: crop,
            bounds: NormalizedRect(x: 0.8, y: 0.05, width: 0.1, height: 0.2)
        )
        XCTAssertTrue(result.text.hasPrefix("あれは"))
    }
}
