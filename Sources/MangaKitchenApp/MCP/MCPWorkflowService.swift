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

/// Agent 自行迴圈處理時的工作清單項目。
///
/// 刻意不含 regions：`ComicPage` 內嵌完整 `DialogueRegion`（含數千點的
/// maskPolygons），整個專案列出來會是巨大的 payload。這裡只給「還差什麼」，
/// Agent 依 nextAction 決定要不要進一步讀取該頁的詳細資源。
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
    var hasOutput: Bool
    /// Agent 對這一頁應該做的下一件事。
    var nextAction: MCPPageNextAction
    var sourceURI: String
    var pageURI: String
    var errorMessage: String?
}

/// 工作流只有這幾種待辦狀態；Agent 可直接依此分派，不必自行推導。
enum MCPPageNextAction: String, Codable, Sendable {
    /// 這一頁還沒有任何區域：讀原圖後用 page.supplement_regions 提交。
    case submitRegions
    /// 有區域但原文不完整：用 region.update 寫回 source_text。
    case writeSourceText
    /// 原文齊全但缺譯文：用 region.update 寫入 translated_text。
    case writeTranslation
    /// 譯文齊全但尚未輸出：執行 page.compose。
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

    private let models: ModelRuntimeHub
    /// 用來把 Agent 目測的粗框對齊到本機偵測；兩種 region_source 都會用到。
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
    /// 區域從哪裡來。翻譯在兩種模式下都固定由 Agent 負責。
    private var regionSource: MCPRegionSource = .agent
    private var glossary = ProjectGlossary()
    private var pages: [ComicPage] = []
    private var workspaces: [UUID: MCPWorkspaceContext] = [:]

    init(
        dataDirectoryPath: String?,
        imageCompositingBackend: ImageCompositingBackend = .cpu
    ) throws {
        let metal = try MetalContext()
        let models = ModelRuntimeHub(metal: metal)
        let root = try Self.makeWorkspaceRoot(dataDirectoryPath: dataDirectoryPath)
        self.models = models
        self.workspaceRoot = root
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
            try activateWorkspaceContext(existing.id)
        } else {
            saveActiveWorkspace()
            let newWorkspaceID = UUID()
            workspaceID = newWorkspaceID
            self.sourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
            self.outputDirectoryURL = outputDirectoryURL?.standardizedFileURL
            options = ProcessingOptions()
            regionSource = .agent
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
        for index in pages.indices {
            let tableURL = try stringTableURL(for: pages[index])
            if let table = try await stringTables.load(from: tableURL) {
                pages[index].regions = table.regions
                pages[index].stringTableURL = tableURL
                pages[index].stage = table.entries.contains(where: { !$0.translatedText.isEmpty })
                    ? .translationReady
                    : .maskReady
            }
        }
        saveActiveWorkspace()
        return await state()
    }

    func listWorkspaces() async -> [MCPWorkspaceState] {
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
        try activateWorkspaceContext(workspaceID)
        return await state()
    }

    func rescanWorkspace(workspaceID: UUID) async throws -> MCPWorkspaceState {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
                page.stage = table.entries.contains(where: { !$0.translatedText.isEmpty })
                    ? .translationReady
                    : .maskReady
            }
            rescanned.append(page)
        }
        pages = rescanned
        return await state()
    }

    func setOutputDirectory(workspaceID: UUID, directoryURL: URL) async throws -> MCPWorkspaceState {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard let sourceDirectoryURL else { throw MCPServiceError.workspaceNotOpen }
        try validateOutputDirectory(directoryURL, sourceDirectoryURL: sourceDirectoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        outputDirectoryURL = directoryURL.standardizedFileURL
        return await state()
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
    ) throws -> MCPWorkspaceConfiguration {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
        return MCPWorkspaceConfiguration(options: options, regionSource: self.regionSource)
    }

    func loadModel(directoryURL: URL) async throws -> LoadedModelInfo {
        return try await models.loadModel(at: directoryURL)
    }

    func glossaryEntries(workspaceID: UUID) throws -> [GlossaryEntry] {
        try requireWorkspace(workspaceID)
        return glossary.entries
    }

    func upsertGlossaryEntry(
        workspaceID: UUID,
        entryID: UUID?,
        sourceTerm: String,
        translations: [String: String],
        note: String?
    ) throws -> GlossaryEntry {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
        return saved
    }

    func removeGlossaryEntry(workspaceID: UUID, entryID: UUID) throws -> [GlossaryEntry] {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard glossary.entries.contains(where: { $0.id == entryID }) else {
            throw MCPServiceError.glossaryEntryNotFound
        }
        glossary.remove(entryID: entryID)
        return glossary.entries
    }

    func run(
        workspaceID: UUID,
        step: MCPWorkflowStep,
        pageIDs requestedPageIDs: [UUID]?,
        progress: @escaping Progress
    ) async throws -> MCPWorkflowResult {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        let targetIDs = try resolvePageIDs(requestedPageIDs)
        // 純 Agent 模式沒有任何步驟會用到 imageToText，因此不再檢查該模型。
        // 需要譯文的步驟改由 AgentDrivenTranslator 拋出可操作的錯誤說明。
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
                if !hasMaskData(pageID: pageID) {
                    try await detect(pageID: pageID, progress: pageProgress)
                }
                try await translate(pageID: pageID, progress: pageProgress)
            case .compose:
                if !hasMaskData(pageID: pageID) {
                    try await detect(pageID: pageID, progress: pageProgress)
                }
                if !hasTranslationData(pageID: pageID) {
                    try await translate(pageID: pageID, progress: pageProgress)
                }
                try await compose(pageID: pageID, progress: pageProgress)
            case .fullPage:
                if !hasMaskData(pageID: pageID) {
                    try await detect(pageID: pageID, progress: pageProgress)
                }
                if !hasTranslationData(pageID: pageID) {
                    try await translate(pageID: pageID, progress: pageProgress)
                }
                if !hasCompletedOutput(pageID: pageID) {
                    try await compose(pageID: pageID, progress: pageProgress)
                }
            }
            progress(Double(offset + 1) / Double(targetIDs.count), "完成頁面：\(pageID.uuidString)")
        }
        return MCPWorkflowResult(
            workspaceID: workspaceID,
            operation: step.rawValue,
            processedPageIDs: targetIDs,
            pages: pages.filter { targetIDs.contains($0.id) }
        )
    }

    private func hasMaskData(pageID: UUID) -> Bool {
        guard let regions = pages.first(where: { $0.id == pageID })?.regions,
              !regions.isEmpty else { return false }
        return regions.allSatisfy(Self.hasUsableMask)
    }

    private static func hasUsableMask(_ region: DialogueRegion) -> Bool {
        if region.maskStrokes.contains(where: { $0.mode == .add }) { return true }
        return region.automaticMaskEnabled
    }

    private func hasTranslationData(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              !page.regions.isEmpty else { return false }
        return page.regions.allSatisfy {
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func hasCompletedOutput(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              page.stage == .completed,
              let outputURL = page.outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    /// 讓外部 MCP Agent 一次補入遺漏文字。Agent 可只提供粗框，後端會再做像素級遮罩精修。
    /// 與既有區域高度重疊的候選會略過，使同一批資料可安全重送。
    /// 專案的檔案工作清單，讓 Agent 收到使用者指令後可以自行迴圈處理。
    /// `pendingOnly` 預設為 true，只回傳還有待辦的頁面。
    func pageTasks(
        workspaceID: UUID,
        pendingOnly: Bool
    ) async throws -> MCPWorkspacePageList {
        try requireWorkspace(workspaceID)
        guard let context = workspaces[workspaceID] else {
            throw MCPServiceError.workspaceNotFound
        }
        let allTasks = context.pages.map(Self.makePageTask)
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

    private static func makePageTask(_ page: ComicPage) -> MCPPageTask {
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
        let hasOutput = page.outputURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let identifier = page.id.uuidString.lowercased()

        let nextAction: MCPPageNextAction
        if page.regions.isEmpty {
            nextAction = .submitRegions
        } else if missingSourceText > 0 {
            nextAction = .writeSourceText
        } else if missingTranslation > 0 {
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
            hasMask: page.maskURL != nil,
            hasOutput: hasOutput,
            nextAction: nextAction,
            sourceURI: "mangakitchen://page/\(identifier)/source",
            pageURI: "mangakitchen://page/\(identifier)",
            errorMessage: page.errorMessage
        )
    }

    func supplementRegions(
        workspaceID: UUID,
        pageID: UUID,
        proposals: [MCPAgentRegionProposal]
    ) async throws -> MCPAgentSupplementResult {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        try await persistStringTable(pageID: pageID)

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
        writingDirection: WritingDirection?
    ) async throws -> DialogueRegion {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
        if shouldRegenerateMask {
            try await refreshEditedPage(pageIndex: pageIndex)
        } else {
            pages[pageIndex].stage = pages[pageIndex].regions.contains(where: { !$0.translatedText.isEmpty })
                ? .translationReady
                : .maskReady
            try await persistStringTable(pageID: pageID)
        }
        return pages[pageIndex].regions[regionIndex]
    }

    func createRegion(
        workspaceID: UUID,
        pageID: UUID,
        bounds: NormalizedRect
    ) async throws -> DialogueRegion {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
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
        return pages[pageIndex].regions[pages[pageIndex].regions.count - 1]
    }

    func removeRegion(workspaceID: UUID, pageID: UUID, regionID: UUID) async throws -> ComicPage {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        pages[pageIndex].regions.remove(at: regionIndex)
        try await refreshEditedPage(pageIndex: pageIndex)
        return pages[pageIndex]
    }

    func state() async -> MCPWorkspaceState {
        saveActiveWorkspace()
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

    func resources() -> [ComicPage] {
        pages
    }

    func readResource(uri: String) async throws -> MCPResourcePayload {
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
        guard let url = URL(string: uri), url.scheme == "mangakitchen", url.host == "page" else {
            throw MCPServiceError.resourceNotFound(uri)
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let rawID = components.first, let pageID = UUID(uuidString: rawID),
              let page = pages.first(where: { $0.id == pageID }) else {
            throw MCPServiceError.resourceNotFound(uri)
        }
        if components.count == 1 {
            return .text(try Self.json(page), mimeType: "application/json")
        }
        switch components[1] {
        case "source":
            return .binary(
                try Data(contentsOf: page.sourceURL),
                mimeType: Self.imageMIMEType(for: page.sourceURL)
            )
        case "strings":
            return .text(
                try Self.json(ComicStringTable(page: page, targetLanguageCode: options.targetLanguageCode)),
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

    /// 步驟二。`regionSource` 決定區域從哪裡來；翻譯在兩種模式下都不會用本機模型。
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

    /// 純 Agent 模式：不呼叫內建封閉區域偵測或圖生文模型。只把 Agent 目前提供的區域
    /// 收斂成像素級遮罩並輸出遮罩圖；沒有區域時就產生空白遮罩，等 Agent 補齊。
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
        pages[pageIndex].regions = outcome.regions
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
        progress(.maskReady, 1)
    }

    /// 本機區域模式：只以氣泡 BBOX 與像素精修建立遮罩，並保留 Agent 已寫入的資料。
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
        pages[pageIndex].regions = regions
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].backgroundURL = nil
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = .maskReady
        pages[pageIndex].progress = 0.25
        pages[pageIndex].errorMessage = nil
    }

    private func translate(pageID: UUID, progress: @escaping PagePipelineProgress) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        guard !pages[index].regions.isEmpty else { throw MCPServiceError.maskRequired }
        let translated = try await pipeline.translate(
            page: pages[index],
            regions: pages[index].regions,
            options: options,
            glossary: glossary,
            progress: progress
        )
        pages[index].regions = translated
        pages[index].stage = .translationReady
        pages[index].progress = 0.65
        pages[index].errorMessage = nil
        try await persistStringTable(pageID: pageID)
    }

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
        let result = try await pipeline.compose(
            page: pages[index],
            regions: pages[index].regions,
            options: options,
            outputURL: paths.outputURL,
            existingMaskURL: pages[index].maskURL,
            progress: progress
        )
        pages[index].regions = result.regions
        pages[index].maskURL = result.maskURL
        pages[index].backgroundURL = result.backgroundURL
        pages[index].outputURL = result.outputURL
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
        pages[pageIndex].maskURL = maskURL
        pages[pageIndex].stage = pages[pageIndex].regions.contains(where: { !$0.translatedText.isEmpty })
            ? .translationReady
            : .maskReady
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
        let table = ComicStringTable(page: pages[index], targetLanguageCode: options.targetLanguageCode)
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

    private func requireWorkspace(_ id: UUID) throws {
        try activateWorkspaceContext(id)
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
    case agentTranslationRequired
    case outputDirectoryRequired
    case outputInsideSource
    case outputWouldOverwriteSource
    case resourceNotFound(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotOpen: "尚未開啟漫畫廚房工作區。"
        case .workspaceNotFound: "workspace_id 不存在或已失效。"
        case .pageNotFound: "找不到指定的 page_id。"
        case .regionNotFound: "找不到指定的 region_id。"
        case .glossaryEntryNotFound: "找不到指定的 glossary entry_id。"
        case .maskRequired: "翻譯前必須先執行文字與遮罩偵測。"
        case .agentTranslationRequired:
            "MCP 為純 Agent 模式，不會呼叫內建圖生文模型翻譯。請讀取頁面原圖後，以 region.update 的 translated_text 寫入譯文，再執行 page.compose。"
        case .outputDirectoryRequired: "合成前必須設定輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片。"
        case let .resourceNotFound(uri): "找不到 MCP resource：\(uri)"
        case let .invalidArguments(message): message
        }
    }
}
