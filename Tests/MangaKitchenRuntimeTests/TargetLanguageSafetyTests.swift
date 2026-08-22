import XCTest
@testable import MangaKitchenCore
@testable import MangaKitchenRuntime

final class TargetLanguageSafetyTests: XCTestCase {
    private actor StubTranslationModel: ImageToTextGenerating {
        let response: String
        let progressValues: [Double]
        private(set) var prompts: [String] = []

        init(response: String, progressValues: [Double] = [1]) {
            self.response = response
            self.progressValues = progressValues
        }

        func generateText(
            imageURL _: URL,
            prompt: String,
            maximumOutputTokens _: Int?,
            progress: @escaping InferenceProgress
        ) async throws -> String {
            prompts.append(prompt)
            progressValues.forEach(progress)
            return response
        }
    }

    private actor SequencedTranslationModel: ImageToTextGenerating {
        let responses: [String]
        private(set) var callCount = 0

        init(responses: [String]) {
            self.responses = responses
        }

        func generateText(
            imageURL _: URL,
            prompt _: String,
            maximumOutputTokens _: Int?,
            progress: @escaping InferenceProgress
        ) async throws -> String {
            let index = min(callCount, max(0, responses.count - 1))
            callCount += 1
            progress(1)
            return responses[index]
        }
    }

    private final class RegionProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(current: Int, total: Int)] = []

        func record(current: Int, total: Int) {
            lock.lock()
            values.append((current, total))
            lock.unlock()
        }

        func snapshot() -> [(current: Int, total: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class ActivityRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PageProcessingActivity] = []

        func record(_ activity: PageProcessingActivity) {
            lock.lock()
            values.append(activity)
            lock.unlock()
        }

        func snapshot() -> [PageProcessingActivity] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testAutomaticChineseDefaultsToTraditionalUnlessSimplifiedIsExplicit() {
        XCTAssertEqual(
            TargetLanguageResolver.resolve("auto", preferredLanguages: ["zh"]),
            "zh-Hant"
        )
        XCTAssertEqual(
            TargetLanguageResolver.resolve("auto", preferredLanguages: ["zh-TW"]),
            "zh-Hant"
        )
        XCTAssertEqual(
            TargetLanguageResolver.resolve("auto", preferredLanguages: ["zh-Hant-HK"]),
            "zh-Hant"
        )
        XCTAssertEqual(
            TargetLanguageResolver.resolve("auto", preferredLanguages: ["zh-CN"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            TargetLanguageResolver.resolve("auto", preferredLanguages: ["zh-Hans"]),
            "zh-Hans"
        )
    }

    func testChineseTranslationScriptNormalizationIsSymmetric() {
        XCTAssertEqual(
            VLMRegionTranslationService.normalizedTranslation(
                "这把剑比短剑长，转弯不够灵活。",
                targetLanguageCode: "zh-Hant"
            ),
            "這把劍比短劍長，轉彎不夠靈活。"
        )
        XCTAssertEqual(
            VLMRegionTranslationService.normalizedTranslation(
                "這把劍比短劍長，轉彎不夠靈活。",
                targetLanguageCode: "zh-Hans"
            ),
            "这把剑比短剑长，转弯不够灵活。"
        )
    }

    func testTraditionalTargetNormalizesModelResponseBeforeSaving() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"这把剑不够灵活。","displayTranslation":"这把剑不够灵活。","speakerID":"speaker-1","tone":"严肃","confidence":0.9,"qaFlags":[]}]
        """)
        let service = VLMRegionTranslationService(model: model)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "この剣は扱いにくい。",
            confidence: 1
        )
        let translated = try await service.translate(
            regions: [region],
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(translated.first?.translatedText, "這把劍不夠靈活。")
        XCTAssertEqual(translated.first?.literalTranslatedText, "這把劍不夠靈活。")
        XCTAssertEqual(translated.first?.tone, "嚴肅")
        let prompts = await model.prompts
        XCTAssertTrue(prompts.first?.contains("Use Traditional Chinese characters only") == true)
    }

    func testFullPageTranslationReportsGeneratedRegionProgress() async throws {
        let ids = (1...3).map { value in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
        let response = ids.map { id in
            """
            {"id":"\(id.uuidString)","literalTranslation":"譯文","displayTranslation":"譯文","confidence":0.9,"qaFlags":[]}
            """
        }.joined(separator: ",")
        let model = StubTranslationModel(
            response: "[\(response)]",
            progressValues: [0.55, 0.70, 0.85, 0.99, 1]
        )
        let regions = ids.enumerated().map { index, id in
            DialogueRegion(
                id: id,
                bounds: NormalizedRect(
                    x: Double(index) * 0.2,
                    y: 0.1,
                    width: 0.1,
                    height: 0.2
                ),
                sourceText: "原文 \(index + 1)",
                confidence: 1
            )
        }
        let recorder = RegionProgressRecorder()
        let service = VLMRegionTranslationService(model: model)

        _ = try await service.translate(
            regions: regions,
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                usePageContext: true,
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: recorder.record,
            progress: { _ in }
        )

        let reported = recorder.snapshot().filter { $0.total == regions.count }
        XCTAssertEqual(Set(reported.map(\.current)), Set([0, 1, 2, 3]))
        XCTAssertEqual(recorder.snapshot().last?.current, 0)
        XCTAssertEqual(recorder.snapshot().last?.total, 0)
    }

    func testPartialPageResponseUsesOnlyOneBatchRecovery() async throws {
        let ids = (1...3).map { value in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
        let item: (UUID, String) -> String = { id, text in
            """
            {"id":"\(id.uuidString)","displayTranslation":"\(text)","confidence":0.9,"qaFlags":[]}
            """
        }
        let model = SequencedTranslationModel(responses: [
            "[\(item(ids[0], "譯文一"))]",
            "[\(item(ids[1], "譯文二")),\(item(ids[2], "譯文三"))]"
        ])
        let regions = ids.enumerated().map { index, id in
            DialogueRegion(
                id: id,
                bounds: NormalizedRect(x: Double(index) * 0.2, y: 0.1, width: 0.1, height: 0.2),
                sourceText: "原文 \(index + 1)",
                confidence: 1
            )
        }
        let service = VLMRegionTranslationService(model: model)

        let translated = try await service.translate(
            regions: regions,
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                usePageContext: true,
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        let callCount = await model.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(translated.map(\.translatedText), ["譯文一", "譯文二", "譯文三"])
    }

    func testSecondPassReportsReviewActivitySeparatelyFromDraftTranslation() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"譯文","displayTranslation":"譯文","confidence":0.9,"qaFlags":[]}]
        """)
        let recorder = ActivityRecorder()
        let service = VLMRegionTranslationService(model: model)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "原文",
            confidence: 1
        )

        _ = try await service.translate(
            regions: [region],
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                reviewPassEnabled: true,
                qualityCheckEnabled: false
            ),
            activity: recorder.record,
            regionProgress: { _, _ in },
            progress: { _ in }
        )

        XCTAssertEqual(recorder.snapshot(), [.translatingRegions, .reviewingTranslations])
    }
}
