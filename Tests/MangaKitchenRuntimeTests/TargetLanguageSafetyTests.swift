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

    func testTranslationPromptDoesNotUseCopyablePlaceholderValues() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"兩位都辛苦了！","displayTranslation":"兩位都辛苦了！","speakerID":"unknown","tone":"neutral","confidence":0.9,"qaFlags":[]}]
        """)
        let service = VLMRegionTranslationService(model: model, usesImageContext: false)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "二人ともお疲れ様です！",
            confidence: 1
        )

        _ = try await service.translate(
            regions: [region],
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                usePageContext: false,
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: { _, _ in },
            draftsReady: { _ in },
            progress: { _ in }
        )

        let prompts = await model.prompts
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("actual zh-Hant text"))
        XCTAssertTrue(prompt.contains("placeholders such as"))
        XCTAssertTrue(prompt.contains("qaFlags must always be a JSON string array"))
        XCTAssertFalse(prompt.contains("\"id\":\"UUID\""))
        XCTAssertFalse(prompt.contains("\"literalTranslation\":\"...\""))
    }

    func testTranslationAcceptsGPTOSSConfidenceAndRepairsLiteralSourceLeak() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000654")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"二人ともお疲れ様です！","displayTranslation":"兩位都辛苦了！","speakerID":null,"tone":"neutral","confidence":"high","qaFlags":[]}]
        """)
        let service = VLMRegionTranslationService(model: model, usesImageContext: false)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "二人ともお疲れ様です！",
            confidence: 1
        )

        let translated = try await service.translate(
            regions: [region],
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                usePageContext: false,
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: { _, _ in },
            draftsReady: { _ in },
            progress: { _ in }
        )

        XCTAssertEqual(translated.first?.translatedText, "兩位都辛苦了！")
        XCTAssertEqual(translated.first?.literalTranslatedText, "兩位都辛苦了！")
        XCTAssertEqual(translated.first?.translationConfidence, 0.9)
        XCTAssertTrue(translated.first?.translationQAFlags.contains(.sourceTextLeak) == true)
    }

    func testTranslationAcceptsNestedArrayAndScalarQAFlagsFromVLM() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000655")!
        let model = StubTranslationModel(response: """
        [[{"id":"\(regionID.uuidString)","literalTranslation":"謝謝！","displayTranslation":"謝謝！","speakerID":"unknown","tone":"neutral","confidence":1.0,"qaFlags":""}]]
        """)
        let service = VLMRegionTranslationService(model: model)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "ありがとう！",
            confidence: 1
        )

        let translated = try await service.translate(
            regions: [region],
            pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
            targetLanguageCode: "zh-Hant",
            glossaryTerms: [],
            readingDirection: .rightToLeft,
            qualityOptions: TranslationQualityOptions(
                usePageContext: false,
                reviewPassEnabled: false,
                qualityCheckEnabled: false
            ),
            regionProgress: { _, _ in },
            draftsReady: { _ in },
            progress: { _ in }
        )

        XCTAssertEqual(translated.first?.translatedText, "謝謝！")
    }

    func testUnchangedSourceTextIsRecognizedAsTranslationLeak() {
        XCTAssertTrue(
            VLMRegionTranslationService.isLikelySourceTextLeak(
                sourceText: "二人とも0お疲れ様です！",
                translatedText: "二人とも0お疲れ様です！",
                targetLanguageCode: "zh-Hant"
            )
        )
        XCTAssertFalse(
            VLMRegionTranslationService.isLikelySourceTextLeak(
                sourceText: "二人とも0お疲れ様です！",
                translatedText: "兩位都辛苦了！",
                targetLanguageCode: "zh-Hant"
            )
        )
    }

    func testTranslationRejectsUnchangedSourceText() async {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000789")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"二人とも0お疲れ様です！","displayTranslation":"二人とも0お疲れ様です！","confidence":0.9,"qaFlags":[]}]
        """)
        let service = VLMRegionTranslationService(model: model)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "二人とも0お疲れ様です！",
            confidence: 1
        )

        do {
            _ = try await service.translate(
                regions: [region],
                pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
                targetLanguageCode: "zh-Hant",
                glossaryTerms: [],
                readingDirection: .rightToLeft,
                qualityOptions: TranslationQualityOptions(
                    usePageContext: false,
                    reviewPassEnabled: false,
                    qualityCheckEnabled: false
                ),
                regionProgress: { _, _ in },
                draftsReady: { _ in },
                progress: { _ in }
            )
            XCTFail("Expected unchanged source text to be rejected")
        } catch let error as TranslationRuntimeError {
            guard case let .missingTranslations(count) = error else {
                XCTFail("Unexpected translation error: \(error)")
                return
            }
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranslationRejectsEditorialAnnotationsButPreservesRealQuotation() async throws {
        let regionID = UUID(uuidString: "00000000-0000-0000-0000-000000000124")!
        let model = StubTranslationModel(response: """
        [{"id":"\(regionID.uuidString)","literalTranslation":"「旁白/內心獨白」這裡是故鄉。","displayTranslation":"「主角驚呼」……唔……好臭！","speakerID":"hero","tone":"驚訝","confidence":0.9,"qaFlags":[]}]
        """)
        let service = VLMRegionTranslationService(model: model)
        let region = DialogueRegion(
            id: regionID,
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            sourceText: "故郷だ。うっ……くさい！",
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
            draftsReady: { _ in },
            progress: { _ in }
        )

        XCTAssertEqual(translated.first?.literalTranslatedText, "這裡是故鄉。")
        XCTAssertEqual(translated.first?.translatedText, "……唔……好臭！")
        XCTAssertEqual(
            VLMRegionTranslationService.removingEditorialAnnotations("「這把劍」真的很重。"),
            "「這把劍」真的很重。"
        )
        XCTAssertEqual(
            VLMRegionTranslationService.removingEditorialAnnotations("旁白：夜幕降臨。"),
            "夜幕降臨。"
        )
        let prompts = await model.prompts
        XCTAssertTrue(prompts.first?.contains("Never prepend or append editorial annotations") == true)
        XCTAssertTrue(prompts.first?.contains("「旁白/內心獨白」") == true)
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
            draftsReady: { _ in },
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
            draftsReady: { _ in },
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
            draftsReady: { _ in },
            progress: { _ in }
        )

        let callCount = await model.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(translated.map(\.translatedText), ["譯文一", "譯文二", "譯文三"])
    }

    func testIndividualTranslationRejectsWhenEveryRegionResponseIsInvalid() async {
        let ids = (1...2).map { value in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
        let model = SequencedTranslationModel(responses: ["模型沒有輸出 JSON"])
        let regions = ids.enumerated().map { index, id in
            DialogueRegion(
                id: id,
                bounds: NormalizedRect(x: Double(index) * 0.2, y: 0.1, width: 0.1, height: 0.2),
                sourceText: "原文 \(index + 1)",
                confidence: 1
            )
        }
        let service = VLMRegionTranslationService(model: model)

        do {
            _ = try await service.translate(
                regions: regions,
                pageURL: URL(fileURLWithPath: "/tmp/unused.png"),
                targetLanguageCode: "zh-Hant",
                glossaryTerms: [],
                readingDirection: .rightToLeft,
                qualityOptions: TranslationQualityOptions(
                    usePageContext: false,
                    reviewPassEnabled: false,
                    qualityCheckEnabled: false
                ),
                regionProgress: { _, _ in },
                draftsReady: { _ in },
                progress: { _ in }
            )
            XCTFail("Expected invalid individual responses to fail the translation")
        } catch let error as TranslationRuntimeError {
            guard case let .missingTranslations(count) = error else {
                XCTFail("Unexpected translation error: \(error)")
                return
            }
            XCTAssertEqual(count, regions.count)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
            draftsReady: { _ in },
            progress: { _ in }
        )

        XCTAssertEqual(recorder.snapshot(), [.translatingRegions, .reviewingTranslations])
    }
}
