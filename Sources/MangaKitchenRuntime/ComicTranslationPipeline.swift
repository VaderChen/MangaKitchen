import Foundation
import MangaKitchenCore

public actor ComicTranslationPipeline {
    private let recognizer: any PageTextRecognizing
    private let translator: any RegionTranslating
    private let maskGenerator: any DialogueMaskGenerating
    private let backgroundRestorer: any PageBackgroundRestoring
    private let typesetter: any DialogueTypesetting
    private let outputRoot: URL

    public init(
        recognizer: any PageTextRecognizing,
        translator: any RegionTranslating,
        maskGenerator: any DialogueMaskGenerating,
        backgroundRestorer: any PageBackgroundRestoring,
        typesetter: any DialogueTypesetting,
        outputRoot: URL
    ) {
        self.recognizer = recognizer
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
        progress: @escaping PagePipelineProgress
    ) async throws -> PageProcessingResult {
        try Task.checkCancellation()
        let detection = try await detectMasks(page: page, options: options, progress: progress)
        let regions = try await translate(
            page: page,
            regions: detection.regions,
            options: options,
            glossary: glossary,
            progress: progress
        )
        let composition = try await compose(
            page: page,
            regions: regions,
            options: options,
            outputURL: outputURL,
            progress: progress
        )
        progress(.completed, 1)

        return PageProcessingResult(
            regions: regions,
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
        progress: @escaping PagePipelineProgress
    ) async throws -> PageDetectionResult {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        progress(.detectingText, 0)
        var regions = try await recognizer.recognizeText(
            in: page.sourceURL,
            languageCodes: options.sourceLanguageCodes,
            readingDirection: options.readingDirection
        )
        regions = regions.map { region in
            var value = region
            value.style = options.defaultStyle
            return value
        }
        progress(.detectingText, 0.9)
        try await maskGenerator.generateMask(
            sourceURL: page.sourceURL,
            regions: regions,
            expansion: options.maskExpansion,
            outputURL: urls.mask
        )
        progress(.maskReady, 1)
        return PageDetectionResult(regions: regions, maskURL: urls.mask)
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

    /// 步驟三：只翻譯既有區域，保留 bounds、style 與人工遮罩筆劃。
    public func translate(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        glossary: ProjectGlossary = ProjectGlossary(),
        progress: @escaping PagePipelineProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        progress(.translating, 0)
        let translated = try await translator.translate(
            regions: regions,
            pageURL: page.sourceURL,
            targetLanguageCode: options.targetLanguageCode,
            glossaryTerms: glossary.resolvedTerms(
                for: options.targetLanguageCode,
                sourceTexts: regions.map(\.sourceText)
            )
        ) { value in
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
        progress: @escaping PagePipelineProgress
    ) async throws -> PageCompositionResult {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        let outputURL = requestedOutputURL ?? urls.output
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let renderedRegions = regions.filter {
            !$0.translatedText.isEmpty || !options.preserveUntranslatedRegions
        }
        progress(.composing, 0)
        try await maskGenerator.generateMask(
            sourceURL: page.sourceURL,
            regions: renderedRegions,
            expansion: options.maskExpansion,
            outputURL: urls.mask
        )
        progress(.composing, 0.12)

        let warnings = try await backgroundRestorer.restoreBackground(
            sourceURL: page.sourceURL,
            maskURL: urls.mask,
            regions: renderedRegions,
            outputURL: urls.background,
            preferGenerativeModel: options.useImageToImageRestoration
        ) { value in
            progress(.composing, 0.12 + value * 0.68)
        }

        try await typesetter.typeset(
            backgroundURL: urls.background,
            regions: renderedRegions,
            outputURL: outputURL
        )
        progress(.composing, 1)

        return PageCompositionResult(
            maskURL: urls.mask,
            backgroundURL: urls.background,
            outputURL: outputURL,
            warnings: warnings
        )
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
