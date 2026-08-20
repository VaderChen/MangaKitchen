import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

struct MCPWorkspaceState: Codable, Sendable {
    var workspaceID: UUID?
    var name: String?
    var sourceDirectoryURL: URL?
    var outputDirectoryURL: URL?
    var options: ProcessingOptions
    /// 區域候選來源；遮罩永遠由系統產生，翻譯與排版永遠由 Agent 負責。
    var regionSource: MCPRegionSource
    var glossary: ProjectGlossary
    var pages: [ComicPage]
    var loadedModels: [LoadedModelInfo]
}

private struct MCPWorkspaceContext: Sendable {
    var id: UUID
    var name: String
    var sourceDirectoryURL: URL
    var outputDirectoryURL: URL?
    var options: ProcessingOptions
    var glossary: ProjectGlossary
    var pages: [ComicPage]
    var regionSource: MCPRegionSource
}

/// 頁面狀態摘要；`nextAction` 僅供查詢，不授權 Agent 自行執行。
///
/// 刻意不含 regions：`ComicPage` 內嵌完整 `DialogueRegion`（含數千點的
/// maskPolygons），整個專案列出來會是巨大的 payload。這裡只給「還差什麼」，
/// 需要處理頁面時改由單頁工作包一次提供完整區域資料。
struct MCPPageTask: Codable, Sendable {
    var pageID: UUID
    var index: Int
    var title: String
    var relativeSourcePath: String?
    var stage: PageProcessingStage
    var pixelWidth: Int
    var pixelHeight: Int
    var regionCount: Int
    /// 尚未寫入來源文字的區域數。
    var regionsMissingSourceText: Int
    /// 尚未寫入譯文的區域數。
    var regionsMissingTranslation: Int
    /// 像素遮罩覆蓋檢查未通過的區域數。
    var regionsWithIncompleteMask: Int
    var hasMask: Bool
    var hasBackground: Bool
    var hasTranslationPreview: Bool
    var hasOutput: Bool
    /// 目前缺少的產物類型，並非強制執行命令。
    var nextAction: MCPPageNextAction
    /// 非強制性的狀態提示。
    var nextActionInstruction: String
    var sourceURI: String
    var pageURI: String
    var revision: String
    var errorMessage: String?
}

/// 工作流只有這幾種待辦狀態；Agent 可直接依此分派，不必自行推導。
enum MCPPageNextAction: String, Codable, Sendable {
    /// 預設 App-first 流程尚未建立區域：先執行 page.detect_masks。
    case detectMasks
    /// 明確使用 agent 區域來源且尚無區域：讀原圖後用 page.supplement_regions 提交。
    case submitRegions
    /// 有區域但原文不完整：用 region.update 寫回 source_text。
    case writeSourceText
    /// 原文齊全但缺譯文：用 region.update 寫入 translated_text。
    case writeTranslation
    /// 步驟三預覽齊全但尚未輸出：執行 page.render。
    case compose
    /// 已輸出，無待辦。
    case done
}

struct MCPWorkspacePageList: Codable, Sendable {
    var workspaceID: UUID
    var name: String
    var sourceDirectoryURL: URL
    var outputDirectoryURL: URL?
    var totalPageCount: Int
    var pendingPageCount: Int
    var pages: [MCPPageTask]
}

struct MCPWorkspaceConfiguration: Codable, Sendable {
    var options: ProcessingOptions
    /// 區域候選來源；遮罩永遠由系統產生，翻譯與排版永遠由 Agent 負責。
    var regionSource: MCPRegionSource
}

struct MCPWorkflowResult: Codable, Sendable {
    var workspaceID: UUID
    var operation: String
    var processedPageIDs: [UUID]
    var pages: [ComicPage]
    var revisions: [UUID: String] = [:]
}

struct MCPAgentRegionProposal: Sendable {
    var bounds: NormalizedRect
    var sourceText: String
    var bubbleBounds: NormalizedRect?
    var writingDirection: WritingDirection?
}

struct MCPAgentSupplementResult: Codable, Sendable {
    var page: ComicPage
    var acceptedRegionIDs: [UUID]
    var skippedCount: Int
    var warnings: [String]
}

/// App 交給 Agent 的單頁工作包。遮罩與區域由 App 產生，Agent 只需依這份
/// JSON 逐區讀取原文、翻譯及排版，完成後以一次 submit_agent_result 回寫。
struct MCPAgentPageBundle: Codable, Sendable {
    var workspaceID: UUID
    var pageID: UUID
    var revision: String
    var title: String
    var pixelWidth: Int
    var pixelHeight: Int
    var regionData: ComicStringTable
    var targetLanguageCode: String
    var readingDirection: ReadingDirection
    var defaultWritingDirection: WritingDirection
    var translationQuality: TranslationQualityOptions
    var glossary: ProjectGlossary
    var instruction: String
}

struct MCPAgentTaskPayload: Sendable {
    var bundle: MCPAgentPageBundle
    var sourceImageData: Data
    var sourceImageMIMEType: String
}

struct MCPAgentRegionResult: Sendable {
    var regionID: UUID
    var sourceText: String
    var translatedText: String
    var literalTranslatedText: String?
    var speakerID: String?
    var tone: String?
    var translationConfidence: Double?
    var translationQAFlags: [TranslationQAFlag]?
    var translationAnchor: NormalizedPoint?
    var translationBounds: NormalizedRect?
    var fontName: String?
    var fontSize: Double?
    var fontWeight: DialogueFontWeight?
    var automaticFontSize: Bool?
    var writingDirection: WritingDirection?
    var textAlignment: DialogueTextAlignment?
    var textColorHex: String?
    var strokeColorHex: String?
    var strokeWidth: Double?
    var opacity: Double?
    var rotationDegrees: Double?
    var isVisible: Bool?
}

enum MCPWorkflowStep: String, Sendable {
    case detectMasks
    case translate
    case compose
    case fullPage
}

enum MCPResourcePayload: Sendable {
    case text(String, mimeType: String)
    case binary(Data, mimeType: String)
}

actor MCPWorkflowService {
    typealias Progress = @Sendable (_ completed: Double, _ message: String) -> Void
    typealias StateChangeHandler = @MainActor @Sendable (MCPWorkspaceState) async -> Void
    typealias StateProvider = @MainActor @Sendable (URL) async -> WorkspaceSnapshot?

    private let models: ModelRuntimeHub
    /// 用來產生本機氣泡形狀，或把相容模式的 Agent 粗框對齊到原圖。
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?
    /// 區域編輯的唯一實作，與 App 端共用。
    private var regionEditor: PageRegionEditor {
        PageRegionEditor(pipeline: pipeline, bubbleSegmenter: bubbleSegmenter)
    }
    /// Agent 提供區域粗框與文字；遮罩由系統產生。
    private let agentPipeline: ComicTranslationPipeline
    /// 區域由本機 Core ML BBOX／氣泡形狀定位；文字與排版仍由 Agent 提供。
    private let localDetectionPipeline: ComicTranslationPipeline
    private var pipeline: ComicTranslationPipeline {
        switch regionSource {
        case .agent: agentPipeline
        case .local: localDetectionPipeline
        }
    }
    private let scanner = ComicDirectoryScanner()
    private let stringTables = ComicStringTableRepository()
    private let pathResolver = WorkflowPathResolver()
    private let workspaceRoot: URL

    private var workspaceID: UUID?
    private var sourceDirectoryURL: URL?
    private var outputDirectoryURL: URL?
    private var options = ProcessingOptions()
    /// 預設由 App 先建立區域與遮罩；步驟三固定由 Agent 負責。
    private var regionSource: MCPRegionSource = .local
    private var glossary = ProjectGlossary()
    private var pages: [ComicPage] = []
    private var workspaces: [UUID: MCPWorkspaceContext] = [:]
    private let stateChangeHandler: StateChangeHandler?
    private let stateProvider: StateProvider?

    init(
        dataDirectoryPath: String?,
        imageCompositingBackend: ImageCompositingBackend = .cpu,
        stateChangeHandler: StateChangeHandler? = nil,
        stateProvider: StateProvider? = nil
    ) throws {
        let metal = try MetalContext()
        let models = ModelRuntimeHub(metal: metal)
        let root = try Self.makeWorkspaceRoot(dataDirectoryPath: dataDirectoryPath)
        self.models = models
        self.workspaceRoot = root
        self.stateChangeHandler = stateChangeHandler
        self.stateProvider = stateProvider
        let maskGenerator = DialogueMaskGenerator()
        let typesetter = HTMLDialogueTypesetter()
        let backgroundRestorer = try HybridBackgroundRestorer(
            models: models,
            metal: metal,
            compositingBackend: imageCompositingBackend
        )
        let artifactsRoot = root.appendingPathComponent("Artifacts", isDirectory: true)
        // 翻譯位置在兩條管線都是 AgentDrivenTranslator：MCP 永遠不會用
        // 內建圖生文模型翻譯，這一點不隨模式改變。
        self.bubbleSegmenter = Self.bundledBubbleSegmenter()
        self.agentPipeline = ComicTranslationPipeline(
            regionDetector: AgentDrivenRegionDetector(),
            maskRefiner: MangaTextMaskRefiner(),
            translator: AgentDrivenTranslator(),
            maskGenerator: maskGenerator,
            backgroundRestorer: backgroundRestorer,
            typesetter: typesetter,
            outputRoot: artifactsRoot
        )
        self.localDetectionPipeline = ComicTranslationPipeline(
            regionDetector: MangaBubbleMaskRegionDetector(
                bubbleSegmenter: Self.bundledBubbleSegmenter()
            ),
            maskRefiner: MangaTextMaskRefiner(),
            translator: AgentDrivenTranslator(),
            maskGenerator: DialogueMaskGenerator(),
            backgroundRestorer: try HybridBackgroundRestorer(
                models: models,
                metal: metal,
                compositingBackend: imageCompositingBackend
            ),
            typesetter: HTMLDialogueTypesetter(),
            outputRoot: root.appendingPathComponent("Artifacts", isDirectory: true)
        )
    }

    private static func bundledBubbleSegmenter() -> MangaBubbleSegmentationCoreMLRuntime? {
        guard let modelURL = Bundle.module.url(
            forResource: "MangaBubbleSegmentation",
            withExtension: "mlpackage",
            subdirectory: "Models"
        ) else {
            return nil
        }
        return try? MangaBubbleSegmentationCoreMLRuntime(modelURL: modelURL)
    }

    func openWorkspace(
        sourceDirectoryURL: URL,
        outputDirectoryURL: URL?,
        targetLanguageCode: String?
    ) async throws -> MCPWorkspaceState {
        if let outputDirectoryURL {
            try validateOutputDirectory(outputDirectoryURL, sourceDirectoryURL: sourceDirectoryURL)
            try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        }

        if let existing = workspaces.values.first(where: {
            $0.sourceDirectoryURL.standardizedFileURL == sourceDirectoryURL.standardizedFileURL
        }) {
            try await requireWorkspace(existing.id)
        } else if let snapshot = await stateProvider?(sourceDirectoryURL.standardizedFileURL) {
            saveActiveWorkspace()
            workspaceID = snapshot.projectID
            self.sourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
            self.outputDirectoryURL = snapshot.outputDirectoryURL?.standardizedFileURL
            options = snapshot.options
            options.useImageToImageRestoration = false
            regionSource = .local
            glossary = snapshot.glossary
            pages = snapshot.pages
        } else {
            saveActiveWorkspace()
            let newWorkspaceID = UUID()
            workspaceID = newWorkspaceID
            self.sourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
            self.outputDirectoryURL = outputDirectoryURL?.standardizedFileURL
            options = ProcessingOptions()
            regionSource = .local
            glossary = ProjectGlossary()
            pages = []
        }
        if let outputDirectoryURL {
            self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        }
        if let targetLanguageCode {
            let trimmed = targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { options.targetLanguageCode = trimmed }
        }

        let scanner = self.scanner
        let scanned = try await Task.detached {
            try scanner.scan(sourceDirectoryURL)
        }.value
        try Task.checkCancellation()

        let knownPages = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.sourceURL.standardizedFileURL.path, $0) }
        )
        pages = scanned.enumerated().map { offset, item in
            var page = knownPages[item.sourceURL.path] ?? ComicPage(
                index: offset + 1,
                title: item.sourceURL.deletingPathExtension().lastPathComponent,
                sourceURL: item.sourceURL,
                relativeSourcePath: item.relativePath,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                stage: .scanned
            )
            page.index = offset + 1
            page.relativeSourcePath = item.relativePath
            page.pixelWidth = item.pixelWidth
            page.pixelHeight = item.pixelHeight
            return page
        }
        for index in pages.indices where knownPages[pages[index].sourceURL.path] == nil {
            let tableURL = try stringTableURL(for: pages[index])
            if let table = try await stringTables.load(from: tableURL) {
                pages[index].regions = table.regions
                pages[index].stringTableURL = tableURL
                pages[index].stage = Self.completedArtifactStage(for: pages[index])
            }
        }
        await publishStateChange()
        return await currentState()
    }

    func listWorkspaces() async -> [MCPWorkspaceState] {
        if let workspaceID {
            try? await requireWorkspace(workspaceID)
        }
        saveActiveWorkspace()
        let loadedModels = await models.loadedModels()
        return workspaces.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { context in
                MCPWorkspaceState(
                    workspaceID: context.id,
                    name: context.name,
                    sourceDirectoryURL: context.sourceDirectoryURL,
                    outputDirectoryURL: context.outputDirectoryURL,
                    options: context.options,
                    regionSource: context.regionSource,
                    glossary: context.glossary,
                    pages: context.pages,
                    loadedModels: loadedModels
                )
            }
    }

    func activateWorkspace(workspaceID: UUID) async throws -> MCPWorkspaceState {
        try await requireWorkspace(workspaceID)
        await publishStateChange()
        return await currentState()
    }

    func rescanWorkspace(workspaceID: UUID) async throws -> MCPWorkspaceState {
        try await requireWorkspace(workspaceID)
        guard let sourceDirectoryURL else { throw MCPServiceError.workspaceNotOpen }
        let previousPages = pages
        let oldPages = Dictionary(
            uniqueKeysWithValues: previousPages.map { ($0.sourceURL.standardizedFileURL.path, $0) }
        )
        let fingerprint: (String, Int, Int) -> String = { title, width, height in
            "\(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\(width)x\(height)"
        }
        let relocationGroups = Dictionary(grouping: previousPages) {
            fingerprint($0.title, $0.pixelWidth, $0.pixelHeight)
        }
        let relocated = relocationGroups.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var reusedPageIDs: Set<UUID> = []
        let scanner = self.scanner
        let scanned = try await Task.detached {
            try scanner.scan(sourceDirectoryURL)
        }.value
        var rescanned: [ComicPage] = []
        for (offset, item) in scanned.enumerated() {
            let title = item.sourceURL.deletingPathExtension().lastPathComponent
            let movedPage = relocated[fingerprint(title, item.pixelWidth, item.pixelHeight)].flatMap {
                reusedPageIDs.contains($0.id) ? nil : $0
            }
            var page = oldPages[item.sourceURL.path] ?? movedPage ?? ComicPage(
                index: offset + 1,
                title: title,
                sourceURL: item.sourceURL,
                relativeSourcePath: item.relativePath,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                stage: .scanned
            )
            reusedPageIDs.insert(page.id)
            page.index = offset + 1
            page.sourceURL = item.sourceURL
            page.relativeSourcePath = item.relativePath
            page.pixelWidth = item.pixelWidth
            page.pixelHeight = item.pixelHeight
            let tableURL = pathResolver.stringTableURL(for: item.sourceURL)
            if let table = try await stringTables.load(from: tableURL) {
                page.regions = table.regions
                page.stringTableURL = tableURL
                page.stage = Self.completedArtifactStage(for: page)
            }
            rescanned.append(page)
        }
        pages = rescanned
        await publishStateChange()
        return await currentState()
    }

    func setOutputDirectory(workspaceID: UUID, directoryURL: URL) async throws -> MCPWorkspaceState {
        try await requireWorkspace(workspaceID)
        guard let sourceDirectoryURL else { throw MCPServiceError.workspaceNotOpen }
        try validateOutputDirectory(directoryURL, sourceDirectoryURL: sourceDirectoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        outputDirectoryURL = directoryURL.standardizedFileURL
        await publishStateChange()
        return await currentState()
    }

    func configure(
        workspaceID: UUID,
        targetLanguageCode: String?,
        readingDirection: ReadingDirection?,
        writingDirection: WritingDirection?,
        fontName: String?,
        maskExpansion: Double?,
        useImageToImageRestoration: Bool?,
        regionSource: MCPRegionSource?
    ) async throws -> MCPWorkspaceConfiguration {
        try await requireWorkspace(workspaceID)
        if let targetLanguageCode {
            let trimmed = targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MCPServiceError.invalidArguments("target_language_code 不可為空。") }
            options.targetLanguageCode = trimmed
        }
        if let readingDirection { options.readingDirection = readingDirection }
        if let writingDirection { options.defaultStyle.writingDirection = writingDirection }
        if let fontName, !fontName.isEmpty { options.defaultStyle.fontName = fontName }
        if let maskExpansion, maskExpansion.isFinite {
            options.maskExpansion = min(max(maskExpansion, 0), 0.75)
        }
        options.useImageToImageRestoration = false
        if let regionSource { self.regionSource = regionSource }
        await publishStateChange()
        return MCPWorkspaceConfiguration(options: options, regionSource: self.regionSource)
    }

    func loadModel(directoryURL: URL) async throws -> LoadedModelInfo {
        return try await models.loadModel(at: directoryURL)
    }

    func glossaryEntries(workspaceID: UUID) async throws -> [GlossaryEntry] {
        try await requireWorkspace(workspaceID)
        return glossary.entries
    }

    func upsertGlossaryEntry(
        workspaceID: UUID,
        entryID: UUID?,
        sourceTerm: String,
        translations: [String: String],
        note: String?
    ) async throws -> GlossaryEntry {
        try await requireWorkspace(workspaceID)
        let source = sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw MCPServiceError.invalidArguments("source_term 不可為空。")
        }
        if let entryID, !glossary.entries.contains(where: { $0.id == entryID }) {
            throw MCPServiceError.glossaryEntryNotFound
        }
        let requested = GlossaryEntry(
            id: entryID ?? UUID(),
            sourceTerm: source,
            translations: translations,
            note: note
        )
        let savedID = glossary.upsert(requested)
        guard let saved = glossary.entries.first(where: { $0.id == savedID }) else {
            throw MCPServiceError.glossaryEntryNotFound
        }
        await publishStateChange()
        return saved
    }

    func removeGlossaryEntry(workspaceID: UUID, entryID: UUID) async throws -> [GlossaryEntry] {
        try await requireWorkspace(workspaceID)
        guard glossary.entries.contains(where: { $0.id == entryID }) else {
            throw MCPServiceError.glossaryEntryNotFound
        }
        glossary.remove(entryID: entryID)
        await publishStateChange()
        return glossary.entries
    }

    func run(
        workspaceID: UUID,
        step: MCPWorkflowStep,
        pageIDs requestedPageIDs: [UUID]?,
        progress: @escaping Progress
    ) async throws -> MCPWorkflowResult {
        try await requireWorkspace(workspaceID)
        if step == .translate {
            throw MCPServiceError.agentTranslationRequired
        }
        let targetIDs = try resolvePageIDs(requestedPageIDs)
        // MCP 步驟三固定由外部 Agent 提供原文、翻譯與排版，因此不檢查
        // App 內建 imageToText 模型；需要譯文時由 AgentDrivenTranslator
        // 拋出可操作的錯誤說明。
        if step == .compose || step == .fullPage {
            guard outputDirectoryURL != nil else { throw MCPServiceError.outputDirectoryRequired }
        }

        for (offset, pageID) in targetIDs.enumerated() {
            try Task.checkCancellation()
            let base = Double(offset) / Double(max(targetIDs.count, 1))
            let scale = 1 / Double(max(targetIDs.count, 1))
            let pageProgress: PagePipelineProgress = { stage, fraction in
                let local = Self.stageFraction(stage: stage, fraction: fraction)
                progress(base + local * scale, "\(stage.rawValue)：\(pageID.uuidString)")
            }
            switch step {
            case .detectMasks:
                try await detect(pageID: pageID, progress: pageProgress)
            case .translate:
                throw MCPServiceError.agentTranslationRequired
            case .compose:
                guard hasMaskData(pageID: pageID) else {
                    throw MCPServiceError.maskDataRequired
                }
                guard hasTranslationData(pageID: pageID) else {
                    throw MCPServiceError.translationPreviewRequired
                }
                try await compose(pageID: pageID, progress: pageProgress)
            case .fullPage:
                guard hasMaskData(pageID: pageID) else {
                    throw MCPServiceError.maskDataRequired
                }
                guard hasTranslationData(pageID: pageID) else {
                    throw MCPServiceError.translationPreviewRequired
                }
                if !hasCompletedOutput(pageID: pageID) {
                    try await compose(pageID: pageID, progress: pageProgress)
                }
            }
            progress(Double(offset + 1) / Double(targetIDs.count), "完成頁面：\(pageID.uuidString)")
            await publishStateChange()
        }
        return MCPWorkflowResult(
            workspaceID: workspaceID,
            operation: step.rawValue,
            processedPageIDs: targetIDs,
            pages: pages.filter { targetIDs.contains($0.id) }
        )
    }

    private func hasMaskData(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              let maskURL = page.maskURL,
              FileManager.default.fileExists(atPath: maskURL.path),
              let backgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: backgroundURL.path) else { return false }
        return true
    }

    private func hasAgentTaskData(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              !page.regions.isEmpty else { return false }
        return hasMaskData(pageID: pageID)
    }

    private func hasTranslationData(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              !page.regions.isEmpty,
              page.regions.allSatisfy({
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              let previewURL = page.translationPreviewURL else { return false }
        return FileManager.default.fileExists(atPath: previewURL.path)
    }

    private func hasCompletedOutput(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              page.stage == .completed,
              let outputURL = page.outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    private static func completedArtifactStage(for page: ComicPage) -> PageProcessingStage {
        let fileManager = FileManager.default
        if let outputURL = page.outputURL,
           fileManager.fileExists(atPath: outputURL.path) {
            return .completed
        }
        if let previewURL = page.translationPreviewURL,
           fileManager.fileExists(atPath: previewURL.path) {
            return .translationReady
        }
        if let maskURL = page.maskURL,
           let backgroundURL = page.backgroundURL,
           fileManager.fileExists(atPath: maskURL.path),
           fileManager.fileExists(atPath: backgroundURL.path) {
            return .maskReady
        }
        return .scanned
    }

    /// 專案的頁面狀態摘要，不會觸發或授權 Agent 自行處理。
    /// `pendingOnly` 預設為 true，只回傳還有待辦的頁面。
    func pageTasks(
        workspaceID: UUID,
        pendingOnly: Bool
    ) async throws -> MCPWorkspacePageList {
        try await requireWorkspace(workspaceID)
        guard let context = workspaces[workspaceID] else {
            throw MCPServiceError.workspaceNotFound
        }
        let allTasks = context.pages.map {
            Self.makePageTask($0, regionSource: context.regionSource)
        }
        let pending = allTasks.filter { $0.nextAction != .done }
        return MCPWorkspacePageList(
            workspaceID: workspaceID,
            name: context.name,
            sourceDirectoryURL: context.sourceDirectoryURL,
            outputDirectoryURL: context.outputDirectoryURL,
            totalPageCount: allTasks.count,
            pendingPageCount: pending.count,
            pages: pendingOnly ? pending : allTasks
        )
    }

    func contractDescription() -> MCPContractDescription {
        .current
    }

    func workspaceCapabilities(workspaceID: UUID) async throws -> MCPWorkspaceCapabilities {
        try await requireWorkspace(workspaceID)
        return MCPWorkspaceCapabilities(
            workspaceID: workspaceID,
            contractVersion: MCPContractDescription.current.contractVersion,
            regionSource: regionSource,
            providerPolicy: "provider-agnostic-agent",
            tools: MCPContractDescription.current.publicTools,
            styleFields: MCPContractDescription.current.styleFields,
            supportsOptimisticConcurrency: true,
            supportsAtomicRegionBatchUpdate: true,
            supportsHTMLBasedPSD: true
        )
    }

    func inspectPage(workspaceID: UUID, pageID: UUID) async throws -> MCPPageInspection {
        try await requireWorkspace(workspaceID)
        guard let page = pages.first(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        return try Self.makeInspection(workspaceID: workspaceID, page: page)
    }

    func updatePage(
        workspaceID: UUID,
        pageID: UUID,
        expectedRevision: String,
        title: String?,
        position: Int?
    ) async throws -> MCPPageMutationResult {
        try await requireWorkspace(workspaceID)
        guard let originalIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        try Self.requireRevision(expectedRevision, for: pages[originalIndex])

        if let title {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.count <= 200 else {
                throw MCPServiceError.invalidArguments("title 不可為空白且最多 200 字元。")
            }
            pages[originalIndex].title = normalized
        }

        if let position {
            guard (1...pages.count).contains(position) else {
                throw MCPServiceError.invalidArguments("position 必須介於 1 與目前頁數之間。")
            }
            guard let currentIndex = pages.firstIndex(where: { $0.id == pageID }) else {
                throw MCPServiceError.pageNotFound
            }
            let page = pages.remove(at: currentIndex)
            pages.insert(page, at: position - 1)
            for index in pages.indices {
                pages[index].index = index + 1
            }
        }

        await publishStateChange()
        guard let page = pages.first(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        return try Self.makeMutationResult(workspaceID: workspaceID, page: page)
    }

    /// 步驟三入口：只封裝已完成的步驟二資料，不代跑區域偵測、遮罩或去字背景。
    func prepareAgentTask(
        workspaceID: UUID,
        pageID: UUID,
        progress: @escaping Progress
    ) async throws -> MCPAgentTaskPayload {
        try await requireWorkspace(workspaceID)
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        guard hasAgentTaskData(pageID: pageID) else {
            throw MCPServiceError.maskDataRequired
        }
        progress(0.1, "封裝 App 已完成的步驟二資料：\(pages[index].title)")
        let page = pages[index]
        let targetLanguageCode = options.resolvedTargetLanguageCode
        let bundle = MCPAgentPageBundle(
            workspaceID: workspaceID,
            pageID: page.id,
            revision: try Self.revision(for: page),
            title: page.title,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            regionData: ComicStringTable(page: page, targetLanguageCode: targetLanguageCode),
            targetLanguageCode: targetLanguageCode,
            readingDirection: options.readingDirection,
            defaultWritingDirection: options.defaultStyle.writingDirection,
            translationQuality: options.translationQuality,
            glossary: glossary,
            instruction: "原圖已附在本次 tool result 的 image content，全部區域與遮罩資料已內嵌於 regionData.entries。請依 readingDirection 以整頁語境處理，先建立忠實直譯稿，再依 translationQuality 的長度策略與 styleGuide 完成自然譯文；reviewPassEnabled 時需執行整頁二次校稿，qualityCheckEnabled 時回傳信心與 QA flags。entries 中既有的 sourceText 與 translatedText 都是待校稿草稿，正確時保留，不正確或空白時修正。請同時檢查排版欄位，必要時調整以符合氣泡內的 HTML 排版。不要搜尋、讀取或建立 .str 檔案，也不要額外讀取 page resource。請依既有 region id 逐區處理，不要刪除、合併或重建區域與遮罩。完成全部區域後，以 submit_agent_result 一次回寫並完成步驟三翻譯排字預覽；只有使用者要求輸出時才另外呼叫 page.render 執行步驟四。"
        )
        progress(1, "單頁 Agent 工作包已準備完成：\(page.title)")
        return MCPAgentTaskPayload(
            bundle: bundle,
            sourceImageData: try Data(contentsOf: page.sourceURL),
            sourceImageMIMEType: Self.imageMIMEType(for: page.sourceURL)
        )
    }

    /// 步驟三：一次套用 Agent 對本頁所有區域的文字與排版，並建立翻譯預覽。
    /// 區域 ID 集合必須完全相同，避免 Agent 意外刪除或新增 App 產生的區域。
    func submitAgentResult(
        workspaceID: UUID,
        pageID: UUID,
        expectedRevision: String,
        results: [MCPAgentRegionResult],
        progress: @escaping Progress
    ) async throws -> MCPWorkflowResult {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        try Self.requireRevision(expectedRevision, for: pages[pageIndex])
        guard hasAgentTaskData(pageID: pageID) else {
            throw MCPServiceError.maskDataRequired
        }
        let expectedIDs = Set(pages[pageIndex].regions.map(\.id))
        let receivedIDs = results.map(\.regionID)
        guard Set(receivedIDs).count == receivedIDs.count,
              Set(receivedIDs) == expectedIDs else {
            throw MCPServiceError.invalidArguments(
                "submit_agent_result 必須一次包含本頁全部 region_id，且不可新增、刪除或重複區域。"
            )
        }
        var updatedRegions = pages[pageIndex].regions
        let resultByID = Dictionary(uniqueKeysWithValues: results.map { ($0.regionID, $0) })
        for regionIndex in updatedRegions.indices {
            let regionID = updatedRegions[regionIndex].id
            guard let result = resultByID[regionID] else { continue }
            var edit = RegionEdit()
            edit.sourceText = result.sourceText
            edit.translatedText = result.translatedText
            if let anchor = result.translationAnchor {
                edit.translationAnchor = .set(anchor)
            }
            if let bounds = result.translationBounds {
                edit.translationBounds = .set(bounds)
            }
            edit.fontName = result.fontName
            if let fontSize = result.fontSize {
                edit.fontSize = .set(fontSize)
            }
            edit.useAutomaticFontSize = result.automaticFontSize
            edit.fontWeight = result.fontWeight
            edit.writingDirection = result.writingDirection
            edit.textAlignment = result.textAlignment
            edit.textColorHex = result.textColorHex
            edit.strokeColorHex = result.strokeColorHex
            edit.strokeWidth = result.strokeWidth
            edit.opacity = result.opacity
            edit.rotationDegrees = result.rotationDegrees
            edit.isVisible = result.isVisible
            edit.sourceTextChangesMaskGeometry = false
            _ = PageRegionEditor.apply(edit, to: &updatedRegions[regionIndex])
            updatedRegions[regionIndex].literalTranslatedText = result.literalTranslatedText
            updatedRegions[regionIndex].speakerID = result.speakerID
            updatedRegions[regionIndex].tone = result.tone
            updatedRegions[regionIndex].translationConfidence = result.translationConfidence.map {
                min(max($0, 0), 1)
            }
            updatedRegions[regionIndex].translationQAFlags = result.translationQAFlags ?? []
        }
        guard updatedRegions.allSatisfy({
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MCPServiceError.agentTranslationRequired
        }
        guard let cleanBackgroundURL = pages[pageIndex].backgroundURL,
              FileManager.default.fileExists(atPath: cleanBackgroundURL.path) else {
            throw MCPServiceError.maskDataRequired
        }
        progress(0.65, "已驗證全部區域文字與排版：\(pages[pageIndex].title)")
        let previewURL = try await pipeline.renderTranslationPreview(
            page: pages[pageIndex],
            backgroundURL: pages[pageIndex].superResolvedBackgroundURL ?? cleanBackgroundURL,
            regions: updatedRegions
        )
        pages[pageIndex].regions = updatedRegions
        pages[pageIndex].translationPreviewURL = previewURL
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .translationReady
        pages[pageIndex].progress = 0.65
        pages[pageIndex].errorMessage = nil
        try await persistStringTable(pageID: pageID)
        await publishStateChange()
        progress(1, "步驟三翻譯與排字預覽已完成：\(pages[pageIndex].title)")
        return MCPWorkflowResult(
            workspaceID: workspaceID,
            operation: "agent_submit",
            processedPageIDs: [pageID],
            pages: [pages[pageIndex]],
            revisions: [pageID: try Self.revision(for: pages[pageIndex])]
        )
    }

    private static func makePageTask(
        _ page: ComicPage,
        regionSource: MCPRegionSource
    ) -> MCPPageTask {
        let missingSourceText = page.regions.reduce(into: 0) { count, region in
            let text = region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { count += 1 }
        }
        let missingTranslation = page.regions.reduce(into: 0) { count, region in
            if region.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        let incompleteMask = page.regions.reduce(into: 0) { count, region in
            if !region.maskCoverageComplete { count += 1 }
        }
        let hasMask = page.maskURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let hasBackground = page.backgroundURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let hasTranslationPreview = page.translationPreviewURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let hasOutput = page.outputURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let identifier = page.id.uuidString.lowercased()
        let hasCompleteMaskData = hasMask && hasBackground

        let nextAction: MCPPageNextAction
        if page.regions.isEmpty {
            nextAction = regionSource == .local ? .detectMasks : .submitRegions
        } else if !hasCompleteMaskData {
            nextAction = .detectMasks
        } else if missingSourceText > 0 {
            nextAction = .writeSourceText
        } else if missingTranslation > 0 || !hasTranslationPreview {
            nextAction = .writeTranslation
        } else if !hasOutput {
            nextAction = .compose
        } else {
            nextAction = .done
        }

        return MCPPageTask(
            pageID: page.id,
            index: page.index,
            title: page.title,
            relativeSourcePath: page.relativeSourcePath,
            stage: page.stage,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            regionCount: page.regions.count,
            regionsMissingSourceText: missingSourceText,
            regionsMissingTranslation: missingTranslation,
            regionsWithIncompleteMask: incompleteMask,
            hasMask: hasMask,
            hasBackground: hasBackground,
            hasTranslationPreview: hasTranslationPreview,
            hasOutput: hasOutput,
            nextAction: nextAction,
            nextActionInstruction: Self.nextActionInstruction(for: nextAction),
            sourceURI: "mangakitchen://page/\(identifier)/source",
            pageURI: "mangakitchen://page/\(identifier)",
            revision: (try? Self.revision(for: page)) ?? "unavailable",
            errorMessage: page.errorMessage
        )
    }

    private static func nextActionInstruction(for action: MCPPageNextAction) -> String {
        switch action {
        case .detectMasks:
            "狀態提示：步驟二的區域、遮罩或去字背景尚未完成；請先在 App 完成步驟二。"
        case .submitRegions:
            "狀態提示：目前沒有 App 區域；只有使用者要求補區域時才提交。"
        case .writeSourceText:
            "狀態提示：部分區域缺少原文；優先使用單頁 Agent 工作包一次處理。"
        case .writeTranslation:
            "狀態提示：步驟三的原文、譯文或排字預覽尚未完成；請使用單頁 Agent 工作包一次處理。"
        case .compose:
            "狀態提示：步驟三預覽已完成；只有使用者要求輸出時才呼叫 page.render 儲存。"
        case .done:
            "狀態提示：本頁已有完整產物，除非使用者明確要求修改，否則不需操作。"
        }
    }

    func supplementRegions(
        workspaceID: UUID,
        pageID: UUID,
        proposals: [MCPAgentRegionProposal]
    ) async throws -> MCPAgentSupplementResult {
        try await requireWorkspace(workspaceID)
        guard !proposals.isEmpty, proposals.count <= 64 else {
            throw MCPServiceError.invalidArguments("regions 每次必須包含 1...64 個候選區域。")
        }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }

        var occupiedBounds = pages[pageIndex].regions.map(\.bounds)
        var accepted: [DialogueRegion] = []
        var skippedCount = 0

        for (offset, proposal) in proposals.enumerated() {
            let bounds = proposal.bounds.clamped()
            guard bounds.width > 0, bounds.height > 0 else {
                throw MCPServiceError.invalidArguments("regions[\(offset)].bounds 裁切至圖片後不可為空。")
            }
            let sourceText = proposal.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty else {
                throw MCPServiceError.invalidArguments("regions[\(offset)].source_text 不可為空。")
            }
            if occupiedBounds.contains(where: { Self.isDuplicate(bounds, of: $0) }) {
                skippedCount += 1
                continue
            }

            let bubbleBounds = proposal.bubbleBounds?.clamped()
            if let bubbleBounds, bubbleBounds.width <= 0 || bubbleBounds.height <= 0 {
                throw MCPServiceError.invalidArguments("regions[\(offset)].bubble_bounds 裁切至圖片後不可為空。")
            }
            var style = options.defaultStyle
            if let writingDirection = proposal.writingDirection {
                style.writingDirection = writingDirection
            }
            accepted.append(DialogueRegion(
                bounds: bounds,
                bubbleBounds: bubbleBounds,
                sourceText: sourceText,
                ocrTextRefined: true,
                confidence: 0.5,
                style: style,
                maskRefinementApplied: false,
                maskCoverageRatio: nil,
                maskCoverageComplete: false
            ))
            occupiedBounds.append(bounds)
        }

        guard !accepted.isEmpty else {
            return MCPAgentSupplementResult(
                page: pages[pageIndex],
                acceptedRegionIDs: [],
                skippedCount: skippedCount,
                warnings: []
            )
        }

        accepted = try await regionEditor.materialize(
            regions: accepted,
            refining: accepted.map(\.id),
            page: pages[pageIndex],
            options: options,
            regeneratesMask: false
        ).regions
        let warnings = accepted.compactMap { region -> String? in
            guard !region.maskCoverageComplete else { return nil }
            let ratio = region.maskCoverageRatio.map { String(format: "%.1f%%", $0 * 100) }
                ?? "無法計算"
            return "區域 \(region.id.uuidString) 的像素遮罩覆蓋檢查未通過（\(ratio)）；請擴大 bounds／bubble_bounds 後重新執行 page.detect_masks。"
        }
        pages[pageIndex].regions.append(contentsOf: accepted)
        let maskURL = try await pipeline.regenerateMask(
            page: pages[pageIndex],
            regions: pages[pageIndex].regions,
            options: options
        )
        let backgroundURL = try await pipeline.renderMaskPreview(
            page: pages[pageIndex],
            regions: pages[pageIndex].regions,
            maskURL: maskURL,
            fillColorHex: options.eraseColorHex
        )
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = backgroundURL
        pages[pageIndex].superResolvedBackgroundURL = nil
        pages[pageIndex].translationPreviewURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        try await persistStringTable(pageID: pageID)
        await publishStateChange()

        return MCPAgentSupplementResult(
            page: pages[pageIndex],
            acceptedRegionIDs: accepted.map(\.id),
            skippedCount: skippedCount,
            warnings: warnings
        )
    }

    func updateRegion(
        workspaceID: UUID,
        pageID: UUID,
        regionID: UUID,
        sourceText: String?,
        translatedText: String?,
        translationAnchor: MCPFieldUpdate<NormalizedPoint>,
        bounds: NormalizedRect?,
        bubbleBounds: MCPFieldUpdate<NormalizedRect>,
        fontName: String?,
        fontSize: MCPFieldUpdate<Double>,
        fontWeight: DialogueFontWeight?,
        useAutomaticFontSize: Bool?,
        writingDirection: WritingDirection?,
        textAlignment: DialogueTextAlignment?,
        textColorHex: String?,
        strokeColorHex: String?,
        strokeWidth: Double?,
        opacity: Double?,
        rotationDegrees: Double?,
        isVisible: Bool?
    ) async throws -> DialogueRegion {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        var edit = RegionEdit()
        edit.sourceText = sourceText
        edit.translatedText = translatedText
        edit.translationAnchor = translationAnchor
        edit.bounds = bounds
        edit.bubbleBounds = bubbleBounds
        edit.fontName = fontName
        edit.fontSize = fontSize
        edit.useAutomaticFontSize = useAutomaticFontSize
        edit.fontWeight = fontWeight
        edit.writingDirection = writingDirection
        edit.textAlignment = textAlignment
        edit.textColorHex = textColorHex
        edit.strokeColorHex = strokeColorHex
        edit.strokeWidth = strokeWidth
        edit.opacity = opacity
        edit.rotationDegrees = rotationDegrees
        edit.isVisible = isVisible
        edit.sourceTextChangesMaskGeometry = false
        let geometryChanged = PageRegionEditor.apply(
            edit,
            to: &pages[pageIndex].regions[regionIndex]
        )
        let shouldRegenerateMask = geometryChanged
        if geometryChanged {
            let outcome = try await regionEditor.materialize(
                regions: pages[pageIndex].regions,
                refining: [regionID],
                page: pages[pageIndex],
                options: options,
                regeneratesMask: false
            )
            pages[pageIndex].regions = outcome.regions
        }
        pages[pageIndex].outputURL = nil
        pages[pageIndex].translationPreviewURL = nil
        if shouldRegenerateMask {
            try await refreshEditedPage(pageIndex: pageIndex)
        } else {
            pages[pageIndex].stage = pages[pageIndex].regions.contains(where: { !$0.translatedText.isEmpty })
                ? .translating
                : .maskReady
            pages[pageIndex].progress = 0.25
            pages[pageIndex].errorMessage = nil
            try await persistStringTable(pageID: pageID)
        }
        await publishStateChange()
        return pages[pageIndex].regions[regionIndex]
    }

    func batchUpdateRegions(
        workspaceID: UUID,
        pageID: UUID,
        expectedRevision: String,
        patches: [MCPRegionPatch]
    ) async throws -> MCPRegionBatchResult {
        try await requireWorkspace(workspaceID)
        guard !patches.isEmpty, patches.count <= 64 else {
            throw MCPServiceError.invalidArguments("regions 每次必須包含 1...64 個 patch。")
        }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        try Self.requireRevision(expectedRevision, for: pages[pageIndex])

        let patchIDs = patches.map(\.regionID)
        guard Set(patchIDs).count == patchIDs.count else {
            throw MCPServiceError.invalidArguments("regions 不可包含重複的 region_id。")
        }
        let currentIDs = Set(pages[pageIndex].regions.map(\.id))
        guard patchIDs.allSatisfy(currentIDs.contains) else {
            throw MCPServiceError.regionNotFound
        }

        var updatedRegions = pages[pageIndex].regions
        var geometryChangedIDs: [UUID] = []
        for patch in patches {
            guard let regionIndex = updatedRegions.firstIndex(where: { $0.id == patch.regionID }) else {
                throw MCPServiceError.regionNotFound
            }
            let geometryChanged = PageRegionEditor.apply(
                Self.regionEdit(from: patch),
                to: &updatedRegions[regionIndex]
            )
            if geometryChanged {
                geometryChangedIDs.append(patch.regionID)
            }
        }

        var regeneratedMaskURL: URL?
        var regeneratedBackgroundURL: URL?
        if !geometryChangedIDs.isEmpty {
            let outcome = try await regionEditor.materialize(
                regions: updatedRegions,
                refining: geometryChangedIDs,
                page: pages[pageIndex],
                options: options,
                regeneratesMask: false
            )
            updatedRegions = outcome.regions
            regeneratedMaskURL = try await pipeline.regenerateMask(
                page: pages[pageIndex],
                regions: updatedRegions,
                options: options
            )
            if let regeneratedMaskURL {
                regeneratedBackgroundURL = try await pipeline.renderMaskPreview(
                    page: pages[pageIndex],
                    regions: updatedRegions,
                    maskURL: regeneratedMaskURL,
                    fillColorHex: options.eraseColorHex
                )
            }
        }

        pages[pageIndex].regions = updatedRegions
        pages[pageIndex].outputURL = nil
        pages[pageIndex].translationPreviewURL = nil
        if let regeneratedMaskURL {
            pages[pageIndex].maskURL = regeneratedMaskURL
            pages[pageIndex].backgroundURL = regeneratedBackgroundURL
            pages[pageIndex].superResolvedBackgroundURL = nil
        }
        let hasTranslatedText = updatedRegions.contains(where: { !$0.translatedText.isEmpty })
        pages[pageIndex].stage = geometryChangedIDs.isEmpty && hasTranslatedText
            ? .translating
            : .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        try await persistStringTable(pageID: pageID)
        await publishStateChange()

        return MCPRegionBatchResult(
            workspaceID: workspaceID,
            pageID: pageID,
            revision: try Self.revision(for: pages[pageIndex]),
            updatedRegionIDs: patchIDs,
            regions: pages[pageIndex].regions
        )
    }

    func reorderRegions(
        workspaceID: UUID,
        pageID: UUID,
        expectedRevision: String,
        orderedRegionIDs: [UUID]
    ) async throws -> MCPRegionBatchResult {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        try Self.requireRevision(expectedRevision, for: pages[pageIndex])

        let existingIDs = pages[pageIndex].regions.map(\.id)
        guard orderedRegionIDs.count == existingIDs.count,
              Set(orderedRegionIDs).count == orderedRegionIDs.count,
              Set(orderedRegionIDs) == Set(existingIDs) else {
            throw MCPServiceError.invalidArguments(
                "ordered_region_ids 必須且只能包含本頁目前全部 region_id。"
            )
        }
        let regionsByID = Dictionary(uniqueKeysWithValues: pages[pageIndex].regions.map { ($0.id, $0) })
        pages[pageIndex].regions = orderedRegionIDs.compactMap { regionsByID[$0] }
        pages[pageIndex].outputURL = nil
        pages[pageIndex].translationPreviewURL = nil
        pages[pageIndex].stage = pages[pageIndex].regions.contains(where: { !$0.translatedText.isEmpty })
            ? .translating
            : .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        try await persistStringTable(pageID: pageID)
        await publishStateChange()

        return MCPRegionBatchResult(
            workspaceID: workspaceID,
            pageID: pageID,
            revision: try Self.revision(for: pages[pageIndex]),
            updatedRegionIDs: orderedRegionIDs,
            regions: pages[pageIndex].regions
        )
    }

    func renderPage(
        workspaceID: UUID,
        pageID: UUID,
        expectedRevision: String,
        progress: @escaping Progress
    ) async throws -> MCPPageMutationResult {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        try Self.requireRevision(expectedRevision, for: pages[pageIndex])
        guard hasMaskData(pageID: pageID) else { throw MCPServiceError.maskRequired }
        guard hasTranslationData(pageID: pageID) else {
            throw MCPServiceError.translationPreviewRequired
        }

        let pageProgress: PagePipelineProgress = { stage, fraction in
            progress(fraction, "\(stage.rawValue)：\(pageID.uuidString)")
        }
        try await compose(pageID: pageID, progress: pageProgress)
        await publishStateChange()
        return try Self.makeMutationResult(workspaceID: workspaceID, page: pages[pageIndex])
    }

    func createRegion(
        workspaceID: UUID,
        pageID: UUID,
        bounds: NormalizedRect
    ) async throws -> DialogueRegion {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        let region = DialogueRegion(
            bounds: bounds.clamped(),
            sourceText: "",
            confidence: 1,
            style: options.defaultStyle
        )
        let outcome = try await regionEditor.created(
            region,
            appendingTo: pages[pageIndex].regions,
            page: pages[pageIndex],
            options: options
        )
        pages[pageIndex].regions = outcome.regions
        try await refreshEditedPage(pageIndex: pageIndex)
        await publishStateChange()
        return pages[pageIndex].regions[pages[pageIndex].regions.count - 1]
    }

    func removeRegion(workspaceID: UUID, pageID: UUID, regionID: UUID) async throws -> ComicPage {
        try await requireWorkspace(workspaceID)
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        pages[pageIndex].regions.remove(at: regionIndex)
        try await refreshEditedPage(pageIndex: pageIndex)
        await publishStateChange()
        return pages[pageIndex]
    }

    func state() async -> MCPWorkspaceState {
        if let workspaceID {
            try? await requireWorkspace(workspaceID)
        }
        return await currentState()
    }

    private func currentState() async -> MCPWorkspaceState {
        return MCPWorkspaceState(
            workspaceID: workspaceID,
            name: sourceDirectoryURL?.lastPathComponent,
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            options: options,
            regionSource: regionSource,
            glossary: glossary,
            pages: pages,
            loadedModels: await models.loadedModels()
        )
    }

    func resources() async -> [ComicPage] {
        if let workspaceID {
            try? await requireWorkspace(workspaceID)
        }
        return pages
    }

    func readResource(uri: String) async throws -> MCPResourcePayload {
        if let workspaceID {
            try await requireWorkspace(workspaceID)
        }
        if uri == "mangakitchen://contract/current" {
            return .text(
                try Self.json(MCPContractDescription.current),
                mimeType: "application/json"
            )
        }
        if uri == "mangakitchen://workspace/list" {
            return .text(try Self.json(await listWorkspaces()), mimeType: "application/json")
        }
        if uri == "mangakitchen://workspace/current" {
            return .text(try Self.json(await state()), mimeType: "application/json")
        }
        if uri == "mangakitchen://workspace/current/pages" {
            guard let workspaceID else { throw MCPServiceError.workspaceNotOpen }
            return .text(
                try Self.json(await pageTasks(workspaceID: workspaceID, pendingOnly: false)),
                mimeType: "application/json"
            )
        }
        if uri == "mangakitchen://workspace/current/glossary" {
            return .text(try Self.json(glossary.entries), mimeType: "application/json")
        }
        guard let url = URL(string: uri), url.scheme == "mangakitchen" else {
            throw MCPServiceError.resourceNotFound(uri)
        }
        let components = url.pathComponents.filter { $0 != "/" }
        if url.host == "workspace",
           components.count == 2,
           components[1] == "capabilities",
           let requestedWorkspaceID = UUID(uuidString: components[0]) {
            return .text(
                try Self.json(
                    await workspaceCapabilities(workspaceID: requestedWorkspaceID)
                ),
                mimeType: "application/json"
            )
        }
        guard url.host == "page" else {
            throw MCPServiceError.resourceNotFound(uri)
        }
        guard let rawID = components.first, let pageID = UUID(uuidString: rawID),
              let page = pages.first(where: { $0.id == pageID }) else {
            throw MCPServiceError.resourceNotFound(uri)
        }
        if components.count == 1 {
            guard let workspaceID else { throw MCPServiceError.workspaceNotOpen }
            return .text(
                try Self.json(Self.makeInspection(workspaceID: workspaceID, page: page)),
                mimeType: "application/json"
            )
        }
        switch components[1] {
        case "source":
            return .binary(
                try Data(contentsOf: page.sourceURL),
                mimeType: Self.imageMIMEType(for: page.sourceURL)
            )
        case "strings":
            return .text(
                try Self.json(
                    ComicStringTable(
                        page: page,
                        targetLanguageCode: options.resolvedTargetLanguageCode
                    )
                ),
                mimeType: "application/json"
            )
        case "regions":
            guard let workspaceID else { throw MCPServiceError.workspaceNotOpen }
            return .text(
                try Self.json(MCPPageRegionsResource(
                    workspaceID: workspaceID,
                    pageID: page.id,
                    revision: Self.revision(for: page),
                    regions: page.regions
                )),
                mimeType: "application/json"
            )
        case "mask":
            guard let maskURL = page.maskURL else { throw MCPServiceError.resourceNotFound(uri) }
            return .binary(try Data(contentsOf: maskURL), mimeType: "image/png")
        case "output":
            guard let outputURL = page.outputURL else { throw MCPServiceError.resourceNotFound(uri) }
            return .binary(try Data(contentsOf: outputURL), mimeType: "image/png")
        default:
            throw MCPServiceError.resourceNotFound(uri)
        }
    }

    /// 步驟二。預設由 App 內建 Core ML 建立區域與遮罩；步驟三一律交給 Agent。
    private func detect(pageID: UUID, progress: @escaping PagePipelineProgress) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        switch regionSource {
        case .agent:
            try await detectByAgentSuppliedRegions(pageIndex: index, progress: progress)
        case .local:
            try await detectByLocalPipeline(pageIndex: index, progress: progress)
        }
        try await persistStringTable(pageID: pageID)
    }

    /// Agent 區域後備模式：不呼叫內建封閉區域偵測或圖生文模型。只把 Agent 目前
    /// 提供的區域收斂成像素級遮罩並輸出遮罩圖；沒有區域時就產生空白遮罩，等 Agent 補齊。
    private func detectByAgentSuppliedRegions(
        pageIndex: Int,
        progress: @escaping PagePipelineProgress
    ) async throws {
        progress(.detectingText, 0)
        // 絕不覆寫 Agent 已提供的區域：這一步只重算遮罩，不做辨識。
        let regionsForRefinement = Self.resetMaskGeometry(pages[pageIndex].regions)
        let outcome = try await regionEditor.materialize(
            regions: regionsForRefinement,
            refining: regionsForRefinement.map(\.id),
            page: pages[pageIndex],
            options: options,
            regeneratesMask: true
        )
        progress(.detectingText, 0.6)
        guard let maskURL = outcome.maskURL else { return }
        let backgroundURL = try await pipeline.renderMaskPreview(
            page: pages[pageIndex],
            regions: outcome.regions,
            maskURL: maskURL,
            fillColorHex: options.eraseColorHex
        )
        pages[pageIndex].regions = outcome.regions
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = backgroundURL
        pages[pageIndex].superResolvedBackgroundURL = nil
        pages[pageIndex].translationPreviewURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        progress(.maskReady, 1)
    }

    /// 預設 App-first 模式：只以氣泡 BBOX 與像素精修建立遮罩，並保留 Agent 已寫入的資料。
    private func detectByLocalPipeline(
        pageIndex: Int,
        progress: @escaping PagePipelineProgress
    ) async throws {
        let previousRegions = pages[pageIndex].regions
        let result = try await pipeline.detectMasks(
            page: pages[pageIndex],
            options: options,
            progress: progress
        )
        let regions = Self.mergeAgentEditingState(
            from: previousRegions,
            into: result.regions
        )
        let maskURL = try await pipeline.regenerateMask(
            page: pages[pageIndex],
            regions: regions,
            options: options
        )
        let backgroundURL = try await pipeline.renderMaskPreview(
            page: pages[pageIndex],
            regions: regions,
            maskURL: maskURL,
            fillColorHex: options.eraseColorHex
        )
        pages[pageIndex].regions = regions
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = backgroundURL
        pages[pageIndex].superResolvedBackgroundURL = nil
        pages[pageIndex].translationPreviewURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
    }

    /// 步驟四：只把步驟三已完成的翻譯排字預覽存到輸出位置。
    private func compose(pageID: UUID, progress: @escaping PagePipelineProgress) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        guard let outputDirectoryURL else { throw MCPServiceError.outputDirectoryRequired }
        let paths = try pathResolver.paths(
            sourceURL: pages[index].sourceURL,
            relativeSourcePath: pages[index].relativeSourcePath ?? pages[index].sourceURL.lastPathComponent,
            outputDirectoryURL: outputDirectoryURL
        )
        guard paths.outputURL.standardizedFileURL != pages[index].sourceURL.standardizedFileURL else {
            throw MCPServiceError.outputWouldOverwriteSource
        }
        guard let previewURL = pages[index].translationPreviewURL,
              FileManager.default.fileExists(atPath: previewURL.path) else {
            throw MCPServiceError.translationPreviewRequired
        }
        try Task.checkCancellation()
        progress(.composing, 0)
        try FileManager.default.createDirectory(
            at: paths.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previewData = try Data(contentsOf: previewURL)
        try previewData.write(to: paths.outputURL, options: .atomic)
        progress(.completed, 1)
        pages[index].outputURL = paths.outputURL
        pages[index].stage = .completed
        pages[index].progress = 1
        pages[index].errorMessage = nil
        try await persistStringTable(pageID: pageID)
    }

    private func refreshEditedPage(pageIndex: Int) async throws {
        let pageID = pages[pageIndex].id
        let maskURL = try await pipeline.regenerateMask(
            page: pages[pageIndex],
            regions: pages[pageIndex].regions,
            options: options
        )
        let backgroundURL = try await pipeline.renderMaskPreview(
            page: pages[pageIndex],
            regions: pages[pageIndex].regions,
            maskURL: maskURL,
            fillColorHex: options.eraseColorHex
        )
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = backgroundURL
        pages[pageIndex].superResolvedBackgroundURL = nil
        pages[pageIndex].translationPreviewURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        try await persistStringTable(pageID: pageID)
    }

    private static func isDuplicate(_ candidate: NormalizedRect, of existing: NormalizedRect) -> Bool {
        let overlap = candidate.intersection(with: existing)
        let overlapArea = overlap.width * overlap.height
        guard overlapArea > 0 else { return false }
        let candidateArea = max(candidate.width * candidate.height, .leastNonzeroMagnitude)
        let existingArea = max(existing.width * existing.height, .leastNonzeroMagnitude)
        return overlapArea / candidateArea >= 0.5 && overlapArea / existingArea >= 0.5
    }

    private static func mergeAgentEditingState(
        from previousRegions: [DialogueRegion],
        into detectedRegions: [DialogueRegion]
    ) -> [DialogueRegion] {
        var matchedRegionIDs = Set<UUID>()
        return detectedRegions.map { detectedRegion in
            let match = previousRegions
                .filter { !matchedRegionIDs.contains($0.id) }
                .compactMap { previousRegion -> (region: DialogueRegion, score: Double)? in
                    let intersection = detectedRegion.bounds.intersection(with: previousRegion.bounds)
                    let intersectionArea = intersection.width * intersection.height
                    let detectedArea = detectedRegion.bounds.width * detectedRegion.bounds.height
                    let previousArea = previousRegion.bounds.width * previousRegion.bounds.height
                    let minimumArea = min(detectedArea, previousArea)
                    guard intersectionArea > 0, minimumArea > 0 else { return nil }
                    return (previousRegion, intersectionArea / minimumArea)
                }
                .max { left, right in left.score < right.score }

            guard let match, match.score >= 0.25 else { return detectedRegion }
            matchedRegionIDs.insert(match.region.id)
            var mergedRegion = detectedRegion
            mergedRegion.id = match.region.id
            if !match.region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mergedRegion.rawSourceText = match.region.rawSourceText ?? match.region.sourceText
                mergedRegion.sourceText = match.region.sourceText
                mergedRegion.ocrTextRefined = match.region.ocrTextRefined
            }
            mergedRegion.translatedText = match.region.translatedText
            mergedRegion.translationAnchor = match.region.translationAnchor
            mergedRegion.translationBounds = match.region.translationBounds
            mergedRegion.style = match.region.style
            mergedRegion.maskStrokes = match.region.maskStrokes
            return mergedRegion
        }
    }

    private static func resetMaskGeometry(_ regions: [DialogueRegion]) -> [DialogueRegion] {
        regions.map { region in
            var resetRegion = region
            resetRegion.maskPolygons = []
            resetRegion.maskRefinementApplied = false
            resetRegion.maskCoverageRatio = nil
            resetRegion.maskCoverageComplete = false
            return resetRegion
        }
    }

    private func persistStringTable(pageID: UUID) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        let fileURL = try stringTableURL(for: pages[index])
        pages[index].stringTableURL = fileURL
        let table = ComicStringTable(
            page: pages[index],
            targetLanguageCode: options.resolvedTargetLanguageCode
        )
        try await stringTables.save(table, to: fileURL)
    }

    private func stringTableURL(for page: ComicPage) throws -> URL {
        pathResolver.stringTableURL(for: page.sourceURL)
    }

    private func resolvePageIDs(_ requested: [UUID]?) throws -> [UUID] {
        let ids = requested?.isEmpty == false ? requested! : pages.map(\.id)
        let known = Set(pages.map(\.id))
        guard ids.allSatisfy(known.contains) else { throw MCPServiceError.pageNotFound }
        return ids
    }

    private func requireWorkspace(_ id: UUID) async throws {
        let sourceURL: URL
        if workspaceID == id, let sourceDirectoryURL {
            sourceURL = sourceDirectoryURL
        } else if let context = workspaces[id] {
            sourceURL = context.sourceDirectoryURL
        } else {
            throw MCPServiceError.workspaceNotFound
        }
        if let snapshot = await stateProvider?(sourceURL.standardizedFileURL) {
            saveActiveWorkspace()
            workspaceID = id
            sourceDirectoryURL = snapshot.sourceDirectoryURL?.standardizedFileURL ?? sourceURL
            outputDirectoryURL = snapshot.outputDirectoryURL?.standardizedFileURL
            options = snapshot.options
            options.useImageToImageRestoration = false
            regionSource = workspaces[id]?.regionSource ?? regionSource
            glossary = snapshot.glossary
            pages = snapshot.pages
            saveActiveWorkspace()
        } else {
            try activateWorkspaceContext(id)
        }
    }

    private func activateWorkspaceContext(_ id: UUID) throws {
        guard workspaceID != id else { return }
        guard let context = workspaces[id] else { throw MCPServiceError.workspaceNotFound }
        saveActiveWorkspace()
        workspaceID = context.id
        sourceDirectoryURL = context.sourceDirectoryURL
        outputDirectoryURL = context.outputDirectoryURL
        var restoredOptions = context.options
        restoredOptions.useImageToImageRestoration = false
        options = restoredOptions
        regionSource = context.regionSource
        glossary = context.glossary
        pages = context.pages
    }

    private func saveActiveWorkspace() {
        guard let workspaceID, let sourceDirectoryURL else { return }
        let name = workspaces[workspaceID]?.name ?? sourceDirectoryURL.lastPathComponent
        workspaces[workspaceID] = MCPWorkspaceContext(
            id: workspaceID,
            name: name,
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            options: options,
            glossary: glossary,
            pages: pages,
            regionSource: regionSource
        )
    }

    private func publishStateChange() async {
        saveActiveWorkspace()
        guard let stateChangeHandler else { return }
        await stateChangeHandler(await currentState())
    }

    private func validateOutputDirectory(_ output: URL, sourceDirectoryURL: URL) throws {
        let sourcePath = sourceDirectoryURL.standardizedFileURL.path
        let outputPath = output.standardizedFileURL.path
        if outputPath == sourcePath || outputPath.hasPrefix(sourcePath + "/") {
            throw MCPServiceError.outputInsideSource
        }
    }

    private static func stageFraction(stage: PageProcessingStage, fraction: Double) -> Double {
        let value = min(max(fraction, 0), 1)
        return switch stage {
        case .pending: 0
        case .scanned: 0.02
        case .detectingText: value * 0.25
        case .maskReady: 0.25
        case .translating: 0.25 + value * 0.4
        case .translationReady: 0.65
        case .superResolving: 0.65 + value * 0.35
        case .composing: 0.65 + value * 0.35
        case .recognizing: value * 0.15
        case .masking: 0.55 + value * 0.05
        case .restoringBackground: 0.6 + value * 0.25
        case .typesetting: 0.85 + value * 0.15
        case .completed: 1
        case .failed: 0
        }
    }

    private static func makeWorkspaceRoot(dataDirectoryPath: String?) throws -> URL {
        let root = try ApplicationDirectories.applicationSupportRoot(customPath: dataDirectoryPath)
            .appendingPathComponent("MCPWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeInspection(
        workspaceID: UUID,
        page: ComicPage
    ) throws -> MCPPageInspection {
        let identifier = page.id.uuidString.lowercased()
        let sourceExists = FileManager.default.fileExists(atPath: page.sourceURL.path)
        let maskExists = page.maskURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let backgroundExists = page.backgroundURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let superResolvedExists = page.superResolvedBackgroundURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let translationPreviewExists = page.translationPreviewURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let outputExists = page.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        var operations = [
            "mangakitchen.page.inspect",
            "mangakitchen.page.update"
        ]
        if maskExists,
           backgroundExists,
           !page.regions.isEmpty {
            operations.append("mangakitchen.page.prepare_agent_task")
        }
        if !page.regions.isEmpty {
            operations.append("mangakitchen.region.batch_update")
        }
        if page.regions.count > 1 {
            operations.append("mangakitchen.region.reorder")
        }
        if translationPreviewExists,
           page.regions.allSatisfy({ !$0.translatedText.isEmpty }) {
            operations.append("mangakitchen.page.render")
        }
        return MCPPageInspection(
            workspaceID: workspaceID,
            contractVersion: MCPContractDescription.current.contractVersion,
            revision: try revision(for: page),
            page: page,
            artifacts: MCPPageArtifacts(
                hasSource: sourceExists,
                hasMask: maskExists,
                hasBackground: backgroundExists,
                hasSuperResolvedBackground: superResolvedExists,
                hasTranslationPreview: translationPreviewExists,
                hasOutput: outputExists,
                sourceURI: "mangakitchen://page/\(identifier)/source",
                maskURI: maskExists ? "mangakitchen://page/\(identifier)/mask" : nil,
                outputURI: outputExists ? "mangakitchen://page/\(identifier)/output" : nil
            ),
            availableOperations: operations,
            regionsURI: "mangakitchen://page/\(identifier)/regions"
        )
    }

    private static func makeMutationResult(
        workspaceID: UUID,
        page: ComicPage
    ) throws -> MCPPageMutationResult {
        MCPPageMutationResult(
            workspaceID: workspaceID,
            revision: try revision(for: page),
            page: page
        )
    }

    private static func revision(for page: ComicPage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(page)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "page-%016llx", hash)
    }

    private static func requireRevision(_ expected: String, for page: ComicPage) throws {
        let current = try revision(for: page)
        guard expected == current else {
            throw MCPServiceError.revisionConflict(expected: expected, current: current)
        }
    }

    private static func regionEdit(from patch: MCPRegionPatch) -> RegionEdit {
        var edit = RegionEdit()
        edit.sourceText = patch.sourceText
        edit.translatedText = patch.translatedText
        edit.translationAnchor = patch.translationAnchor
        edit.translationBounds = patch.translationBounds
        edit.bounds = patch.bounds
        edit.bubbleBounds = patch.bubbleBounds
        edit.fontName = patch.fontName
        edit.fontSize = patch.fontSize
        edit.useAutomaticFontSize = patch.automaticFontSize
        edit.fontWeight = patch.fontWeight
        edit.writingDirection = patch.writingDirection
        edit.textAlignment = patch.textAlignment
        edit.textColorHex = patch.textColorHex
        edit.strokeColorHex = patch.strokeColorHex
        edit.strokeWidth = patch.strokeWidth
        edit.opacity = patch.opacity
        edit.rotationDegrees = patch.rotationDegrees
        edit.isVisible = patch.isVisible
        edit.sourceTextChangesMaskGeometry = false
        return edit
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func imageMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}

enum MCPServiceError: LocalizedError {
    case workspaceNotOpen
    case workspaceNotFound
    case pageNotFound
    case regionNotFound
    case glossaryEntryNotFound
    case maskRequired
    case maskDataRequired
    case agentTranslationRequired
    case translationPreviewRequired
    case outputDirectoryRequired
    case outputInsideSource
    case outputWouldOverwriteSource
    case resourceNotFound(String)
    case revisionConflict(expected: String, current: String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotOpen: "尚未開啟漫畫廚房工作區。"
        case .workspaceNotFound: "workspace_id 不存在或已失效。"
        case .pageNotFound: "找不到指定的 page_id。"
        case .regionNotFound: "找不到指定的 region_id。"
        case .glossaryEntryNotFound: "找不到指定的 glossary entry_id。"
        case .maskRequired: "翻譯前必須先完成步驟二的文字區域、遮罩與去字背景。"
        case .maskDataRequired: "步驟二的區域、遮罩或去字背景尚未完成；請先在 App 完成並確認步驟二，再呼叫 page.prepare_agent_task。後續步驟不會代跑步驟二。"
        case .agentTranslationRequired:
            "MCP 步驟三由 Agent 接手，不會呼叫 App 內建圖生文模型。請先呼叫 page.prepare_agent_task，完成全部區域原文、譯文與排版後，以 page.submit_agent_result 一次回寫。"
        case .translationPreviewRequired:
            "步驟三尚未完成翻譯排字預覽；請先完成 page.submit_agent_result，再執行 page.render 儲存輸出。"
        case .outputDirectoryRequired: "合成前必須設定輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片。"
        case let .resourceNotFound(uri): "找不到 MCP resource：\(uri)"
        case let .revisionConflict(expected, current):
            "頁面 revision 已變更，拒絕覆蓋較新的資料（expected_revision=\(expected)，current_revision=\(current)）。請重新 inspect 後再提交。"
        case let .invalidArguments(message): message
        }
    }
}
