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
            modelID: "ppocrv6-small-rec",
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
            modelID: "ppocrv6-small-rec",
            characters: characters
        )
        let result = try await runtime.recognize(
            crop: crop,
            bounds: NormalizedRect(x: 0.8, y: 0.05, width: 0.1, height: 0.2)
        )
        XCTAssertTrue(result.text.hasPrefix("あれは"))
    }

    func testBundledMediumPPRecognizerReadsVerticalJapaneseCrop() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelDirectory = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/OCR")
        let characters = try PPOCRCharacterList.load(
            from: modelDirectory.appendingPathComponent("ppocrv6-medium-rec-characters.json")
        )
        let smallCharacters = try PPOCRCharacterList.load(
            from: modelDirectory.appendingPathComponent("ppocrv6-small-rec-characters.json")
        )
        XCTAssertEqual(characters, smallCharacters)

        let modelURL = modelDirectory.appendingPathComponent("ppocrv6-medium-rec-macos14.mlpackage")
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
        XCTAssertEqual(result.modelID, "ppocrv6-medium-rec")
        XCTAssertTrue(result.text.hasPrefix("あれは"))
    }

    func testBundledMediumDetectorAndRecognizerReadMultiColumnRegions() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelDirectory = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/OCR")
        let detectorDirectory = projectRoot
            .appendingPathComponent("Sources/MangaKitchenApp/Resources/Models/TextLocalization")
        let recognizer = try PPOCRRecognitionRuntime(
            modelURL: modelDirectory.appendingPathComponent(
                "ppocrv6-medium-rec-macos14.mlpackage"
            ),
            characters: try PPOCRCharacterList.load(
                from: modelDirectory.appendingPathComponent(
                    "ppocrv6-medium-rec-characters.json"
                )
            )
        )
        let locator = try PPOCRTextDetectionRuntime(
            modelURL: detectorDirectory.appendingPathComponent(
                "ppocrv6-medium-det-736x480-macos14.mlpackage"
            )
        )
        let bounds = [
            NormalizedRect(
                x: 0.4570596797671033,
                y: 0.078125,
                width: 0.11208151382823878,
                height: 0.09375
            ),
            NormalizedRect(
                x: 0.0858806404657933,
                y: 0.078125,
                width: 0.14410480349344978,
                height: 0.0947265625
            ),
            NormalizedRect(
                x: 0.08879184861717612,
                y: 0.62109375,
                width: 0.10189228529839883,
                height: 0.1171875
            )
        ]
        let regions = bounds.map {
            DialogueRegion(
                bounds: $0,
                detectedWritingDirection: .vertical,
                sourceText: "",
                confidence: 1
            )
        }
        let recognized = try await OCRRegionTextRecognitionService(
            ocr: recognizer,
            locator: locator
        ).recognizeRegions(
            pageURL: projectRoot.appendingPathComponent("Samples/Gemini_Image_001.jpeg"),
            regions: regions,
            sourceLanguageCodes: ["ja-JP"],
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertTrue(recognized.allSatisfy {
            !$0.sourceText.isEmpty
                && ($0.ocrResults["ppocrv6-medium-rec"]?.lines.count ?? 0) >= 2
        })
    }
}
