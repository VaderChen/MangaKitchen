import XCTest
import MangaKitchenCore

final class ComicStringTablePersistenceTests: XCTestCase {
    func testBubbleShapeSurvivesStrRoundTrip() throws {
        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            bubbleBounds: NormalizedRect(x: 0.09, y: 0.09, width: 0.22, height: 0.22),
            bubbleMaskPolygons: [[
                NormalizedPoint(x: 0.12, y: 0.12), NormalizedPoint(x: 0.28, y: 0.12),
                NormalizedPoint(x: 0.28, y: 0.14), NormalizedPoint(x: 0.12, y: 0.14)
            ]],
            bubbleLayoutBounds: NormalizedRect(x: 0.12, y: 0.12, width: 0.16, height: 0.16),
            sourceText: "テスト",
            mcpExtractedSourceText: "MCP 原文",
            confidence: 1
        )
        let table = ComicStringTable(
            sourceRelativePath: "p.jpg", pixelWidth: 100, pixelHeight: 100,
            targetLanguageCode: "zh-Hant",
            entries: [ComicStringEntry(order: 0, region: region)]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            ComicStringTable.self, from: try encoder.encode(table)
        ).regions[0]

        XCTAssertEqual(restored.bubbleMaskPolygons.count, 1)
        XCTAssertEqual(restored.bubbleMaskPolygons.first?.count, 4)
        XCTAssertEqual(restored.bubbleLayoutBounds?.width ?? 0, 0.16, accuracy: 1e-9)
        XCTAssertEqual(restored.mcpExtractedSourceText, "MCP 原文")
    }

    func testLegacyStrWithoutBubbleShapeStillDecodes() throws {
        let legacy = """
        {"schemaVersion":1,"sourceRelativePath":"p.jpg","pixelWidth":100,"pixelHeight":100,
         "targetLanguageCode":"zh-Hant","updatedAt":"2026-08-18T00:00:00Z",
         "entries":[{"id":"9E5B4C3A-1111-2222-3333-444455556666","order":0,
         "bounds":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},"sourceText":"舊檔",
         "translatedText":"","confidence":1,"style":{},"automaticMaskEnabled":true,
         "ocrTextRefined":false,"maskRefinementApplied":false,
         "maskCoverageComplete":false,"maskStrokes":[]}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let region = try decoder.decode(
            ComicStringTable.self, from: Data(legacy.utf8)
        ).regions[0]
        XCTAssertTrue(region.bubbleMaskPolygons.isEmpty)
        XCTAssertNil(region.bubbleLayoutBounds)
        XCTAssertEqual(region.sourceText, "舊檔")
        XCTAssertTrue(region.ocrResults.isEmpty)
    }

    func testOCRResultsRemainSeparatedByModel() throws {
        let bounds = NormalizedRect(x: 0.2, y: 0.1, width: 0.2, height: 0.6)
        let region = DialogueRegion(
            bounds: bounds,
            sourceText: "VLM 原文",
            ocrResults: [
                "ocr-a": OCRModelResult(
                    modelID: "ocr-a",
                    text: "候選甲",
                    confidence: 0.91,
                    lines: [OCRTextLineResult(
                        text: "候選甲",
                        confidence: 0.91,
                        bounds: bounds
                    )]
                ),
                "ocr-b": OCRModelResult(
                    modelID: "ocr-b",
                    text: "候選乙",
                    confidence: 0.72,
                    lines: [OCRTextLineResult(
                        text: "候選乙",
                        confidence: 0.72,
                        bounds: bounds
                    )]
                )
            ],
            confidence: 1
        )
        let table = ComicStringTable(
            sourceRelativePath: "p.jpg", pixelWidth: 100, pixelHeight: 100,
            targetLanguageCode: "zh-Hant",
            entries: [ComicStringEntry(order: 0, region: region)]
        )
        let encoded = try JSONEncoder().encode(table)
        let restored = try JSONDecoder().decode(ComicStringTable.self, from: encoded).regions[0]

        XCTAssertEqual(restored.sourceText, "VLM 原文")
        XCTAssertEqual(restored.ocrResults["ocr-a"]?.text, "候選甲")
        XCTAssertEqual(restored.ocrResults["ocr-b"]?.text, "候選乙")
        XCTAssertEqual(restored.ocrResults.count, 2)
    }
}
