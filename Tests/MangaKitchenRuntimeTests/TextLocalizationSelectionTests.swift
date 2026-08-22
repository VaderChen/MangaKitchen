import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class TextLocalizationSelectionTests: XCTestCase {
    private actor StubDetector: SemanticRegionDetecting {
        let marker: String

        init(marker: String) {
            self.marker = marker
        }

        func detectRegions(
            pageURL _: URL,
            sourceLanguageCodes _: [String],
            fineScanEnabled _: Bool,
            progress: @escaping InferenceProgress
        ) async throws -> [DialogueRegion] {
            progress(1)
            return [DialogueRegion(
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                sourceText: marker,
                confidence: 1
            )]
        }
    }

    private actor PassthroughRefiner: DialogueMaskRefining {
        func refineMasks(
            sourceURL _: URL,
            regions: [DialogueRegion]
        ) async throws -> [DialogueRegion] {
            regions
        }
    }

    private actor StubRecognizer: RegionTextRecognizing {
        let marker: String

        init(marker: String) {
            self.marker = marker
        }

        func recognizeRegions(
            pageURL _: URL,
            regions: [DialogueRegion],
            sourceLanguageCodes _: [String],
            regionProgress _: @escaping PageRegionProgress,
            progress: @escaping InferenceProgress
        ) async throws -> [DialogueRegion] {
            progress(1)
            return regions.map { region in
                var value = region
                value.rawSourceText = marker
                value.sourceText = marker
                return value
            }
        }
    }

    private actor StubTranslator: RegionTranslating {
        func translate(
            regions: [DialogueRegion],
            pageURL _: URL,
            targetLanguageCode _: String,
            glossaryTerms _: [ResolvedGlossaryTerm],
            readingDirection _: ReadingDirection,
            qualityOptions _: TranslationQualityOptions,
            activity _: @escaping PagePipelineActivity,
            regionProgress _: @escaping PageRegionProgress,
            progress _: @escaping InferenceProgress
        ) async throws -> [DialogueRegion] {
            regions
        }
    }

    private actor StubMaskGenerator: DialogueMaskGenerating {
        func generateMask(
            sourceURL _: URL,
            regions _: [DialogueRegion],
            expansion _: Double,
            outputURL _: URL
        ) async throws {}
    }

    private actor StubRestorer: PageBackgroundRestoring {
        func restoreBackground(
            sourceURL _: URL,
            maskURL _: URL,
            regions _: [DialogueRegion],
            fillColorHex _: String,
            outputURL _: URL,
            preferGenerativeModel _: Bool,
            progress _: @escaping InferenceProgress
        ) async throws -> [String] {
            []
        }
    }

    private actor StubTypesetter: DialogueTypesetting {
        func typeset(
            backgroundURL _: URL,
            regions _: [DialogueRegion],
            outputURL _: URL,
            renderScale _: Double
        ) async throws {}
    }

    func testPPDetectorIsTheDefaultForNewAndLegacyOptions() throws {
        XCTAssertEqual(
            ProcessingOptions().textLocalizationMethod,
            .ppocrv6MediumDet
        )
        let legacy = try JSONDecoder().decode(
            ProcessingOptions.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(legacy.textLocalizationMethod, .ppocrv6MediumDet)
    }

    func testMaskDetectionDoesNotChangeWithTextLocalizationSetting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-LocatorSelection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ComicTranslationPipeline(
            regionDetector: StubDetector(marker: "bubble"),
            maskRefiner: PassthroughRefiner(),
            translator: StubTranslator(),
            maskGenerator: StubMaskGenerator(),
            backgroundRestorer: StubRestorer(),
            typesetter: StubTypesetter(),
            outputRoot: directory
        )
        let page = ComicPage(
            index: 1,
            title: "page",
            sourceURL: directory.appendingPathComponent("source.png"),
            pixelWidth: 100,
            pixelHeight: 100
        )

        let ppocr = try await pipeline.detectMasks(
            page: page,
            options: ProcessingOptions(textLocalizationMethod: .ppocrv6MediumDet),
            progress: { _, _ in }
        )
        let vlm = try await pipeline.detectMasks(
            page: page,
            options: ProcessingOptions(textLocalizationMethod: .vlm),
            progress: { _, _ in }
        )

        XCTAssertEqual(ppocr.regions.map(\.sourceText), ["bubble"])
        XCTAssertEqual(vlm.regions.map(\.sourceText), ["bubble"])
        XCTAssertEqual(ppocr.regions.map(\.bounds), vlm.regions.map(\.bounds))
    }

    func testTextExtractionUsesSelectedRecognizerWithoutChangingMaskGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-RecognizerSelection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ComicTranslationPipeline(
            regionDetector: StubDetector(marker: "bubble"),
            textRecognizer: StubRecognizer(marker: "fallback"),
            textRecognizers: [
                .ppocrv6MediumDet: StubRecognizer(marker: "ppocr"),
                .vlm: StubRecognizer(marker: "vlm")
            ],
            maskRefiner: PassthroughRefiner(),
            translator: StubTranslator(),
            maskGenerator: StubMaskGenerator(),
            backgroundRestorer: StubRestorer(),
            typesetter: StubTypesetter(),
            outputRoot: directory
        )
        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let mask = [[
            NormalizedPoint(x: 0.1, y: 0.1),
            NormalizedPoint(x: 0.3, y: 0.1),
            NormalizedPoint(x: 0.3, y: 0.3)
        ]]
        let region = DialogueRegion(
            bounds: bounds,
            sourceText: "",
            confidence: 1,
            maskPolygons: mask
        )
        let page = ComicPage(
            index: 1,
            title: "page",
            sourceURL: directory.appendingPathComponent("source.png"),
            pixelWidth: 100,
            pixelHeight: 100
        )

        let ppocr = try await pipeline.recognizeRegions(
            page: page,
            regions: [region],
            options: ProcessingOptions(textLocalizationMethod: .ppocrv6MediumDet)
        )
        let vlm = try await pipeline.recognizeRegions(
            page: page,
            regions: [region],
            options: ProcessingOptions(textLocalizationMethod: .vlm)
        )

        XCTAssertEqual(ppocr[0].sourceText, "ppocr")
        XCTAssertEqual(vlm[0].sourceText, "vlm")
        XCTAssertEqual(ppocr[0].bounds, bounds)
        XCTAssertEqual(vlm[0].bounds, bounds)
        XCTAssertEqual(ppocr[0].maskPolygons, mask)
        XCTAssertEqual(vlm[0].maskPolygons, mask)
    }
}
