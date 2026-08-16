import Combine
import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [ComicProjectSummary] = []
    @Published private(set) var activeProjectID: UUID?
    @Published private(set) var pages: [ComicPage] = []
    @Published private(set) var loadedModels: [LoadedModelInfo] = []
    @Published private(set) var sourceDirectoryURL: URL?
    @Published private(set) var outputDirectoryURL: URL?
    @Published var selectedPageID: UUID?
    @Published private(set) var selectedPageIDs: Set<UUID> = []
    @Published var options = ProcessingOptions()
    @Published private(set) var glossary = ProjectGlossary()
    @Published private(set) var batchJobs: [BatchJob] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isSwitchingProject = false
    @Published var statusMessage: String?

    private let models: ModelRuntimeHub?
    private let pipeline: ComicTranslationPipeline?
    private let applicationRoot: URL?
    private let projectsRoot: URL?
    private let legacyRepository: WorkspaceRepository?
    private let libraryRepository: ProjectLibraryRepository?
    private let scanner = ComicDirectoryScanner()
    private let stringTables = ComicStringTableRepository()
    private let pathResolver = WorkflowPathResolver()

    private var projectSnapshots: [UUID: WorkspaceSnapshot] = [:]
    private var activeModelDirectories: [URL] = []
    private var preferredModelPaths: [ModelCapability: String] = [:]
    private var activeProjectCreatedAt = Date()
    private var processingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var maskRegenerationTasks: [UUID: Task<Void, Never>] = [:]

    init(
        dataDirectoryPath: String? = nil,
        imageToTextModelPath: String? = nil,
        imageToImageModelPath: String? = nil
    ) {
        do {
            let metal = try MetalContext()
            let models = ModelRuntimeHub(metal: metal)
            let root = try Self.makeApplicationRoot(dataDirectoryPath: dataDirectoryPath)
            let artifactsRoot = root.appendingPathComponent("Artifacts", isDirectory: true)
            let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            let pipeline = ComicTranslationPipeline(
                recognizer: VisionOCRService(),
                translator: VLMRegionTranslationService(model: models),
                maskGenerator: DialogueMaskGenerator(),
                backgroundRestorer: try HybridBackgroundRestorer(models: models, metal: metal),
                typesetter: CoreTextDialogueTypesetter(),
                outputRoot: artifactsRoot
            )
            self.models = models
            self.pipeline = pipeline
            applicationRoot = root
            self.projectsRoot = projectsRoot
            legacyRepository = WorkspaceRepository(
                fileURL: root
                    .appendingPathComponent("Workspace", isDirectory: true)
                    .appendingPathComponent("workspace.json")
            )
            libraryRepository = ProjectLibraryRepository(
                fileURL: projectsRoot.appendingPathComponent("library.json")
            )
            statusMessage = "Metal 裝置已就緒，請建立或選取漫畫專案。"
        } catch {
            models = nil
            pipeline = nil
            applicationRoot = nil
            projectsRoot = nil
            legacyRepository = nil
            libraryRepository = nil
            statusMessage = error.localizedDescription
        }
        Task { [weak self] in
            guard let self else { return }
            await self.restoreProjectLibrary()
            await self.applyPreferredModelsNow(
                imageToTextPath: imageToTextModelPath,
                imageToImagePath: imageToImageModelPath
            )
        }
    }

    var activeProjectName: String? {
        guard let activeProjectID else { return nil }
        return projects.first(where: { $0.id == activeProjectID })?.name
    }

    var applicationDataDirectoryPath: String? { applicationRoot?.path }

    // MARK: - 專案管理與步驟一

    /// 每個來源目錄對應一個專案；重複選取既有目錄時改為切換並重掃。
    func openProject(from directoryURL: URL) {
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "批次工作或專案切換進行中，暫時無法開啟其他專案。"
            return
        }
        let sourceURL = directoryURL.standardizedFileURL
        if let existing = projects.first(where: {
            $0.sourceDirectoryURL.standardizedFileURL == sourceURL
        }) {
            if existing.id == activeProjectID {
                scanActiveSourceDirectory()
            } else {
                activateProject(existing.id, rescanAfterActivation: true)
            }
            return
        }

        isSwitchingProject = true
        statusMessage = "正在建立專案：\(sourceURL.lastPathComponent)…"
        Task { [weak self] in
            guard let self else { return }
            await self.persistActiveProjectNow()

            let projectID = UUID()
            let snapshot = WorkspaceSnapshot(
                projectID: projectID,
                name: sourceURL.lastPathComponent,
                options: ProcessingOptions(),
                glossary: ProjectGlossary(),
                pages: [],
                selectedPageID: nil,
                selectedPageIDs: [],
                modelDirectories: [],
                sourceDirectoryURL: sourceURL
            )
            self.projectSnapshots[projectID] = snapshot
            self.projects.append(Self.summary(from: snapshot))
            self.projects.sort { $0.updatedAt > $1.updatedAt }
            self.apply(snapshot)
            await self.saveProject(snapshot)
            await self.persistLibraryNow()
            self.isSwitchingProject = false
            self.scanActiveSourceDirectory()
        }
    }

    /// 舊呼叫名稱保留；不同目錄會建立新專案，不再覆蓋目前專案。
    func scanSourceDirectory(_ directoryURL: URL) {
        openProject(from: directoryURL)
    }

    func activateProject(_ projectID: UUID) {
        activateProject(projectID, rescanAfterActivation: false)
    }

    private func activateProject(_ projectID: UUID, rescanAfterActivation: Bool) {
        guard projectID != activeProjectID else {
            if rescanAfterActivation { scanActiveSourceDirectory() }
            return
        }
        guard projects.contains(where: { $0.id == projectID }) else {
            statusMessage = "找不到指定的專案。"
            return
        }
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "請等待目前批次工作完成或先取消工作。"
            return
        }

        isSwitchingProject = true
        statusMessage = "正在切換專案…"
        Task { [weak self] in
            guard let self else { return }
            await self.persistActiveProjectNow()
            do {
                let snapshot: WorkspaceSnapshot
                if let cached = self.projectSnapshots[projectID] {
                    snapshot = cached
                } else {
                    guard let loaded = try await self.projectRepository(for: projectID)?.load() else {
                        throw AppWorkflowError.projectNotFound
                    }
                    snapshot = loaded
                    self.projectSnapshots[projectID] = loaded
                }
                let restored = self.validated(snapshot)
                self.cache(restored)
                self.apply(restored)
                await self.loadProjectModels(restored.modelDirectories)
                await self.persistLibraryNow()
                self.statusMessage = "已切換至專案「\(restored.name)」。"
                self.isSwitchingProject = false
                if rescanAfterActivation {
                    self.scanActiveSourceDirectory()
                }
            } catch {
                self.isSwitchingProject = false
                self.statusMessage = "切換專案失敗：\(error.localizedDescription)"
            }
        }
    }

    func renameActiveProject(_ name: String) {
        guard let activeProjectID else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let index = projects.firstIndex(where: { $0.id == activeProjectID }) else { return }
        projects[index].name = value
        projects[index].updatedAt = Date()
        statusMessage = "專案已重新命名為「\(value)」。"
        schedulePersistence()
    }

    func rescanSourceDirectory() {
        scanActiveSourceDirectory()
    }

    private func scanActiveSourceDirectory() {
        guard !isProcessing, !isSwitchingProject else { return }
        guard sourceDirectoryURL != nil, activeProjectID != nil else {
            statusMessage = "請先建立或選取漫畫專案。"
            return
        }
        guard let sourceDirectoryURL else { return }

        isProcessing = true
        statusMessage = "正在遞迴掃描來源目錄…"
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.processingTask = nil
                self.startBatchQueueIfNeeded()
            }
            do {
                let scanner = self.scanner
                let scanned = try await Task.detached {
                    try scanner.scan(sourceDirectoryURL)
                }.value
                try Task.checkCancellation()
                await self.mergeScannedPages(scanned, sourceDirectoryURL: sourceDirectoryURL)
                self.statusMessage = scanned.isEmpty
                    ? "來源目錄內沒有支援的圖片。"
                    : "已掃描並整理 \(scanned.count) 頁漫畫。"
                self.schedulePersistence()
            } catch is CancellationError {
                self.statusMessage = "已取消掃描。"
            } catch {
                self.statusMessage = "掃描來源目錄失敗：\(error.localizedDescription)"
            }
        }
    }

    func importPages(from inputURLs: [URL]) {
        guard let first = inputURLs.first else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            openProject(from: first)
        } else {
            openProject(from: first.deletingLastPathComponent())
        }
    }

    func setOutputDirectory(_ directoryURL: URL) {
        guard activeProjectID != nil else {
            statusMessage = "請先建立或選取漫畫專案。"
            return
        }
        do {
            try validateOutputDirectory(directoryURL)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            outputDirectoryURL = directoryURL.standardizedFileURL
            statusMessage = "輸出目錄已設定；正在同步 .str 文件。"
            Task { [weak self] in
                guard let self else { return }
                do {
                    for page in self.pages where !page.regions.isEmpty {
                        try await self.persistStringTableNow(pageID: page.id)
                    }
                    self.statusMessage = "輸出目錄與 .str 文件已就緒。"
                    self.schedulePersistence()
                } catch {
                    self.statusMessage = "同步 .str 文件失敗：\(error.localizedDescription)"
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - 頁面選取

    func selectPage(_ id: UUID) {
        setPageSelection(pageIDs: [id], activePageID: id)
    }

    func setPageSelection(pageIDs: [UUID], activePageID requestedActivePageID: UUID?) {
        let validIDs = Set(pages.map(\.id))
        let selection = Set(pageIDs).intersection(validIDs)
        let active = requestedActivePageID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? selectedPageID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? selection.first
            ?? pages.first?.id
        selectedPageIDs = selection
        selectedPageID = active
        schedulePersistence()
    }

    func selectAllPages() {
        selectedPageIDs = Set(pages.map(\.id))
        selectedPageID = selectedPageID ?? pages.first?.id
        schedulePersistence()
    }

    func clearPageSelection() {
        selectedPageIDs = []
        schedulePersistence()
    }

    func clearPages() {
        guard !isProcessing else { return }
        cancelMaskRegeneration()
        pages = []
        selectedPageID = nil
        selectedPageIDs = []
        statusMessage = "專案頁面列表已清除；來源圖片與既有輸出檔未刪除。"
        schedulePersistence()
    }

    // MARK: - 四階段與批次工作佇列

    func detectMasksForAllPages() {
        enqueueBatch(operation: .detectMasks, pageIDs: pages.map(\.id))
    }

    func detectMasksForSelectedPage() {
        enqueueSelected(operation: .detectMasks)
    }

    func translateAllPages() {
        enqueueBatch(operation: .translate, pageIDs: pages.map(\.id))
    }

    func translateSelectedPage() {
        enqueueSelected(operation: .translate)
    }

    func composeAllPages() {
        enqueueBatch(operation: .compose, pageIDs: pages.map(\.id))
    }

    func composeSelectedPage() {
        enqueueSelected(operation: .compose)
    }

    func processAllPages() {
        enqueueBatch(operation: .fullPage, pageIDs: pages.map(\.id))
    }

    func processSelectedPage() {
        enqueueSelected(operation: .fullPage)
    }

    func enqueueBatch(operation: BatchOperation, pageIDs: [UUID]) {
        guard let activeProjectID, let activeProjectName else {
            statusMessage = "請先建立或選取漫畫專案。"
            return
        }
        let requested = Set(pageIDs)
        let orderedIDs = pages.lazy.map(\.id).filter(requested.contains)
        guard !orderedIDs.isEmpty else {
            statusMessage = "請先選取至少一張漫畫頁面。"
            return
        }
        guard pipeline != nil else {
            statusMessage = "漫畫處理 Runtime 尚未就緒。"
            return
        }
        if operation.requiresTextModel,
           !loadedModels.contains(where: { $0.capability == .imageToText }) {
            statusMessage = "翻譯前請先載入圖生文模型。"
            return
        }
        if operation.requiresOutputDirectory, outputDirectoryURL == nil {
            statusMessage = "合成前請先選取輸出目錄。"
            return
        }

        let job = BatchJob(
            projectID: activeProjectID,
            projectName: activeProjectName,
            operation: operation,
            pageIDs: Array(orderedIDs)
        )
        batchJobs.append(job)
        statusMessage = "已將 \(job.pageIDs.count) 頁加入批次工作佇列。"
        schedulePersistence()
        startBatchQueueIfNeeded()
    }

    func cancelProcessing() {
        for index in batchJobs.indices where batchJobs[index].status == .queued {
            batchJobs[index].status = .cancelled
            batchJobs[index].finishedAt = Date()
        }
        processingTask?.cancel()
        statusMessage = "正在取消目前與等待中的批次工作…"
        schedulePersistence()
    }

    func retryFailedBatchJob(_ jobID: UUID) {
        guard let job = batchJobs.first(where: { $0.id == jobID }),
              job.projectID == activeProjectID else {
            statusMessage = "只能在原專案內重試失敗頁面。"
            return
        }
        enqueueBatch(operation: job.operation, pageIDs: job.failures.map(\.pageID))
    }

    func clearFinishedBatchJobs() {
        batchJobs.removeAll { $0.status != .queued && $0.status != .running }
        schedulePersistence()
    }

    private func enqueueSelected(operation: BatchOperation) {
        let ids = selectedPageIDs.isEmpty
            ? selectedPageID.map { [$0] } ?? []
            : pages.lazy.map(\.id).filter(selectedPageIDs.contains)
        enqueueBatch(operation: operation, pageIDs: Array(ids))
    }

    private func startBatchQueueIfNeeded() {
        guard processingTask == nil,
              batchJobs.contains(where: { $0.status == .queued }) else { return }
        isProcessing = true
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.processingTask = nil
                self.schedulePersistence()
            }

            while let jobIndex = self.batchJobs.firstIndex(where: { $0.status == .queued }) {
                guard !Task.isCancelled else { break }
                guard self.batchJobs[jobIndex].projectID == self.activeProjectID else {
                    self.batchJobs[jobIndex].status = .cancelled
                    self.batchJobs[jobIndex].finishedAt = Date()
                    continue
                }

                self.batchJobs[jobIndex].status = .running
                self.batchJobs[jobIndex].startedAt = Date()
                let operation = self.batchJobs[jobIndex].operation
                let pageIDs = self.batchJobs[jobIndex].pageIDs

                for pageID in pageIDs {
                    guard !Task.isCancelled else { break }
                    self.batchJobs[jobIndex].currentPageID = pageID
                    do {
                        try await self.run(operation, pageID: pageID)
                        self.batchJobs[jobIndex].completedPageIDs.append(pageID)
                    } catch is CancellationError {
                        break
                    } catch {
                        self.batchJobs[jobIndex].failures.append(
                            BatchPageFailure(pageID: pageID, message: error.localizedDescription)
                        )
                        self.markFailed(pageID: pageID, message: error.localizedDescription)
                    }
                    self.schedulePersistence()
                }

                self.batchJobs[jobIndex].currentPageID = nil
                self.batchJobs[jobIndex].finishedAt = Date()
                if Task.isCancelled {
                    self.batchJobs[jobIndex].status = .cancelled
                    break
                }
                self.batchJobs[jobIndex].status = self.batchJobs[jobIndex].failures.isEmpty
                    ? .completed
                    : .completedWithErrors
            }

            if Task.isCancelled {
                for index in self.batchJobs.indices where self.batchJobs[index].status == .queued {
                    self.batchJobs[index].status = .cancelled
                    self.batchJobs[index].finishedAt = Date()
                }
                self.statusMessage = "批次工作已取消。"
            } else {
                self.statusMessage = "批次工作佇列已完成。"
            }
        }
    }

    // MARK: - 頁面與遮罩編輯

    @discardableResult
    func createRegion(pageID: UUID, bounds: NormalizedRect) -> UUID? {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            statusMessage = "找不到要新增遮罩的頁面。"
            return nil
        }
        let region = DialogueRegion(
            bounds: bounds.clamped(),
            sourceText: "",
            confidence: 1,
            style: options.defaultStyle
        )
        pages[pageIndex].regions.append(region)
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
        return region.id
    }

    func appendMaskStroke(
        pageID: UUID,
        regionID: UUID,
        mode: MaskStrokeMode,
        points: [NormalizedPoint],
        diameter: Double
    ) {
        guard !points.isEmpty,
              let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要修改的遮罩區域，或畫筆軌跡為空。"
            return
        }
        pages[pageIndex].regions[regionIndex].maskStrokes.append(MaskStroke(
            mode: mode,
            points: points,
            diameter: diameter
        ))
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    func undoMaskStroke(pageID: UUID, regionID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }),
              !pages[pageIndex].regions[regionIndex].maskStrokes.isEmpty else {
            statusMessage = "這個區域沒有可復原的遮罩筆劃。"
            return
        }
        pages[pageIndex].regions[regionIndex].maskStrokes.removeLast()
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    func removeRegion(pageID: UUID, regionID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要移除的對話區域。"
            return
        }
        pages[pageIndex].regions.remove(at: regionIndex)
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    func updateRegion(
        pageID: UUID,
        regionID: UUID,
        sourceText: String?,
        translatedText: String?,
        bounds: NormalizedRect?,
        fontName: String?,
        fontSize: Double?,
        useAutomaticFontSize: Bool?,
        writingDirection: WritingDirection?,
        automaticMaskEnabled: Bool?
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要更新的對話區域。"
            return
        }
        if let sourceText { pages[pageIndex].regions[regionIndex].sourceText = sourceText }
        if let translatedText { pages[pageIndex].regions[regionIndex].translatedText = translatedText }
        if let bounds { pages[pageIndex].regions[regionIndex].bounds = bounds.clamped() }
        if let fontName, !fontName.isEmpty {
            pages[pageIndex].regions[regionIndex].style.fontName = fontName
        }
        if useAutomaticFontSize == true {
            pages[pageIndex].regions[regionIndex].style.fontSize = nil
        } else if let fontSize, fontSize.isFinite {
            pages[pageIndex].regions[regionIndex].style.fontSize = min(max(fontSize, 4), 512)
        }
        if let writingDirection {
            pages[pageIndex].regions[regionIndex].style.writingDirection = writingDirection
        }
        if let automaticMaskEnabled {
            pages[pageIndex].regions[regionIndex].automaticMaskEnabled = automaticMaskEnabled
        }
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    // MARK: - 模型與設定

    func loadModel(from directoryURL: URL) {
        guard let models else {
            statusMessage = "Metal Runtime 尚未就緒。"
            return
        }
        Task {
            await loadModelNow(from: directoryURL, models: models, persist: true)
        }
    }

    func applyPreferredModels(imageToTextPath: String?, imageToImagePath: String?) {
        Task {
            await applyPreferredModelsNow(
                imageToTextPath: imageToTextPath,
                imageToImagePath: imageToImagePath
            )
        }
    }

    func setOptions(_ value: ProcessingOptions) {
        options = value
        schedulePersistence()
    }

    // MARK: - 專案專有名詞表

    @discardableResult
    func upsertGlossaryEntry(
        entryID: UUID?,
        sourceTerm: String,
        translations: [String: String],
        note: String?
    ) -> UUID? {
        guard activeProjectID != nil else {
            statusMessage = "請先建立或選取漫畫專案。"
            return nil
        }
        let source = sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            statusMessage = "專有名詞原詞不可為空。"
            return nil
        }
        if let entryID, !glossary.entries.contains(where: { $0.id == entryID }) {
            statusMessage = "找不到要更新的專有名詞詞條。"
            return nil
        }
        let entry = GlossaryEntry(
            id: entryID ?? UUID(),
            sourceTerm: source,
            translations: translations,
            note: note
        )
        let savedID = glossary.upsert(entry)
        statusMessage = "專有名詞「\(source)」已儲存。"
        schedulePersistence()
        return savedID
    }

    func removeGlossaryEntry(_ entryID: UUID) {
        guard let entry = glossary.entries.first(where: { $0.id == entryID }) else {
            statusMessage = "找不到要移除的專有名詞詞條。"
            return
        }
        glossary.remove(entryID: entryID)
        statusMessage = "已移除專有名詞「\(entry.sourceTerm)」。"
        schedulePersistence()
    }

    // MARK: - 工作流實作

    private func run(_ operation: BatchOperation, pageID: UUID) async throws {
        switch operation {
        case .detectMasks:
            try await runDetection(pageID: pageID)
        case .translate:
            try await runTranslation(pageID: pageID)
        case .compose:
            try await runComposition(pageID: pageID)
        case .fullPage:
            try await runDetection(pageID: pageID)
            try await runTranslation(pageID: pageID)
            try await runComposition(pageID: pageID)
        }
    }

    private func runDetection(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        let result = try await pipeline.detectMasks(
            page: page,
            options: options,
            progress: progressHandler(pageID: pageID)
        )
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].regions = result.regions
        pages[index].maskURL = result.maskURL
        pages[index].stage = .maskReady
        pages[index].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = "第 \(pages[index].index) 頁的文字遮罩已就緒。"
        schedulePersistence()
    }

    private func runTranslation(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard !page.regions.isEmpty else { throw AppWorkflowError.maskRequired }
        let regions = try await pipeline.translate(
            page: page,
            regions: page.regions,
            options: options,
            glossary: glossary,
            progress: progressHandler(pageID: pageID)
        )
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].regions = regions
        pages[index].stage = .translationReady
        pages[index].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = "第 \(pages[index].index) 頁翻譯完成，可逐區調整後合成。"
        schedulePersistence()
    }

    private func runComposition(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }),
              let outputDirectoryURL else {
            throw AppWorkflowError.outputDirectoryRequired
        }
        let paths = try pathResolver.paths(
            relativeSourcePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
            outputDirectoryURL: outputDirectoryURL
        )
        guard paths.outputURL.standardizedFileURL != page.sourceURL.standardizedFileURL else {
            throw AppWorkflowError.outputWouldOverwriteSource
        }
        let result = try await pipeline.compose(
            page: page,
            regions: page.regions,
            options: options,
            outputURL: paths.outputURL,
            progress: progressHandler(pageID: pageID)
        )
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].maskURL = result.maskURL
        pages[index].backgroundURL = result.backgroundURL
        pages[index].outputURL = result.outputURL
        pages[index].stage = .completed
        pages[index].progress = 1
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = result.warnings.isEmpty
            ? "第 \(pages[index].index) 頁已合成至輸出目錄。"
            : result.warnings.joined(separator: "\n")
        schedulePersistence()
    }

    private func progressHandler(pageID: UUID) -> PagePipelineProgress {
        { [weak self] stage, fraction in
            Task { @MainActor [weak self] in
                self?.updateProgress(pageID: pageID, stage: stage, fraction: fraction)
            }
        }
    }

    private func updateProgress(pageID: UUID, stage: PageProcessingStage, fraction: Double) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].stage = stage
        pages[index].progress = Self.totalProgress(stage: stage, fraction: fraction)
        pages[index].errorMessage = nil
    }

    private func markPageEdited(at pageIndex: Int) {
        let hasTranslation = pages[pageIndex].regions.contains { !$0.translatedText.isEmpty }
        pages[pageIndex].stage = hasTranslation ? .translationReady : .maskReady
        pages[pageIndex].progress = Self.totalProgress(stage: pages[pageIndex].stage, fraction: 1)
        pages[pageIndex].errorMessage = nil
    }

    private func scheduleMaskRegeneration(pageID: UUID) {
        maskRegenerationTasks[pageID]?.cancel()
        maskRegenerationTasks[pageID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled,
                  let pipeline = self.pipeline,
                  let page = self.pages.first(where: { $0.id == pageID }) else { return }
            do {
                let maskURL = try await pipeline.regenerateMask(
                    page: page,
                    regions: page.regions,
                    options: self.options
                )
                guard let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                self.pages[index].maskURL = maskURL
                try await self.persistStringTableNow(pageID: pageID)
                self.schedulePersistence()
            } catch is CancellationError {
                return
            } catch {
                self.statusMessage = "更新遮罩失敗：\(error.localizedDescription)"
            }
            self.maskRegenerationTasks[pageID] = nil
        }
    }

    private func cancelMaskRegeneration() {
        maskRegenerationTasks.values.forEach { $0.cancel() }
        maskRegenerationTasks = [:]
    }

    // MARK: - 掃描合併與 .str

    private func mergeScannedPages(
        _ scanned: [ScannedComicPage],
        sourceDirectoryURL: URL
    ) async {
        let known = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.sourceURL.standardizedFileURL.path, $0) }
        )
        var merged: [ComicPage] = []

        for (offset, item) in scanned.enumerated() {
            var page = known[item.sourceURL.path] ?? ComicPage(
                index: offset + 1,
                title: item.sourceURL.deletingPathExtension().lastPathComponent,
                sourceURL: item.sourceURL,
                relativeSourcePath: item.relativePath,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                stage: .scanned
            )
            page.index = offset + 1
            page.sourceURL = item.sourceURL
            page.relativeSourcePath = item.relativePath
            page.pixelWidth = item.pixelWidth
            page.pixelHeight = item.pixelHeight
            if page.stage == .pending { page.stage = .scanned }

            if let tableURL = try? stringTableURL(for: page),
               let table = try? await stringTables.load(from: tableURL) {
                page.regions = table.regions
                page.stringTableURL = tableURL
                page.stage = table.entries.contains(where: { !$0.translatedText.isEmpty })
                    ? .translationReady
                    : .maskReady
            }
            merged.append(page)
        }

        let validIDs = Set(merged.map(\.id))
        let oldSelection = selectedPageID
        pages = merged
        self.sourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
        selectedPageIDs.formIntersection(validIDs)
        selectedPageID = oldSelection.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? pages.first?.id
        if selectedPageIDs.isEmpty, let selectedPageID {
            selectedPageIDs = [selectedPageID]
        }
    }

    private func persistStringTableNow(pageID: UUID) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        let fileURL = try stringTableURL(for: pages[index])
        pages[index].stringTableURL = fileURL
        let table = ComicStringTable(page: pages[index], targetLanguageCode: options.targetLanguageCode)
        try await stringTables.save(table, to: fileURL)
    }

    private func stringTableURL(for page: ComicPage) throws -> URL {
        guard let activeProjectID, let projectsRoot else {
            throw AppWorkflowError.runtimeUnavailable
        }
        let root = outputDirectoryURL
            ?? projectsRoot
                .appendingPathComponent(activeProjectID.uuidString, isDirectory: true)
                .appendingPathComponent("StringTables", isDirectory: true)
        return try pathResolver.paths(
            relativeSourcePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
            outputDirectoryURL: root
        ).stringTableURL
    }

    private func validateOutputDirectory(_ candidate: URL) throws {
        guard let sourceDirectoryURL else { return }
        let sourcePath = sourceDirectoryURL.standardizedFileURL.path
        let outputPath = candidate.standardizedFileURL.path
        if outputPath == sourcePath || outputPath.hasPrefix(sourcePath + "/") {
            throw AppWorkflowError.outputInsideSource
        }
    }

    // MARK: - 專案復原與持久化

    private func restoreProjectLibrary() async {
        guard let libraryRepository else { return }
        do {
            if let library = try await libraryRepository.load(), !library.projects.isEmpty {
                projects = library.projects
                batchJobs = library.jobs.map { job in
                    guard job.status == .queued || job.status == .running else { return job }
                    var value = job
                    value.status = .cancelled
                    value.currentPageID = nil
                    value.finishedAt = Date()
                    return value
                }
                let projectID = library.activeProjectID.flatMap { id in
                    projects.contains(where: { $0.id == id }) ? id : nil
                } ?? projects.first?.id
                if let projectID,
                   let snapshot = try await projectRepository(for: projectID)?.load() {
                    let restored = validated(snapshot)
                    projectSnapshots[projectID] = restored
                    cache(restored)
                    apply(restored)
                    await loadProjectModels(restored.modelDirectories)
                    statusMessage = "已復原專案「\(restored.name)」。"
                }
                await persistLibraryNow()
                return
            }
            try await migrateLegacyWorkspaceIfNeeded()
        } catch {
            statusMessage = "無法復原專案資料庫：\(error.localizedDescription)"
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() async throws {
        guard let legacyRepository,
              var snapshot = try await legacyRepository.load(),
              snapshot.sourceDirectoryURL != nil else { return }
        snapshot.schemaVersion = 3
        snapshot.name = snapshot.sourceDirectoryURL?.lastPathComponent ?? snapshot.name
        snapshot.selectedPageIDs = snapshot.selectedPageIDs.isEmpty
            ? Set(snapshot.selectedPageID.map { [$0] } ?? [])
            : snapshot.selectedPageIDs
        let restored = validated(snapshot)
        projectSnapshots[restored.projectID] = restored
        projects = [Self.summary(from: restored)]
        apply(restored)
        await saveProject(restored)
        await persistLibraryNow()
        await loadProjectModels(restored.modelDirectories)
        statusMessage = "已將舊工作區遷移為專案「\(restored.name)」。"
    }

    private func validated(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot {
        var value = snapshot
        let fileManager = FileManager.default
        let existingPages: [ComicPage] = value.pages.compactMap { original -> ComicPage? in
            guard fileManager.fileExists(atPath: original.sourceURL.path) else { return nil }
            var page = original
            if let outputURL = page.outputURL,
               !fileManager.fileExists(atPath: outputURL.path) {
                page.outputURL = nil
                if page.stage == .completed {
                    page.stage = page.regions.contains(where: { !$0.translatedText.isEmpty })
                        ? .translationReady
                        : .maskReady
                }
            }
            let stableStages: Set<PageProcessingStage> = [
                .pending, .scanned, .maskReady, .translationReady, .completed, .failed
            ]
            if !stableStages.contains(page.stage) {
                page.stage = page.regions.isEmpty ? .scanned : .maskReady
                page.errorMessage = "上次處理未完成，請重新執行該步驟。"
            }
            page.progress = Self.totalProgress(stage: page.stage, fraction: 1)
            return page
        }
        value.pages = existingPages.enumerated().map { offset, page in
            var value = page
            value.index = offset + 1
            return value
        }
        let validIDs = Set(value.pages.map(\.id))
        value.selectedPageIDs.formIntersection(validIDs)
        value.selectedPageID = value.selectedPageID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? value.pages.first?.id
        return value
    }

    private func apply(_ snapshot: WorkspaceSnapshot) {
        cancelMaskRegeneration()
        activeProjectID = snapshot.projectID
        activeProjectCreatedAt = snapshot.createdAt
        pages = snapshot.pages
        options = snapshot.options
        glossary = snapshot.glossary
        sourceDirectoryURL = snapshot.sourceDirectoryURL
        outputDirectoryURL = snapshot.outputDirectoryURL
        selectedPageID = snapshot.selectedPageID
        selectedPageIDs = snapshot.selectedPageIDs
        activeModelDirectories = snapshot.modelDirectories
    }

    private func makeActiveSnapshot() -> WorkspaceSnapshot? {
        guard let activeProjectID,
              let sourceDirectoryURL,
              let name = projects.first(where: { $0.id == activeProjectID })?.name else { return nil }
        return WorkspaceSnapshot(
            projectID: activeProjectID,
            name: name,
            createdAt: activeProjectCreatedAt,
            options: options,
            glossary: glossary,
            pages: pages,
            selectedPageID: selectedPageID,
            selectedPageIDs: selectedPageIDs,
            modelDirectories: activeModelDirectories,
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: outputDirectoryURL
        )
    }

    private func cache(_ snapshot: WorkspaceSnapshot) {
        projectSnapshots[snapshot.projectID] = snapshot
        let summary = Self.summary(from: snapshot)
        if let index = projects.firstIndex(where: { $0.id == snapshot.projectID }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func schedulePersistence() {
        guard let snapshot = makeActiveSnapshot() else { return }
        cache(snapshot)
        let library = makeLibrarySnapshot()
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.projectRepository(for: snapshot.projectID)?.save(snapshot)
                try await self.libraryRepository?.save(library)
            } catch {
                self.statusMessage = "專案自動儲存失敗：\(error.localizedDescription)"
            }
        }
    }

    private func persistActiveProjectNow() async {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard let snapshot = makeActiveSnapshot() else { return }
        cache(snapshot)
        await saveProject(snapshot)
        await persistLibraryNow()
    }

    private func saveProject(_ snapshot: WorkspaceSnapshot) async {
        do {
            try await projectRepository(for: snapshot.projectID)?.save(snapshot)
        } catch {
            statusMessage = "專案儲存失敗：\(error.localizedDescription)"
        }
    }

    private func persistLibraryNow() async {
        do {
            try await libraryRepository?.save(makeLibrarySnapshot())
        } catch {
            statusMessage = "專案索引儲存失敗：\(error.localizedDescription)"
        }
    }

    private func makeLibrarySnapshot() -> ProjectLibrarySnapshot {
        ProjectLibrarySnapshot(
            activeProjectID: activeProjectID,
            projects: projects,
            jobs: Array(batchJobs.suffix(50))
        )
    }

    private func projectRepository(for projectID: UUID) -> WorkspaceRepository? {
        guard let projectsRoot else { return nil }
        let fileURL = projectsRoot
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("project.json")
        return WorkspaceRepository(fileURL: fileURL)
    }

    private func loadProjectModels(_ directories: [URL]) async {
        guard let models else { return }
        let fileManager = FileManager.default
        for directoryURL in directories where fileManager.fileExists(atPath: directoryURL.path) {
            if let manifest = try? ModelManifest.load(from: directoryURL),
               preferredModelPaths[manifest.capability] != nil {
                continue
            }
            await loadModelNow(from: directoryURL, models: models, persist: false)
        }
    }

    private func applyPreferredModelsNow(
        imageToTextPath: String?,
        imageToImagePath: String?
    ) async {
        guard let models else { return }
        await replacePreferredModel(
            capability: .imageToText,
            path: imageToTextPath,
            models: models
        )
        await replacePreferredModel(
            capability: .imageToImage,
            path: imageToImagePath,
            models: models
        )
        loadedModels = await models.loadedModels()
    }

    private func replacePreferredModel(
        capability: ModelCapability,
        path: String?,
        models: ModelRuntimeHub
    ) async {
        guard preferredModelPaths[capability] != path else { return }
        await models.unloadModel(capability: capability)
        guard let path else {
            preferredModelPaths.removeValue(forKey: capability)
            return
        }
        preferredModelPaths[capability] = path
        let directoryURL = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let manifest = try ModelManifest.load(from: directoryURL)
            guard manifest.capability == capability else {
                throw PreferredModelError.capabilityMismatch(expected: capability)
            }
            _ = try await models.loadModel(at: directoryURL)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadModelNow(
        from directoryURL: URL,
        models: ModelRuntimeHub,
        persist: Bool
    ) async {
        statusMessage = "正在載入模型：\(directoryURL.lastPathComponent)…"
        do {
            let info = try await models.loadModel(at: directoryURL)
            loadedModels = await models.loadedModels()
            if persist {
                let location = directoryURL.standardizedFileURL
                if !activeModelDirectories.contains(location) {
                    activeModelDirectories.append(location)
                }
                schedulePersistence()
            }
            statusMessage = "已載入 \(info.displayName)（\(info.backend.rawValue)／\(info.capability.rawValue)）。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func markFailed(pageID: UUID, message: String) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].stage = .failed
        pages[index].errorMessage = message
        statusMessage = "第 \(pages[index].index) 頁失敗：\(message)"
        schedulePersistence()
    }

    private static func summary(from snapshot: WorkspaceSnapshot) -> ComicProjectSummary {
        ComicProjectSummary(
            id: snapshot.projectID,
            name: snapshot.name,
            sourceDirectoryURL: snapshot.sourceDirectoryURL ?? URL(fileURLWithPath: "/"),
            outputDirectoryURL: snapshot.outputDirectoryURL,
            pageCount: snapshot.pages.count,
            completedPageCount: snapshot.pages.count(where: { $0.stage == .completed }),
            updatedAt: snapshot.savedAt
        )
    }

    private static func totalProgress(stage: PageProcessingStage, fraction: Double) -> Double {
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

    private static func makeApplicationRoot(dataDirectoryPath: String?) throws -> URL {
        try ApplicationDirectories.applicationSupportRoot(customPath: dataDirectoryPath)
    }
}

private enum PreferredModelError: LocalizedError {
    case capabilityMismatch(expected: ModelCapability)

    var errorDescription: String? {
        switch self {
        case let .capabilityMismatch(expected):
            "所選模型類型不符，預期為 \(expected.rawValue)。"
        }
    }
}

private extension BatchOperation {
    var requiresTextModel: Bool {
        self == .translate || self == .fullPage
    }

    var requiresOutputDirectory: Bool {
        self == .compose || self == .fullPage
    }
}

private enum AppWorkflowError: LocalizedError {
    case projectNotFound
    case pageNotFound
    case maskRequired
    case outputDirectoryRequired
    case outputInsideSource
    case outputWouldOverwriteSource
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .projectNotFound: "找不到指定的專案資料。"
        case .pageNotFound: "找不到指定的漫畫頁面。"
        case .maskRequired: "請先執行文字與遮罩偵測，再進行翻譯。"
        case .outputDirectoryRequired: "合成前請先選取輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內，以免重新掃描到輸出檔。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片，已中止合成。"
        case .runtimeUnavailable: "漫畫處理 Runtime 尚未就緒。"
        }
    }
}
