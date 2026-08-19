import Foundation
import MangaKitchenCore

public actor ComicTranslationPipeline {
    private let regionDetector: any SemanticRegionDetecting
    private let textRecognizer: (any RegionTextRecognizing)?
    private let maskRefiner: any DialogueMaskRefining
    private let translator: any RegionTranslating
    private let maskGenerator: any DialogueMaskGenerating
    private let backgroundRestorer: any PageBackgroundRestoring
    private let typesetter: any DialogueTypesetting
    private let outputRoot: URL

    public init(
        regionDetector: any SemanticRegionDetecting,
        textRecognizer: (any RegionTextRecognizing)? = nil,
        maskRefiner: any DialogueMaskRefining,
        translator: any RegionTranslating,
        maskGenerator: any DialogueMaskGenerating,
        backgroundRestorer: any PageBackgroundRestoring,
        typesetter: any DialogueTypesetting,
        outputRoot: URL
    ) {
        self.regionDetector = regionDetector
        self.textRecognizer = textRecognizer
        self.maskRefiner = maskRefiner
        self.translator = translator
        self.maskGenerator = maskGenerator
        self.backgroundRestorer = backgroundRestorer
        self.typesetter = typesetter
        self.outputRoot = outputRoot
    }

    public func process(
        page: ComicPage,
        options: ProcessingOptions,
        glossary: ProjectGlossary = ProjectGlossary(),
        outputURL: URL? = nil,
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> PageProcessingResult {
        try Task.checkCancellation()
        let detection = try await detectMasks(
            page: page,
            options: options,
            activity: activity,
            progress: progress
        )
        let regions = try await translate(
            page: page,
            regions: detection.regions,
            options: options,
            glossary: glossary,
            activity: activity,
            progress: progress
        )
        let composition = try await compose(
            page: page,
            regions: regions,
            options: options,
            outputURL: outputURL,
            activity: activity,
            progress: progress
        )
        progress(.completed, 1)

        return PageProcessingResult(
            regions: composition.regions,
            maskURL: composition.maskURL,
            backgroundURL: composition.backgroundURL,
            outputURL: composition.outputURL,
            warnings: composition.warnings
        )
    }

    /// 步驟二：辨識文字區域並建立可供人工修訂的初始遮罩。
    public func detectMasks(
        page: ComicPage,
        options: ProcessingOptions,
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> PageDetectionResult {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        var warnings: [String] = []
        activity(.detectingEnclosures)
        progress(.detectingText, 0)
        let detectedRegions = try await regionDetector.detectRegions(
            pageURL: page.sourceURL,
            sourceLanguageCodes: options.sourceLanguageCodes,
            fineScanEnabled: options.fineScanEnabled
        ) { value in
            progress(.detectingText, min(max(value, 0), 1) * 0.2)
        }
        activity(.mergingRegions)
        var regions = ReadingOrderResolver.sorted(
            detectedRegions,
            direction: options.readingDirection
        )

        try Task.checkCancellation()
        activity(.refiningPixelMask)
        progress(.detectingText, 0.2)
        regions = try await maskRefiner.refineMasks(
            sourceURL: page.sourceURL,
            regions: regions
        )
        let incompleteMasks = regions.filter { !$0.maskCoverageComplete }
        if !incompleteMasks.isEmpty {
            warnings.append(
                "有 \(incompleteMasks.count) 個文字區域未通過像素遮罩覆蓋檢查；請先補齊粗定位或對話框內緣。"
            )
        }
        progress(.detectingText, 0.88)
        activity(.mergingRegions)
        regions = regions.map { region in
            var value = region
            // 新偵測區域一律採用使用者的預設樣式；預設為 automatic 時交由
            // typesetter 依譯文與框形決定方向，不把 VLM 猜測寫成固定橫／直排。
            value.style = options.defaultStyle
            return value
        }
        progress(.detectingText, 0.92)
        activity(.generatingMask)
        try await maskGenerator.generateMask(
            sourceURL: page.sourceURL,
            regions: regions,
            expansion: options.maskExpansion,
            outputURL: urls.mask
        )
        progress(.maskReady, 1)
        return PageDetectionResult(regions: regions, maskURL: urls.mask, warnings: warnings)
    }

    /// 重新輸出人工畫筆修改後的遮罩，不重跑封閉區域偵測或 VLM。
    @discardableResult
    public func regenerateMask(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions
    ) async throws -> URL {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        try await maskGenerator.generateMask(
            sourceURL: page.sourceURL,
            regions: regions,
            expansion: options.maskExpansion,
            outputURL: urls.mask
        )
        return urls.mask
    }

    /// 產生步驟二的遮罩校對圖。只使用目前 CPU／GPU 傳統合成後端，
    /// 不啟動圖生圖模型，讓使用者能立即確認原文字是否已完整清除。
    public func renderMaskPreview(
        page: ComicPage,
        regions: [DialogueRegion],
        maskURL: URL,
        progress: @escaping InferenceProgress = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        _ = try await backgroundRestorer.restoreBackground(
            sourceURL: page.sourceURL,
            maskURL: maskURL,
            regions: regions,
            outputURL: urls.background,
            preferGenerativeModel: false,
            progress: progress
        )
        return urls.background
    }

    /// 將外部提供的文字粗框收斂成像素級文字遮罩，不重跑模型偵測。
    /// 已完成的系統遮罩會保留；自動精修未通過覆蓋檢查時則重新運算，避免沿用
    /// 不完整遮罩。
    public func refineMasks(
        page: ComicPage,
        regions: [DialogueRegion]
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        let pending = regions.filter {
            $0.maskPolygons.isEmpty || ($0.maskRefinementApplied && !$0.maskCoverageComplete)
        }
        guard !pending.isEmpty else { return regions }
        let refined = try await maskRefiner.refineMasks(
            sourceURL: page.sourceURL,
            regions: pending
        )
        let refinedByID = Dictionary(uniqueKeysWithValues: refined.map { ($0.id, $0) })
        let pendingIDs = Set(pending.map(\.id))
        return regions.map { region in
            guard pendingIDs.contains(region.id) else { return region }
            return refinedByID[region.id] ?? region
        }
    }

    /// 步驟三：只翻譯既有區域，保留 bounds、style 與人工遮罩筆劃。
    public func translate(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        glossary: ProjectGlossary = ProjectGlossary(),
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            progress(.translationReady, 1)
            return []
        }
        let recognizedRegions: [DialogueRegion]
        if let textRecognizer {
            activity(.preparingTextModel)
            progress(.translating, 0)
            recognizedRegions = try await textRecognizer.recognizeRegions(
                pageURL: page.sourceURL,
                regions: regions,
                sourceLanguageCodes: options.sourceLanguageCodes
            ) { value in
                if value > 0 { activity(.detectingRegions) }
                progress(.translating, min(max(value, 0), 1) * 0.4)
            }
        } else {
            recognizedRegions = regions
        }
        guard recognizedRegions.allSatisfy({
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ComicTranslationPipelineError.sourceTextRequired
        }
        let targetLanguageCode = options.resolvedTargetLanguageCode
        activity(.applyingGlossary)
        let glossaryTerms = glossary.resolvedTerms(
            for: targetLanguageCode,
            sourceTexts: recognizedRegions.map(\.sourceText)
        )
        activity(.preparingTextModel)
        progress(.translating, textRecognizer == nil ? 0 : 0.4)
        let translated = try await translator.translate(
            regions: recognizedRegions,
            pageURL: page.sourceURL,
            targetLanguageCode: targetLanguageCode,
            glossaryTerms: glossaryTerms
        ) { value in
            if value > 0 { activity(.translatingRegions) }
            progress(.translating, 0.4 + min(max(value, 0), 1) * 0.6)
        }
        progress(.translationReady, 1)
        return translated
    }

    /// 步驟四：依目前遮罩修補背景、排版並輸出；不重跑辨識或翻譯。
    public func compose(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        outputURL requestedOutputURL: URL? = nil,
        existingMaskURL: URL? = nil,
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> PageCompositionResult {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        let outputURL = requestedOutputURL ?? urls.output
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        activity(.preparingTranslationPreview)
        let renderedRegionIDs = Set(regions.filter {
            !$0.translatedText.isEmpty || !options.preserveUntranslatedRegions
        }.map(\.id))
        let reusableMaskURL = existingMaskURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let prepared: (regions: [DialogueRegion], warnings: [String])
        if reusableMaskURL == nil {
            prepared = try await preparePixelMasksForComposition(
                page: page,
                regions: regions,
                renderedRegionIDs: renderedRegionIDs
            )
        } else {
            prepared = (regions: regions, warnings: [])
        }
        let renderedRegions = prepared.regions.filter { renderedRegionIDs.contains($0.id) }
        activity(.generatingMask)
        progress(.composing, 0)
        let maskURL: URL
        if let reusableMaskURL {
            maskURL = reusableMaskURL
        } else {
            maskURL = urls.mask
            try await maskGenerator.generateMask(
                sourceURL: page.sourceURL,
                regions: renderedRegions,
                expansion: options.maskExpansion,
                outputURL: maskURL
            )
        }
        progress(.composing, 0.12)

        activity(.restoringBackground)
        let restorationWarnings = try await backgroundRestorer.restoreBackground(
            sourceURL: page.sourceURL,
            maskURL: maskURL,
            regions: renderedRegions,
            outputURL: urls.background,
            preferGenerativeModel: options.useImageToImageRestoration
        ) { value in
            progress(.composing, 0.12 + value * 0.68)
        }

        activity(.typesettingTranslation)
        try await typesetter.typeset(
            backgroundURL: urls.background,
            regions: renderedRegions,
            outputURL: outputURL
        )
        progress(.composing, 1)

        return PageCompositionResult(
            regions: prepared.regions,
            maskURL: maskURL,
            backgroundURL: urls.background,
            outputURL: outputURL,
            warnings: prepared.warnings + restorationWarnings
        )
    }

    private func preparePixelMasksForComposition(
        page: ComicPage,
        regions: [DialogueRegion],
        renderedRegionIDs: Set<UUID>
    ) async throws -> (regions: [DialogueRegion], warnings: [String]) {
        let pending = regions.filter { region in
            guard renderedRegionIDs.contains(region.id) else { return false }
            guard !region.maskStrokes.contains(where: { $0.mode == .add }) else { return false }
            return region.maskPolygons.isEmpty
                || (region.maskRefinementApplied && !region.maskCoverageComplete)
        }
        var warnings: [String] = []
        let refined: [DialogueRegion]
        if pending.isEmpty {
            refined = regions
        } else {
            do {
                refined = try await refineMasks(page: page, regions: regions)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                refined = regions
                warnings.append("像素級遮罩精修失敗，已改用目前遮罩繼續合成：\(error.localizedDescription)")
            }
        }

        let unverifiedCount = refined.reduce(into: 0) { count, region in
            guard renderedRegionIDs.contains(region.id) else { return }
            let hasManualAddition = region.maskStrokes.contains { $0.mode == .add }
            if !hasManualAddition && !region.maskCoverageComplete { count += 1 }
        }
        if unverifiedCount > 0 {
            warnings.append("有 \(unverifiedCount) 個文字區域未通過像素遮罩覆蓋檢查，已依目前遮罩繼續合成。")
        }
        return (refined, warnings)
    }

    public func rerender(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL
    ) async throws {
        try await typesetter.typeset(
            backgroundURL: backgroundURL,
            regions: regions,
            outputURL: outputURL
        )
    }

    private func artifactURLs(for page: ComicPage) throws -> (mask: URL, background: URL, output: URL) {
        let pageDirectory = outputRoot.appendingPathComponent(page.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pageDirectory, withIntermediateDirectories: true)
        return (
            pageDirectory.appendingPathComponent("dialogue-mask.png"),
            pageDirectory.appendingPathComponent("background.png"),
            pageDirectory.appendingPathComponent("translated.png")
        )
    }
}

public enum ComicTranslationPipelineError: LocalizedError, Sendable {
    case sourceTextRequired

    public var errorDescription: String? {
        switch self {
        case .sourceTextRequired:
            "翻譯前每個區域都必須有由圖生文模型、AI Agent 或人工提供的來源文字；請執行步驟三或補齊文字。"
        }
    }
}
