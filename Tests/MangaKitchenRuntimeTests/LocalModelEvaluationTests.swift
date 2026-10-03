import Darwin
import Foundation
import MLX
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

/// Opt-in integration evaluation. Runs the same model hub and translation service as the app;
/// ordinary test runs never download weights or start a large model.
final class LocalModelEvaluationTests: XCTestCase {
    private struct EvaluationCase: Codable, Sendable {
        let id: String
        let imagePath: String
        let sourceTexts: [String]
        let prompt: String?
    }

    private struct MemorySample: Codable {
        let activeBytes: Int
        let cacheBytes: Int
        let peakActiveBytes: Int
        let peakRSSBytes: Int

        init() {
            let snapshot = Memory.snapshot()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            activeBytes = snapshot.activeMemory
            cacheBytes = snapshot.cacheMemory
            peakActiveBytes = snapshot.peakMemory
            peakRSSBytes = usage.ru_maxrss
        }
    }

    private struct Response: Codable, Sendable {
        let prompt: String
        let output: String
        let seconds: Double
    }

    private struct CaseResult: Codable {
        let id: String
        let seconds: Double
        let responses: [Response]
        let translations: [DialogueRegion]
        let memory: MemorySample
        let error: String?
    }

    private struct Report: Codable {
        let modelDirectory: String
        var loadSeconds: Double?
        var loadedMemory: MemorySample?
        var cases: [CaseResult] = []
        var cancellationSeconds: Double?
        var cancellationObserved = false
        var unloadSeconds: Double?
        var unloadedMemory: MemorySample?
        var reloadSeconds: Double?
        var reloadOutput: String?
        var finalMemory: MemorySample?
        var fatalError: String?

        func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    private actor RecordingModel: ImageToTextGenerating {
        let hub: ModelRuntimeHub
        let usesImage: Bool
        var responses: [Response] = []

        init(hub: ModelRuntimeHub, usesImage: Bool) {
            self.hub = hub
            self.usesImage = usesImage
        }

        func takeResponses() -> [Response] {
            defer { responses.removeAll() }
            return responses
        }

        func generateText(
            imageURL: URL, prompt: String, maximumOutputTokens: Int?,
            progress: @escaping InferenceProgress
        ) async throws -> String {
            let start = Date()
            let output: String
            if usesImage {
                output = try await hub.generateText(
                    imageURL: imageURL, prompt: prompt,
                    maximumOutputTokens: maximumOutputTokens, progress: progress)
            } else {
                output = try await hub.generateText(
                    prompt: prompt, maximumOutputTokens: maximumOutputTokens, progress: progress)
            }
            responses.append(Response(
                prompt: prompt, output: output, seconds: Date().timeIntervalSince(start)))
            return output
        }
    }

    func testLocalModelEvaluation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MANGAKITCHEN_EVALUATION_MODEL"],
              let corpusPath = environment["MANGAKITCHEN_EVALUATION_CASES"],
              let reportPath = environment["MANGAKITCHEN_EVALUATION_REPORT"] else {
            throw XCTSkip("Set MANGAKITCHEN_EVALUATION_MODEL, _CASES and _REPORT to evaluate local weights.")
        }
        let cases = try JSONDecoder().decode(
            [EvaluationCase].self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let first = try XCTUnwrap(cases.first)
        let reportURL = URL(fileURLWithPath: reportPath)
        let directoryURL = URL(fileURLWithPath: directory)
        var report = Report(modelDirectory: directoryURL.path)
        let hub = ModelRuntimeHub(metal: try MetalContext(), log: { level, category, message in
            print("evaluation=\(level.rawValue) category=\(category) message=\(message)")
        })

        do {
            Memory.peakMemory = 0
            let loadStart = Date()
            let info = try await hub.loadModel(at: directoryURL)
            report.loadSeconds = Date().timeIntervalSince(loadStart)
            report.loadedMemory = MemorySample()
            try report.save(to: reportURL)
            let model = RecordingModel(hub: hub, usesImage: info.capability == .imageToText)
            let translator = VLMRegionTranslationService(
                model: model, usesImageContext: info.capability == .imageToText)

            for item in cases {
                let start = Date()
                var translations: [DialogueRegion] = []
                var failure: String?
                do {
                    let pageURL = URL(fileURLWithPath: item.imagePath)
                    if let prompt = item.prompt {
                        let text = try await model.generateText(
                            imageURL: pageURL, prompt: prompt, maximumOutputTokens: 768,
                            progress: { _ in })
                        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        let regions = item.sourceTexts.enumerated().map { index, source in
                            DialogueRegion(
                                id: UUID(uuidString: String(format:
                                    "00000000-0000-4000-8000-%012d", index + 1))!,
                                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                sourceText: source, confidence: 1)
                        }
                        translations = try await translator.translate(
                            regions: regions, pageURL: pageURL, targetLanguageCode: "zh-Hant",
                            glossaryTerms: [], readingDirection: .rightToLeft,
                            qualityOptions: TranslationQualityOptions(reviewPassEnabled: false),
                            regionProgress: { _, _ in }, draftsReady: { _ in }, progress: { _ in })
                        XCTAssertEqual(translations.map(\.id), regions.map(\.id))
                        XCTAssertEqual(translations.map(\.sourceText), item.sourceTexts)
                        for region in translations {
                            XCTAssertFalse(region.translatedText.isEmpty, item.id)
                            XCTAssertNotEqual(region.translatedText, region.sourceText, item.id)
                        }
                    }
                } catch {
                    failure = String(describing: error)
                    XCTFail("\(item.id): \(error)")
                }
                report.cases.append(CaseResult(
                    id: item.id, seconds: Date().timeIntervalSince(start),
                    responses: await model.takeResponses(), translations: translations,
                    memory: MemorySample(), error: failure))
                try report.save(to: reportURL)
            }

            // Cancel a live request after loading; then reuse the same hub after unloading.
            let job = Task {
                try await model.generateText(
                    imageURL: URL(fileURLWithPath: first.imagePath),
                    prompt: "List 1000 numbered sentences explaining the story in Traditional Chinese.",
                    maximumOutputTokens: 4096, progress: { _ in })
            }
            try await Task.sleep(for: .milliseconds(500))
            let cancelStart = Date()
            job.cancel()
            do {
                _ = try await job.value
                XCTFail("Cancelled inference returned normally.")
            } catch is CancellationError {
                report.cancellationObserved = true
            }
            report.cancellationSeconds = Date().timeIntervalSince(cancelStart)
            let unloadStart = Date()
            await hub.unloadModel(capability: info.capability)
            // The MLX producer ends on its next token; allow bounded time for that
            // task to release the model after the cancelled stream consumer exits.
            for _ in 0..<100 {
                Memory.clearCache()
                if Memory.activeMemory < 32 * 1_024 * 1_024 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            report.unloadSeconds = Date().timeIntervalSince(unloadStart)
            report.unloadedMemory = MemorySample()
            XCTAssertLessThan(Memory.activeMemory, 32 * 1_024 * 1_024)
            try report.save(to: reportURL)

            let reloadStart = Date()
            _ = try await hub.loadModel(at: directoryURL)
            report.reloadSeconds = Date().timeIntervalSince(reloadStart)
            report.reloadOutput = try await model.generateText(
                imageURL: URL(fileURLWithPath: first.imagePath),
                prompt: "Return only this JSON: {\"status\":\"ok\"}",
                maximumOutputTokens: 128, progress: { _ in })
            XCTAssertTrue(report.reloadOutput?.contains("ok") == true)
            await hub.unloadModel(capability: info.capability)
            Memory.clearCache()
            report.finalMemory = MemorySample()
            try report.save(to: reportURL)
        } catch {
            report.fatalError = String(describing: error)
            try report.save(to: reportURL)
            throw error
        }
    }
}
