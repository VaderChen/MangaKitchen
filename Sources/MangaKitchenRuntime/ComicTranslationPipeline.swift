import Foundation
import MangaKitchenCore

public actor ComicTranslationPipeline {
    private let recognizer: any PageTextRecognizing
    private let regionDetector: any SemanticRegionDetecting
    private let ocrTextRefiner: any OCRTextRefining
    private let maskRefiner: any DialogueMaskRefining
    private let translator: any RegionTranslating
    private let maskGenerator: any DialogueMaskGenerating
    private let backgroundRestorer: any PageBackgroundRestoring
    private let typesetter: any DialogueTypesetting
    private let outputRoot: URL

    public init(
        recognizer: any PageTextRecognizing,
        regionDetector: any SemanticRegionDetecting,
        ocrTextRefiner: any OCRTextRefining,
        maskRefiner: any DialogueMaskRefining,
        translator: any RegionTranslating,
        maskGenerator: any DialogueMaskGenerating,
        backgroundRestorer: any PageBackgroundRestoring,
        typesetter: any DialogueTypesetting,
        outputRoot: URL
    ) {
        self.recognizer = recognizer
        self.regionDetector = regionDetector
        self.ocrTextRefiner = ocrTextRefiner
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
        refineOCRText: Bool = true,
        detectMissingRegions: Bool = true,
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> PageDetectionResult {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        var warnings: [String] = []
        activity(.startingOCR)
        progress(.detectingText, 0)
        var regions = try await recognizer.recognizeText(
            in: page.sourceURL,
            languageCodes: options.sourceLanguageCodes,
            readingDirection: options.readingDirection
        )
        progress(.detectingText, 0.12)

        if detectMissingRegions {
            activity(.preparingTextModel)
            // 語意偵測器會把系統 OCR、VLM 判讀與封閉白框候選合併成完整清單，
            // 補足 Vision 容易漏掉的直排 CJK，並排除擬聲字與頁尾資訊。模型失敗
            // 時必須讓本步驟失敗，不可把局部結果誤標為完整頁面。
            let mergedRegions = try await regionDetector.detectRegions(
                pageURL: page.sourceURL,
                existingRegions: regions,
                sourceLanguageCodes: options.sourceLanguageCodes
            ) { value in
                if value > 0 { activity(.detectingRegions) }
                progress(.detectingText, 0.12 + min(max(value, 0), 1) * 0.08)
            }
            activity(.mergingRegions)
            regions = ReadingOrderResolver.sorted(
                mergedRegions,
                direction: options.readingDirection
            )
        }

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
        progress(.detectingText, 0.3)
        if refineOCRText {
            activity(.preparingTextModel)
            regions = try await ocrTextRefiner.refineOCRText(
                regions: regions,
                pageURL: page.sourceURL,
                sourceLanguageCodes: options.sourceLanguageCodes
            ) { value in
                if value > 0 { activity(.refiningOCR) }
                progress(.detectingText, 0.3 + min(max(value, 0), 1) * 0.58)
            }
        } else {
            progress(.detectingText, 0.88)
        }
        activity(.mergingRegions)
        regions = regions.map { region in
            var value = region
            let detectedDirection = value.style.writingDirection
            value.style = options.defaultStyle
            if value.style.writingDirection == .automatic,
               detectedDirection != .automatic {
                value.style.writingDirection = detectedDirection
            }
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

    /// 重新輸出人工畫筆修改後的遮罩，不重跑 OCR。
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

    /// 將外部 Agent 提供的文字粗框收斂成像素級文字遮罩，不重跑 OCR 或模型偵測。
    /// Agent 直接提供且未標示為自動精修的多邊形會原樣保留；自動精修未通過
    /// 覆蓋檢查時則重新運算，避免沿用不完整遮罩。
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

    /// 只校正既有 OCR 文字，不重跑區域偵測、遮罩精修或人工筆劃。
    public func refineOCRText(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        activity: @escaping PagePipelineActivity = { _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        let pending = regions.contains { !$0.ocrTextRefined }
        guard pending else { return regions }
        activity(.preparingTextModel)
        progress(.detectingText, 0)
        let refined = try await ocrTextRefiner.refineOCRText(
            regions: regions,
            pageURL: page.sourceURL,
            sourceLanguageCodes: options.sourceLanguageCodes
        ) { value in
            if value > 0 { activity(.refiningOCR) }
            progress(.detectingText, min(max(value, 0), 1))
        }
        progress(.maskReady, 1)
        return refined
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
        guard regions.allSatisfy(\.ocrTextRefined) else {
            throw ComicTranslationPipelineError.ocrTextRefinementRequired
        }
        activity(.applyingGlossary)
        let glossaryTerms = glossary.resolvedTerms(
            for: options.targetLanguageCode,
            sourceTexts: regions.map(\.sourceText)
        )
        activity(.preparingTextModel)
        progress(.translating, 0)
        let translated = try await translator.translate(
            regions: regions,
            pageURL: page.sourceURL,
            targetLanguageCode: options.targetLanguageCode,
            glossaryTerms: glossaryTerms
        ) { value in
            if value > 0 { activity(.translatingRegions) }
            progress(.translating, value)
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
        let prepared = try await preparePixelMasksForComposition(
            page: page,
            regions: regions,
            renderedRegionIDs: renderedRegionIDs
        )
        let renderedRegions = prepared.regions.filter { renderedRegionIDs.contains($0.id) }
        activity(.generatingMask)
        progress(.composing, 0)
        try await maskGenerator.generateMask(
            sourceURL: page.sourceURL,
            regions: renderedRegions,
            expansion: options.maskExpansion,
            outputURL: urls.mask
        )
        progress(.composing, 0.12)

        activity(.restoringBackground)
        let restorationWarnings = try await backgroundRestorer.restoreBackground(
            sourceURL: page.sourceURL,
            maskURL: urls.mask,
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
            maskURL: urls.mask,
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
    case ocrTextRefinementRequired

    public var errorDescription: String? {
        switch self {
        case .ocrTextRefinementRequired:
            "翻譯前必須先以圖生文模型、AI Agent 或人工完成所有 OCR 文字校正。"
        }
    }
}
