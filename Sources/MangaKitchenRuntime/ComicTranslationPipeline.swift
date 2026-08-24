import CoreGraphics
import Foundation
import ImageIO
import MangaKitchenCore

public actor ComicTranslationPipeline {
    private let regionDetector: any SemanticRegionDetecting
    private let textRecognizer: (any RegionTextRecognizing)?
    private let textRecognizers: [TextLocalizationMethod: any RegionTextRecognizing]
    private let maskRefiner: any DialogueMaskRefining
    private let translator: any RegionTranslating
    private let translators: [TranslationModelMethod: any RegionTranslating]
    private let maskGenerator: any DialogueMaskGenerating
    private let backgroundRestorer: any PageBackgroundRestoring
    private let typesetter: any DialogueTypesetting
    private let superResolver: (any ImageSuperResolving)?
    private let colorizer: (any ImageColorizing)?
    private let colorizationMaskGenerator: ColorizationMaskGenerator
    private let outputRoot: URL

    public init(
        regionDetector: any SemanticRegionDetecting,
        textRecognizer: (any RegionTextRecognizing)? = nil,
        textRecognizers: [TextLocalizationMethod: any RegionTextRecognizing] = [:],
        maskRefiner: any DialogueMaskRefining,
        translator: any RegionTranslating,
        translators: [TranslationModelMethod: any RegionTranslating] = [:],
        maskGenerator: any DialogueMaskGenerating,
        backgroundRestorer: any PageBackgroundRestoring,
        typesetter: any DialogueTypesetting,
        outputRoot: URL,
        superResolver: (any ImageSuperResolving)? = nil,
        colorizer: (any ImageColorizing)? = nil,
        colorizationMaskGenerator: ColorizationMaskGenerator = ColorizationMaskGenerator()
    ) {
        self.regionDetector = regionDetector
        self.textRecognizer = textRecognizer
        self.textRecognizers = textRecognizers
        self.maskRefiner = maskRefiner
        self.translator = translator
        self.translators = translators
        self.maskGenerator = maskGenerator
        self.backgroundRestorer = backgroundRestorer
        self.typesetter = typesetter
        self.superResolver = superResolver
        self.colorizer = colorizer
        self.colorizationMaskGenerator = colorizationMaskGenerator
        self.outputRoot = outputRoot
    }

    /// 步驟二：先找對話氣泡，再以原圖像素將氣泡內縮為文字遮罩。
    ///
    /// 這一步不使用專案的 OCR／VLM 文字定位選項。它們屬於後續原文抽取，
    /// 不得改變氣泡區域、像素遮罩或人工筆劃。
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
        // 固定使用氣泡 detector。文字定位模型不能成為步驟二的可變輸入，
        // 否則切換模型就會改變遮罩幾何，破壞流程的單一責任。
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
        fillColorHex: String,
        progress: @escaping InferenceProgress = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let urls = try artifactURLs(for: page)
        _ = try await backgroundRestorer.restoreBackground(
            sourceURL: page.sourceURL,
            maskURL: maskURL,
            regions: regions,
            fillColorHex: fillColorHex,
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
    /// `recognizeText` 為 false 時，沿用目前已確認的 sourceText，只重新翻譯。
    public func translate(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        glossary: ProjectGlossary = ProjectGlossary(),
        recognizeText: Bool = true,
        activity: @escaping PagePipelineActivity = { _ in },
        regionProgress: @escaping PageRegionProgress = { _, _ in },
        progress: @escaping PagePipelineProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            progress(.translationReady, 1)
            return []
        }
        let recognizedRegions = recognizeText
            ? try await recognizeRegions(
                page: page,
                regions: regions,
                options: options,
                force: false,
                activity: activity,
                regionProgress: regionProgress,
                progress: { value in
                    progress(.translating, min(max(value, 0), 1) * 0.4)
                }
            )
            : regions
        let translatableRegions = recognizedRegions.filter {
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !translatableRegions.isEmpty else {
            progress(.translationReady, 1)
            return recognizedRegions
        }
        let targetLanguageCode = options.resolvedTargetLanguageCode
        activity(.applyingGlossary)
        let glossaryTerms = glossary.resolvedTerms(
            for: targetLanguageCode,
            sourceTexts: translatableRegions.map(\.sourceText)
        )
        activity(.preparingTextModel)
        let hasTextRecognizer = textRecognizers[options.textLocalizationMethod] != nil
            || textRecognizer != nil
        progress(.translating, hasTextRecognizer ? 0.4 : 0)
        activity(.translatingRegions)
        let selectedTranslator = translators[options.translationModelMethod]
            ?? translator
        let translatedCandidates = try await selectedTranslator.translate(
            regions: translatableRegions,
            pageURL: page.sourceURL,
            targetLanguageCode: targetLanguageCode,
            glossaryTerms: glossaryTerms,
            readingDirection: options.readingDirection,
            qualityOptions: options.translationQuality,
            activity: activity,
            regionProgress: regionProgress
        ) { value in
            progress(.translating, 0.4 + min(max(value, 0), 1) * 0.6)
        }
        progress(.translationReady, 1)
        let translatedByID = translatedCandidates.reduce(into: [UUID: DialogueRegion]()) { result, region in
            result[region.id] = region
        }
        return recognizedRegions.map { translatedByID[$0.id] ?? $0 }
    }

    /// 在既有區域內重新抽取文字；`force` 會清空辨識器看到的 sourceText，
    /// 因此即使原區域已有原文也會重新送入 VLM／OCR。
    public func recognizeRegions(
        page: ComicPage,
        regions: [DialogueRegion],
        options: ProcessingOptions,
        force: Bool = false,
        activity: @escaping PagePipelineActivity = { _ in },
        regionProgress: @escaping PageRegionProgress = { _, _ in },
        progress: @escaping InferenceProgress = { _ in }
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            progress(1)
            return []
        }
        guard let textRecognizer = textRecognizers[options.textLocalizationMethod]
            ?? textRecognizer else { return regions }
        activity(.preparingTextModel)
        progress(0)
        activity(.detectingRegions)
        let inputRegions: [DialogueRegion]
        if force {
            inputRegions = regions.map { region in
                var value = region
                value.rawSourceText = nil
                value.sourceText = ""
                value.ocrTextRefined = false
                return value
            }
        } else {
            inputRegions = regions
        }
        let recognized = try await textRecognizer.recognizeRegions(
            pageURL: page.sourceURL,
            regions: inputRegions,
            sourceLanguageCodes: options.sourceLanguageCodes,
            regionProgress: regionProgress,
            progress: progress
        )
        // 辨識器只負責回傳文字與 OCR 候選。即使某個 VLM／OCR 實作建立了新的
        // DialogueRegion，也不能把步驟二的座標、氣泡形狀、像素遮罩或人工筆劃
        // 帶回覆蓋掉；步驟三必須是「在既有區域內抽字」。
        return Self.mergeRecognitionResults(
            originals: regions,
            recognized: recognized
        )
    }

    /// 只重新抽取單一既有區域的原文，不翻譯、不重建遮罩，也不改動區域座標。
    /// 先清空傳給辨識器的 sourceText，讓 VLM 重新讀取目前裁切；若辨識失敗，
    /// 回傳原區域，避免一次失敗把既有原文清掉。
    public func recognizeRegion(
        page: ComicPage,
        region: DialogueRegion,
        options: ProcessingOptions,
        regionProgress: @escaping PageRegionProgress = { _, _ in },
        progress: @escaping InferenceProgress = { _ in }
    ) async throws -> DialogueRegion {
        try Task.checkCancellation()
        guard let textRecognizer = textRecognizers[options.textLocalizationMethod]
            ?? textRecognizer else { return region }
        var candidate = region
        candidate.rawSourceText = nil
        candidate.sourceText = ""
        candidate.ocrTextRefined = false
        let recognized = try await textRecognizer.recognizeRegions(
            pageURL: page.sourceURL,
            regions: [candidate],
            sourceLanguageCodes: options.sourceLanguageCodes,
            regionProgress: regionProgress,
            progress: progress
        )
        guard let result = recognized.first(where: { $0.id == region.id }),
              !result.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return region
        }
        return Self.mergeRecognitionResults(
            originals: [region],
            recognized: [result]
        ).first ?? region
    }

    static func mergeRecognitionResults(
        originals: [DialogueRegion],
        recognized: [DialogueRegion]
    ) -> [DialogueRegion] {
        let recognizedByID = Dictionary(uniqueKeysWithValues: recognized.map { ($0.id, $0) })
        return originals.map { original in
            guard let candidate = recognizedByID[original.id] else { return original }
            var merged = original
            merged.ocrResults = original.ocrResults.merging(candidate.ocrResults) {
                _, latest in latest
            }
            guard !candidate.sourceText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                // 空 OCR 仍是該模型的有效診斷結果；保留候選與信心，但不可清掉
                // 已有原文，也不可冒充成功辨識。
                return merged
            }
            merged.rawSourceText = candidate.rawSourceText
            merged.sourceText = candidate.sourceText
            merged.ocrTextRefined = candidate.ocrTextRefined
            merged.detectedWritingDirection = candidate.detectedWritingDirection
            // MCP 抽取結果屬於另一個來源；本機重新抽字不應沿用舊的 MCP 文字。
            merged.mcpExtractedSourceText = candidate.mcpExtractedSourceText
            return merged
        }
    }

    public func rerender(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL,
        renderScale: Double = 1
    ) async throws {
        try await typesetter.typeset(
            backgroundURL: backgroundURL,
            regions: regions,
            outputURL: outputURL,
            renderScale: renderScale
        )
    }

    /// 以目前背景建立（或補建）這一頁的固定翻譯預覽路徑。SR 可以在舊預覽
    /// 不存在時呼叫它，避免只有 SR 背景卻沒有可供輸出階段使用的 translated.png。
    public func renderTranslationPreview(
        page: ComicPage,
        backgroundURL: URL,
        regions: [DialogueRegion]
    ) async throws -> URL {
        let urls = try artifactURLs(for: page)
        let outputURL = urls.output
        let renderScale = Self.renderScale(page: page, imageURL: backgroundURL) ?? 1
        try await typesetter.typeset(
            backgroundURL: backgroundURL,
            regions: regions,
            outputURL: outputURL,
            renderScale: renderScale
        )
        return outputURL
    }

    public func superResolve(
        page: ComicPage,
        inputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws -> URL {
        guard let superResolver else {
            throw ModelRuntimeError.capabilityNotLoaded(.superResolution)
        }
        let urls = try artifactURLs(for: page)
        try await superResolver.superResolve(
            inputURL: inputURL,
            outputURL: urls.superResolvedBackground,
            progress: progress
        )
        if let maskURL = page.maskURL,
           FileManager.default.fileExists(atPath: maskURL.path) {
            try Self.protectCleanedPixels(
                cleanBackgroundURL: inputURL,
                maskURL: maskURL,
                superResolvedURL: urls.superResolvedBackground
            )
        }
        return urls.superResolvedBackground
    }

    public func colorize(
        page: ComicPage,
        inputURL: URL,
        regions: [DialogueRegion],
        strokes: [MaskStroke],
        progress: @escaping InferenceProgress
    ) async throws -> URL {
        guard let colorizer else {
            throw ModelRuntimeError.capabilityNotLoaded(.imageColorization)
        }
        try Task.checkCancellation()
        let maskURL = try prepareColorizationMask(
            page: page,
            sourceURL: inputURL,
            regions: regions,
            strokes: strokes
        )
        let previewURL = try colorizationPreviewURL(for: page)
        progress(0.15)
        try await colorizer.colorize(
            inputURL: inputURL,
            maskURL: maskURL,
            outputURL: previewURL,
            progress: { value in
                progress(0.15 + min(max(value, 0), 1) * 0.85)
            }
        )
        return previewURL
    }

    public func prepareColorizationMask(
        page: ComicPage,
        sourceURL: URL,
        regions: [DialogueRegion],
        strokes: [MaskStroke]
    ) throws -> URL {
        let maskURL = try artifactURLs(for: page).colorizationMask
        try colorizationMaskGenerator.generateMask(
            sourceURL: sourceURL,
            regions: regions,
            strokes: strokes,
            outputURL: maskURL
        )
        return maskURL
    }

    public func colorizationPreviewURL(for page: ComicPage) throws -> URL {
        try artifactURLs(for: page).colorizationPreview
    }

    /// 保護已完成去字的遮罩區，避免 SR 把極淡殘影重新銳化成原文。
    ///
    /// 遮罩外沿用模型輸出；遮罩內使用去字背景的高品質縮放像素。遮罩再向外
    /// 擴一個原圖像素，連同 SR 在筆畫邊緣產生的 halo 一起隔離。
    private static func protectCleanedPixels(
        cleanBackgroundURL: URL,
        maskURL: URL,
        superResolvedURL: URL
    ) throws {
        let cleanBackground = try CGImageIO.load(from: cleanBackgroundURL)
        let mask = try CGImageIO.load(from: maskURL)
        let superResolved = try CGImageIO.load(from: superResolvedURL)
        guard cleanBackground.width == mask.width,
              cleanBackground.height == mask.height,
              superResolved.width > 0,
              superResolved.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        let width = superResolved.width
        let height = superResolved.height
        var protectedPixels = try rgbaPixels(
            from: superResolved,
            width: width,
            height: height,
            interpolationQuality: .none
        )
        let cleanPixels = try rgbaPixels(
            from: cleanBackground,
            width: width,
            height: height,
            interpolationQuality: .high
        )
        let maskPixels = try grayscalePixels(
            from: mask,
            width: width,
            height: height
        )
        let scale = min(
            Double(width) / Double(cleanBackground.width),
            Double(height) / Double(cleanBackground.height)
        )
        let protectedMask = MaskDilation.dilated(
            maskPixels.map { $0 > 127 },
            width: width,
            height: height,
            radius: max(1, Int(ceil(scale)))
        )
        for pixelIndex in protectedMask.indices where protectedMask[pixelIndex] {
            let byteIndex = pixelIndex * 4
            protectedPixels[byteIndex] = cleanPixels[byteIndex]
            protectedPixels[byteIndex + 1] = cleanPixels[byteIndex + 1]
            protectedPixels[byteIndex + 2] = cleanPixels[byteIndex + 2]
            protectedPixels[byteIndex + 3] = cleanPixels[byteIndex + 3]
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(protectedPixels) as CFData),
              let output = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(output, to: superResolvedURL)
    }

    private static func rgbaPixels(
        from image: CGImage,
        width: Int,
        height: Int,
        interpolationQuality: CGInterpolationQuality
    ) throws -> [UInt8] {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = interpolationQuality
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }

    private static func grayscalePixels(
        from image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }

    private func artifactURLs(for page: ComicPage) throws -> (
        mask: URL,
        background: URL,
        superResolvedBackground: URL,
        output: URL,
        colorizationMask: URL,
        colorizationPreview: URL
    ) {
        let pageDirectory = outputRoot.appendingPathComponent(page.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pageDirectory, withIntermediateDirectories: true)
        return (
            pageDirectory.appendingPathComponent("dialogue-mask.png"),
            pageDirectory.appendingPathComponent("background.png"),
            pageDirectory.appendingPathComponent("background-sr.png"),
            pageDirectory.appendingPathComponent("translated.png"),
            pageDirectory.appendingPathComponent("colorization-mask.png"),
            pageDirectory.appendingPathComponent("colorized.png")
        )
    }

    private static func renderScale(page: ComicPage, imageURL: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return max(
            1,
            min(
                Double(width) / Double(max(1, page.pixelWidth)),
                Double(height) / Double(max(1, page.pixelHeight))
            )
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
