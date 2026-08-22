import CoreGraphics
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class OCRRegionTextRecognitionTests: XCTestCase {
    private actor StubLocator: LocalTextLocating {
        let modelID = "stub-locator"

        func locateText(in _: CGImage) async throws -> [TextLocalizationResult] {
            [
                Self.line(x: 0.62, y: 0.10, width: 0.14, height: 0.78),
                Self.line(x: 0.20, y: 0.12, width: 0.14, height: 0.76)
            ]
        }

        private static func line(
            x: Double,
            y: Double,
            width: Double,
            height: Double
        ) -> TextLocalizationResult {
            let bounds = NormalizedRect(x: x, y: y, width: width, height: height)
            return TextLocalizationResult(
                confidence: 0.9,
                polygon: [],
                bounds: bounds
            )
        }
    }

    private actor PositionOCR: LocalOCRRecognizing {
        let modelID = "position-ocr"

        func recognize(
            crop _: CGImage,
            bounds: NormalizedRect
        ) async throws -> OCRModelResult {
            let text = bounds.centerX > 0.3 ? "右" : "左"
            return OCRModelResult(
                modelID: modelID,
                text: text,
                confidence: 0.9,
                lines: [OCRTextLineResult(text: text, confidence: 0.9, bounds: bounds)],
                writingDirection: .vertical
            )
        }
    }

    private actor StubOCR: LocalOCRRecognizing {
        let modelID = "stub-ocr"
        let text: String

        init(text: String = "OCR 候選") {
            self.text = text
        }

        func recognize(
            crop: CGImage,
            bounds: NormalizedRect
        ) async throws -> OCRModelResult {
            OCRModelResult(
                modelID: modelID,
                text: text,
                confidence: 0.88,
                lines: [OCRTextLineResult(
                    text: text,
                    confidence: 0.88,
                    bounds: bounds
                )],
                writingDirection: .vertical
            )
        }
    }

    func testOCRCandidateDoesNotReplaceConfirmedSourceTextOrMask() async throws {
        let sourceURL = try makeSourceImage()
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let mask = [[
            NormalizedPoint(x: 0.12, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.5)
        ]]
        let region = DialogueRegion(
            bounds: bounds,
            rawSourceText: "VLM 原文",
            sourceText: "人工修正原文",
            ocrTextRefined: true,
            confidence: 1,
            maskPolygons: mask,
            maskRefinementApplied: true,
            maskCoverageComplete: true
        )
        let service = OCRRegionTextRecognitionService(ocr: StubOCR())
        let result = try await service.recognizeRegions(
            pageURL: sourceURL,
            regions: [region],
            sourceLanguageCodes: ["ja"],
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rawSourceText, "VLM 原文")
        XCTAssertEqual(result[0].sourceText, "人工修正原文")
        XCTAssertTrue(result[0].ocrTextRefined)
        XCTAssertEqual(result[0].maskPolygons, mask)
        XCTAssertEqual(result[0].ocrResults["stub-ocr"]?.text, "OCR 候選")
        XCTAssertEqual(result[0].ocrResults["stub-ocr"]?.lines.first?.bounds, bounds)
    }

    func testOCRCandidateBecomesSourceTextWithoutClaimingVLMRefinement() async throws {
        let sourceURL = try makeSourceImage()
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let mask = [[
            NormalizedPoint(x: 0.12, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.12),
            NormalizedPoint(x: 0.5, y: 0.5)
        ]]
        let region = DialogueRegion(
            bounds: bounds,
            sourceText: "",
            confidence: 1,
            maskPolygons: mask,
            maskRefinementApplied: true,
            maskCoverageComplete: true
        )
        let service = OCRRegionTextRecognitionService(ocr: StubOCR(text: "  独立 OCR 原文  "))
        let result = try await service.recognizeRegions(
            pageURL: sourceURL,
            regions: [region],
            sourceLanguageCodes: ["ja"],
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rawSourceText, "独立 OCR 原文")
        XCTAssertEqual(result[0].sourceText, "独立 OCR 原文")
        XCTAssertFalse(result[0].ocrTextRefined)
        XCTAssertEqual(result[0].detectedWritingDirection, .vertical)
        XCTAssertEqual(result[0].bounds, bounds)
        XCTAssertEqual(result[0].maskPolygons, mask)
        XCTAssertEqual(result[0].ocrResults["stub-ocr"]?.text, "  独立 OCR 原文  ")
    }

    func testMissingBundledOCRFailsInsteadOfFallingBackToVLM() async {
        let recognizer = UnavailableOCRRegionTextRecognizer()
        do {
            _ = try await recognizer.recognizeRegions(
                pageURL: URL(fileURLWithPath: "/tmp/missing-page.png"),
                regions: [],
                sourceLanguageCodes: ["ja"],
                regionProgress: { _, _ in },
                progress: { _ in }
            )
            XCTFail("缺少 OCR runtime 應明確失敗，不可暗中改走 VLM。")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("PP-OCR"))
        }
    }

    func testVerticalColumnsAreRecognizedSeparatelyAndMergedRightToLeft() async throws {
        let sourceURL = try makeSourceImage()
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.7)
        let mask = [[
            NormalizedPoint(x: 0.12, y: 0.12),
            NormalizedPoint(x: 0.58, y: 0.12),
            NormalizedPoint(x: 0.58, y: 0.75)
        ]]
        let region = DialogueRegion(
            bounds: bounds,
            detectedWritingDirection: .vertical,
            sourceText: "",
            confidence: 1,
            maskPolygons: mask,
            maskRefinementApplied: true,
            maskCoverageComplete: true
        )
        let service = OCRRegionTextRecognitionService(
            ocr: PositionOCR(),
            locator: StubLocator()
        )
        let result = try await service.recognizeRegions(
            pageURL: sourceURL,
            regions: [region],
            sourceLanguageCodes: ["ja"],
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(result[0].sourceText, "右左")
        XCTAssertEqual(result[0].ocrResults["position-ocr"]?.lines.count, 2)
        XCTAssertGreaterThan(
            result[0].ocrResults["position-ocr"]?.lines[0].bounds.centerX ?? 0,
            result[0].ocrResults["position-ocr"]?.lines[1].bounds.centerX ?? 1
        )
        XCTAssertEqual(result[0].bounds, bounds)
        XCTAssertEqual(result[0].maskPolygons, mask)
    }

    private func makeSourceImage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-OCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(image, to: sourceURL)
        return sourceURL
    }
}
