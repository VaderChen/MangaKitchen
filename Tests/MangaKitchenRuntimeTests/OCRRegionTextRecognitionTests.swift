import CoreGraphics
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class OCRRegionTextRecognitionTests: XCTestCase {
    private actor StubLocator: RegionTextRecognizing {
        func recognizeRegions(
            pageURL: URL,
            regions: [DialogueRegion],
            sourceLanguageCodes: [String],
            regionProgress: @escaping PageRegionProgress,
            progress: @escaping InferenceProgress
        ) async throws -> [DialogueRegion] {
            regionProgress(regions.count, regions.count)
            progress(1)
            return regions
        }
    }

    private actor StubOCR: LocalOCRRecognizing {
        let modelID = "stub-ocr"

        func recognize(
            crop: CGImage,
            bounds: NormalizedRect
        ) async throws -> OCRModelResult {
            OCRModelResult(
                modelID: modelID,
                text: "OCR 候選",
                confidence: 0.88,
                lines: [OCRTextLineResult(
                    text: "OCR 候選",
                    confidence: 0.88,
                    bounds: bounds
                )]
            )
        }
    }

    func testOCRCandidateDoesNotReplaceVLMTextOrMask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-OCR-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("page.png")
        guard let context = CGContext(
            data: nil,
            width: 40,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ), let image = context.makeImage() else {
            XCTFail("無法建立測試圖片")
            return
        }
        try CGImageIO.writePNG(image, to: sourceURL)

        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let mask = [[
            NormalizedPoint(x: 0.12, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.5)
        ]]
        let region = DialogueRegion(
            bounds: bounds,
            sourceText: "VLM 原文",
            confidence: 1,
            maskPolygons: mask,
            maskRefinementApplied: true,
            maskCoverageComplete: true
        )
        let service = OCRRegionTextRecognitionService(
            locator: StubLocator(),
            ocr: StubOCR()
        )
        let result = try await service.recognizeRegions(
            pageURL: sourceURL,
            regions: [region],
            sourceLanguageCodes: ["ja"],
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sourceText, "VLM 原文")
        XCTAssertEqual(result[0].maskPolygons, mask)
        XCTAssertEqual(result[0].ocrResults["stub-ocr"]?.text, "OCR 候選")
        XCTAssertEqual(result[0].ocrResults["stub-ocr"]?.lines.first?.bounds, bounds)
    }
}
