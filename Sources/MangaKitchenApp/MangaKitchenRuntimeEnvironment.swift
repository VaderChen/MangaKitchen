import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

/// MangaKitchen 單一程序內唯一的推論與影像處理環境。
///
/// GUI 與 MCP 必須共用此物件，才能保證相同 capability 不會建立兩份大型模型，
/// 並讓所有入口使用相同 Metal context、模型資源與 Artifacts Root。
final class MangaKitchenRuntimeEnvironment: @unchecked Sendable {
    let applicationRoot: URL
    let artifactsRoot: URL
    let metal: MetalContext
    let models: ModelRuntimeHub
    let backgroundRestorer: HybridBackgroundRestorer
    let colorizationCompositor: MaskedImageCompositor
    let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?
    let htmlTypesetter: HTMLDialogueTypesetter
    let appPipeline: ComicTranslationPipeline
    let mcpAgentPipeline: ComicTranslationPipeline
    let mcpLocalDetectionPipeline: ComicTranslationPipeline

    init(
        applicationRoot: URL,
        imageCompositingBackend: ImageCompositingBackend,
        modelThinkingEnabled: Bool,
        dflashEnabled: Bool,
        dflashBlockSize: Int,
        log: @escaping RuntimeLogHandler,
        reasoningStream: @escaping RuntimeReasoningStreamHandler
    ) throws {
        self.applicationRoot = applicationRoot
        artifactsRoot = applicationRoot.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactsRoot,
            withIntermediateDirectories: true
        )

        let metal = try MetalContext()
        let models = ModelRuntimeHub(
            metal: metal,
            dflashEnabled: dflashEnabled,
            dflashBlockSize: dflashBlockSize,
            thinkingEnabled: modelThinkingEnabled,
            log: log,
            reasoningStream: reasoningStream
        )
        let backgroundRestorer = try HybridBackgroundRestorer(
            models: models,
            metal: metal,
            compositingBackend: imageCompositingBackend
        )
        let colorizationCompositor = MaskedImageCompositor(metal: metal)
        let bubbleSegmenter = BundledModelFactory.bubbleSegmenter()
        let htmlTypesetter = HTMLDialogueTypesetter()
        let maskGenerator = DialogueMaskGenerator()
        let maskRefiner = MangaTextMaskRefiner()

        let ppocrTextRecognizer: any RegionTextRecognizing
        if let ocrRuntime = BundledModelFactory.ocrRuntime() {
            ppocrTextRecognizer = OCRRegionTextRecognitionService(
                ocr: ocrRuntime,
                locator: BundledModelFactory.textLocalizationRuntime()
            )
        } else {
            ppocrTextRecognizer = UnavailableOCRRegionTextRecognizer()
        }
        let vlmTextRecognizer = VLMRegionTranscriptionService(model: models)
        let imageTranslator = VLMRegionTranslationService(model: models, log: log)
        let textTranslator = VLMRegionTranslationService(
            model: TextOnlyImageToTextAdapter(model: models),
            usesImageContext: false,
            log: log
        )

        self.metal = metal
        self.models = models
        self.backgroundRestorer = backgroundRestorer
        self.colorizationCompositor = colorizationCompositor
        self.bubbleSegmenter = bubbleSegmenter
        self.htmlTypesetter = htmlTypesetter

        appPipeline = ComicTranslationPipeline(
            regionDetector: MangaBubbleMaskRegionDetector(
                bubbleSegmenter: bubbleSegmenter
            ),
            textRecognizer: ppocrTextRecognizer,
            textRecognizers: [
                .ppocrv6MediumDet: ppocrTextRecognizer,
                .vlm: vlmTextRecognizer
            ],
            maskRefiner: maskRefiner,
            translator: imageTranslator,
            translators: [
                .textToText: textTranslator,
                .imageToText: imageTranslator
            ],
            maskGenerator: maskGenerator,
            backgroundRestorer: backgroundRestorer,
            typesetter: htmlTypesetter,
            outputRoot: artifactsRoot,
            superResolver: models,
            colorizer: models
        )

        mcpAgentPipeline = ComicTranslationPipeline(
            regionDetector: AgentDrivenRegionDetector(),
            maskRefiner: maskRefiner,
            translator: AgentDrivenTranslator(),
            maskGenerator: maskGenerator,
            backgroundRestorer: backgroundRestorer,
            typesetter: htmlTypesetter,
            outputRoot: artifactsRoot,
            colorizer: models
        )

        mcpLocalDetectionPipeline = ComicTranslationPipeline(
            regionDetector: MangaBubbleMaskRegionDetector(
                bubbleSegmenter: bubbleSegmenter
            ),
            maskRefiner: maskRefiner,
            translator: AgentDrivenTranslator(),
            maskGenerator: maskGenerator,
            backgroundRestorer: backgroundRestorer,
            typesetter: htmlTypesetter,
            outputRoot: artifactsRoot,
            colorizer: models
        )
    }
}
