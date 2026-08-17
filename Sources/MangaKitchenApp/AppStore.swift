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
    @Published private(set) var modelDownloadState: ModelDownloadState?
    @Published private(set) var processingActivities: [UUID: PageProcessingActivity] = [:]
    @Published var statusMessage: String?

    private let models: ModelRuntimeHub?
    private let pipeline: ComicTranslationPipeline?
    private let backgroundRestorer: HybridBackgroundRestorer?
    private let applicationRoot: URL?
    private let projectsRoot: URL?
    private let legacyRepository: WorkspaceRepository?
    private let libraryRepository: ProjectLibraryRepository?
    private let scanner = ComicDirectoryScanner()
    private let stringTables = ComicStringTableRepository()
    private let pathResolver = WorkflowPathResolver()
    private let modelDownloader = HuggingFaceModelDownloader()

    private var projectSnapshots: [UUID: WorkspaceSnapshot] = [:]
    private var activeModelDirectories: [URL] = []
    private var preferredModelPaths: [ModelCapability: String] = [:]
    private var activeProjectCreatedAt = Date()
    private var processingTask: Task<Void, Never>?
    private var modelDownloadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var maskRegenerationTasks: [UUID: Task<Void, Never>] = [:]
    private var translationPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var undoneMaskStrokes: [UUID: [UUID: [MaskStroke]]] = [:]

    init(
        dataDirectoryPath: String? = nil,
        imageCompositingBackend: ImageCompositingBackend = .cpu,
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
            let backgroundRestorer = try HybridBackgroundRestorer(
                models: models,
                metal: metal,
                compositingBackend: imageCompositingBackend
            )
            let pipeline = ComicTranslationPipeline(
                recognizer: VisionOCRService(),
                regionDetector: VLMSupplementalRegionDetector(model: models),
                ocrTextRefiner: VLMOCRTextRefinementService(model: models),
                maskRefiner: MangaTextMaskRefiner(),
                translator: VLMRegionTranslationService(model: models),
                maskGenerator: DialogueMaskGenerator(),
                backgroundRestorer: backgroundRestorer,
                typesetter: CoreTextDialogueTypesetter(),
                outputRoot: artifactsRoot
            )
            self.models = models
            self.pipeline = pipeline
            self.backgroundRestorer = backgroundRestorer
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
            backgroundRestorer = nil
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

    func setImageCompositingBackend(_ backend: ImageCompositingBackend) {
        guard let backgroundRestorer else { return }
        Task { [weak self] in
            await backgroundRestorer.setCompositingBackend(backend)
            self?.statusMessage = backend == .gpu
                ? "圖像合成已切換為 GPU。"
                : "圖像合成已切換為 CPU。"
        }
    }

    // MARK: - 專案管理與步驟一

    /// 每個來源目錄對應一個專案；重複選取既有目錄時改為切換並重掃。
    func openProject(from directoryURL: URL) {
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "工作或專案切換進行中，暫時無法開啟其他專案。"
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
            statusMessage = "請等待目前工作完成或先取消工作。"
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
                await self.migrateStringTablesToSource()
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

    /// 只移除 MangaKitchen 內的專案索引，不刪除來源、輸出或 `.str` 檔案。
    func deleteProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            statusMessage = "找不到要刪除的專案。"
            return
        }
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "請等待目前工作完成或先取消工作。"
            return
        }

        isSwitchingProject = true
        statusMessage = "正在刪除專案紀錄「\(project.name)」…"
        Task { [weak self] in
            guard let self else { return }
            await self.persistActiveProjectNow()
            self.projectSnapshots[projectID] = nil
            self.projects.removeAll { $0.id == projectID }
            self.batchJobs.removeAll { $0.projectID == projectID }

            var activationError: Error?
            if self.activeProjectID == projectID {
                self.clearActiveProject()
                if let replacementID = self.projects.first?.id {
                    do {
                        let snapshot: WorkspaceSnapshot
                        if let cached = self.projectSnapshots[replacementID] {
                            snapshot = cached
                        } else {
                            guard let loaded = try await self.projectRepository(for: replacementID)?.load() else {
                                throw AppWorkflowError.projectNotFound
                            }
                            snapshot = loaded
                        }
                        let restored = self.validated(snapshot)
                        self.cache(restored)
                        self.apply(restored)
                        await self.migrateStringTablesToSource()
                        await self.loadProjectModels(restored.modelDirectories)
                    } catch {
                        activationError = error
                    }
                }
            }

            await self.persistLibraryNow()
            self.isSwitchingProject = false
            if let activationError {
                self.statusMessage = "已刪除專案紀錄「\(project.name)」，但無法載入其他專案：\(activationError.localizedDescription)"
            } else {
                self.statusMessage = "已刪除專案紀錄「\(project.name)」；來源、輸出與 .str 檔案均未刪除。"
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
                let scanTask = Task.detached {
                    try scanner.scan(sourceDirectoryURL)
                }
                let scanned = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
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
            statusMessage = "輸出目錄已設定；.str 會保存在各原圖旁。"
            schedulePersistence()
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
        cancelTranslationPreviewRegeneration()
        undoneMaskStrokes = [:]
        pages = []
        selectedPageID = nil
        selectedPageIDs = []
        statusMessage = "專案頁面列表已清除；來源圖片與既有輸出檔未刪除。"
        schedulePersistence()
    }

    func resetPages(_ pageIDs: [UUID]) {
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "請等待目前工作完成或先取消工作。"
            return
        }
        let requestedPageIDs = Set(pageIDs)
        let pageIndexes = pages.indices.filter { requestedPageIDs.contains(pages[$0].id) }
        guard !pageIndexes.isEmpty else {
            statusMessage = "請先選取至少一張漫畫頁面。"
            return
        }

        var resetCount = 0
        var failures: [String] = []
        for pageIndex in pageIndexes {
            let page = pages[pageIndex]
            maskRegenerationTasks[page.id]?.cancel()
            maskRegenerationTasks[page.id] = nil
            translationPreviewTasks[page.id]?.cancel()
            translationPreviewTasks[page.id] = nil
            undoneMaskStrokes[page.id] = nil

            do {
                try removeGeneratedFiles(for: page)
                pages[pageIndex].regions = []
                pages[pageIndex].backgroundURL = nil
                pages[pageIndex].maskURL = nil
                pages[pageIndex].stringTableURL = nil
                pages[pageIndex].translationPreviewURL = nil
                pages[pageIndex].outputURL = nil
                pages[pageIndex].stage = .scanned
                pages[pageIndex].progress = Self.totalProgress(stage: .scanned, fraction: 1)
                pages[pageIndex].errorMessage = nil
                resetCount += 1
            } catch {
                failures.append("\(page.title)：\(error.localizedDescription)")
            }
        }

        if resetCount > 0 {
            schedulePersistence()
        }
        if failures.isEmpty {
            statusMessage = "已清除 \(resetCount) 頁的既有計算資料，可從步驟一重新開始。"
        } else {
            statusMessage = "已重設 \(resetCount) 頁；部分頁面無法清除：\n" + failures.joined(separator: "\n")
        }
    }

    private func removeGeneratedFiles(for page: ComicPage) throws {
        let fileManager = FileManager.default
        let sourceURL = page.sourceURL.standardizedFileURL
        var protectedSourceURLs = Set(pages.map { $0.sourceURL.standardizedFileURL })
        if let sourceDirectoryURL {
            protectedSourceURLs.insert(sourceDirectoryURL.standardizedFileURL)
        }
        let sidecarURL = pathResolver.stringTableURL(for: sourceURL)
        var generatedURLs = Set([
            sidecarURL,
            sidecarURL.appendingPathExtension("bak"),
        ])
        [
            page.backgroundURL,
            page.maskURL,
            page.stringTableURL,
            page.stringTableURL?.appendingPathExtension("bak"),
            page.translationPreviewURL,
            page.outputURL,
        ].compactMap { $0 }.forEach { generatedURLs.insert($0.standardizedFileURL) }

        if let outputDirectoryURL,
           let outputURL = try? pathResolver.outputURL(
               relativeSourcePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
               outputDirectoryURL: outputDirectoryURL
           ) {
            generatedURLs.insert(outputURL.standardizedFileURL)
        }
        let artifactDirectoryURL = applicationRoot?
            .appendingPathComponent("Artifacts", isDirectory: true)
            .appendingPathComponent(page.id.uuidString, isDirectory: true)
            .standardizedFileURL
        if let artifactDirectoryURL { generatedURLs.insert(artifactDirectoryURL) }

        for url in generatedURLs where !protectedSourceURLs.contains(url) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue || url == artifactDirectoryURL else { continue }
            try fileManager.removeItem(at: url)
        }
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

    @discardableResult
    func enqueueBatch(operation: BatchOperation, pageIDs: [UUID]) -> UUID? {
        guard let activeProjectID, let activeProjectName else {
            statusMessage = "請先建立或選取漫畫專案。"
            return nil
        }
        let requested = Set(pageIDs)
        let orderedIDs = pages.lazy.map(\.id).filter(requested.contains)
        guard !orderedIDs.isEmpty else {
            statusMessage = "請先選取至少一張漫畫頁面。"
            return nil
        }
        guard pipeline != nil else {
            statusMessage = "漫畫處理 Runtime 尚未就緒。"
            return nil
        }
        if operation.requiresTextModel,
           !loadedModels.contains(where: { $0.capability == .imageToText }) {
            statusMessage = "OCR 校正或翻譯前請先載入圖生文模型。"
            return nil
        }
        if operation.requiresOutputDirectory, outputDirectoryURL == nil {
            statusMessage = "合成前請先選取輸出目錄。"
            return nil
        }

        let job = BatchJob(
            projectID: activeProjectID,
            projectName: activeProjectName,
            operation: operation,
            pageIDs: Array(orderedIDs)
        )
        batchJobs.append(job)
        statusMessage = "已將 \(job.pageIDs.count) 頁加入工作佇列。"
        schedulePersistence()
        startBatchQueueIfNeeded()
        return job.id
    }

    func cancelProcessing() {
        let cancelledPageIDs = batchJobs.compactMap { job in
            job.status == .running ? job.currentPageID : nil
        }
        let now = Date()
        for index in batchJobs.indices where [.queued, .running].contains(batchJobs[index].status) {
            batchJobs[index].status = .cancelled
            batchJobs[index].currentPageID = nil
            batchJobs[index].finishedAt = now
        }
        processingTask?.cancel()
        cancelledPageIDs.forEach { processingActivities[$0] = nil }
        cancelledPageIDs.forEach(restoreStablePageStateAfterCancellation)
        statusMessage = processingTask == nil
            ? "目前沒有執行中的工作。"
            : "工作已取消，正在停止目前運算…"
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

            while let jobID = self.batchJobs.first(where: { $0.status == .queued })?.id {
                guard !Task.isCancelled else { break }
                guard let jobIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }) else {
                    continue
                }
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
                    guard !Task.isCancelled,
                          let currentIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                          self.batchJobs[currentIndex].status == .running else { break }
                    self.batchJobs[currentIndex].currentPageID = pageID
                    self.processingActivities[pageID] = .preparingPage
                    do {
                        try await self.run(operation, pageID: pageID)
                        try Task.checkCancellation()
                        guard let resultIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                              self.batchJobs[resultIndex].status == .running else {
                            self.processingActivities[pageID] = nil
                            break
                        }
                        self.batchJobs[resultIndex].completedPageIDs.append(pageID)
                    } catch is CancellationError {
                        self.processingActivities[pageID] = nil
                        break
                    } catch {
                        guard let resultIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                              self.batchJobs[resultIndex].status == .running else {
                            self.processingActivities[pageID] = nil
                            break
                        }
                        self.batchJobs[resultIndex].failures.append(
                            BatchPageFailure(pageID: pageID, message: error.localizedDescription)
                        )
                        self.markFailed(pageID: pageID, message: error.localizedDescription)
                    }
                    self.processingActivities[pageID] = nil
                    self.schedulePersistence()
                }

                guard let finalIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }) else {
                    if Task.isCancelled { break }
                    continue
                }
                guard self.batchJobs[finalIndex].status == .running else {
                    if Task.isCancelled { break }
                    continue
                }
                self.batchJobs[finalIndex].currentPageID = nil
                self.batchJobs[finalIndex].finishedAt = Date()
                if Task.isCancelled {
                    self.batchJobs[finalIndex].status = .cancelled
                    break
                }
                self.batchJobs[finalIndex].status = self.batchJobs[finalIndex].failures.isEmpty
                    ? .completed
                    : .completedWithErrors
            }

            if Task.isCancelled {
                for index in self.batchJobs.indices where self.batchJobs[index].status == .queued {
                    self.batchJobs[index].status = .cancelled
                    self.batchJobs[index].finishedAt = Date()
                }
                self.statusMessage = "工作已取消。"
            } else {
                self.statusMessage = "工作佇列已完成。"
            }
        }
    }

    // MARK: - 頁面與遮罩編輯

    @discardableResult
    func createRegion(
        pageID: UUID,
        bounds: NormalizedRect,
        sourceText: String = "",
        translatedText: String = "",
        automaticMaskEnabled: Bool = true
    ) -> UUID? {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            statusMessage = "找不到要新增遮罩的頁面。"
            return nil
        }
        let region = DialogueRegion(
            bounds: bounds.clamped(),
            sourceText: sourceText,
            ocrTextRefined: !sourceText.isEmpty,
            translatedText: translatedText,
            confidence: 1,
            style: options.defaultStyle,
            automaticMaskEnabled: automaticMaskEnabled
        )
        pages[pageIndex].regions.append(region)
        markPageEdited(at: pageIndex)
        if automaticMaskEnabled {
            scheduleMaskRegeneration(pageID: pageID)
        } else {
            persistEditedRegion(pageID: pageID)
        }
        return region.id
    }

    @discardableResult
    func duplicateRegion(pageID: UUID, regionID: UUID) -> UUID? {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要複製的文字區域。"
            return nil
        }
        let source = pages[pageIndex].regions[regionIndex]
        let offset = 0.025
        func shifted(_ rect: NormalizedRect) -> NormalizedRect {
            NormalizedRect(
                x: min(max(rect.x + offset, 0), max(0, 1 - rect.width)),
                y: min(max(rect.y + offset, 0), max(0, 1 - rect.height)),
                width: rect.width,
                height: rect.height
            ).clamped()
        }
        let sourceAnchor = source.translationAnchor ?? NormalizedPoint(
            x: source.bounds.x + source.bounds.width / 2,
            y: source.bounds.y + source.bounds.height / 2
        )
        let duplicate = DialogueRegion(
            bounds: shifted(source.bounds),
            bubbleBounds: source.bubbleBounds.map(shifted),
            rawSourceText: source.rawSourceText,
            sourceText: source.sourceText,
            ocrTextRefined: source.ocrTextRefined,
            translatedText: source.translatedText,
            translationAnchor: NormalizedPoint(
                x: min(max(sourceAnchor.x + offset, 0), 1),
                y: min(max(sourceAnchor.y + offset, 0), 1)
            ),
            translationBounds: source.translationBounds.map(shifted),
            confidence: source.confidence,
            style: source.style,
            automaticMaskEnabled: false
        )
        pages[pageIndex].regions.insert(duplicate, at: regionIndex + 1)
        markPageEdited(at: pageIndex)
        persistEditedRegion(pageID: pageID)
        return duplicate.id
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
        clearMaskRedoHistory(pageID: pageID, regionID: regionID)
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
        let stroke = pages[pageIndex].regions[regionIndex].maskStrokes.removeLast()
        undoneMaskStrokes[pageID, default: [:]][regionID, default: []].append(stroke)
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    func redoMaskStroke(pageID: UUID, regionID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }),
              var pageHistory = undoneMaskStrokes[pageID],
              var regionHistory = pageHistory[regionID],
              let stroke = regionHistory.popLast() else {
            statusMessage = "這個區域沒有可重做的遮罩筆劃。"
            return
        }
        if regionHistory.isEmpty {
            pageHistory[regionID] = nil
        } else {
            pageHistory[regionID] = regionHistory
        }
        if pageHistory.isEmpty {
            undoneMaskStrokes[pageID] = nil
        } else {
            undoneMaskStrokes[pageID] = pageHistory
        }
        pages[pageIndex].regions[regionIndex].maskStrokes.append(stroke)
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
    }

    func maskRedoRegionIDs(pageID: UUID) -> [UUID] {
        undoneMaskStrokes[pageID]?.compactMap { regionID, strokes in
            strokes.isEmpty ? nil : regionID
        } ?? []
    }

    private func clearMaskRedoHistory(pageID: UUID, regionID: UUID) {
        guard var pageHistory = undoneMaskStrokes[pageID] else { return }
        pageHistory[regionID] = nil
        undoneMaskStrokes[pageID] = pageHistory.isEmpty ? nil : pageHistory
    }

    func removeRegion(pageID: UUID, regionID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要移除的對話區域。"
            return
        }
        let hadRenderedMask = pages[pageIndex].maskURL != nil
            || pages[pageIndex].backgroundURL != nil
        let removedRegion = pages[pageIndex].regions.remove(at: regionIndex)
        clearMaskRedoHistory(pageID: pageID, regionID: regionID)
        markPageEdited(at: pageIndex)
        let affectsMask = removedRegion.automaticMaskEnabled
            || !removedRegion.maskPolygons.isEmpty
            || !removedRegion.maskStrokes.isEmpty
        if affectsMask || hadRenderedMask {
            scheduleMaskRegeneration(pageID: pageID)
        } else {
            persistEditedRegion(pageID: pageID)
        }
    }

    func updateRegion(
        pageID: UUID,
        regionID: UUID,
        sourceText: String?,
        translatedText: String?,
        translationAnchor: NormalizedPoint?,
        translationBounds: NormalizedRect?,
        bounds: NormalizedRect?,
        bubbleBounds: NormalizedRect?,
        maskPolygons: [[NormalizedPoint]]?,
        fontName: String?,
        fontSize: Double?,
        fontWeight: DialogueFontWeight?,
        useAutomaticFontSize: Bool?,
        writingDirection: WritingDirection?,
        automaticMaskEnabled: Bool?
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要更新的對話區域。"
            return
        }
        let shouldRefineMask = maskPolygons == nil && (bounds != nil || bubbleBounds != nil)
        if let sourceText {
            let previous = pages[pageIndex].regions[regionIndex].sourceText
            pages[pageIndex].regions[regionIndex].rawSourceText =
                pages[pageIndex].regions[regionIndex].rawSourceText ?? previous
            pages[pageIndex].regions[regionIndex].sourceText = sourceText
            pages[pageIndex].regions[regionIndex].ocrTextRefined = true
            if sourceText != previous, translatedText == nil {
                pages[pageIndex].regions[regionIndex].translatedText = ""
            }
        }
        if let translatedText { pages[pageIndex].regions[regionIndex].translatedText = translatedText }
        if let translationAnchor {
            pages[pageIndex].regions[regionIndex].translationAnchor = translationAnchor.clamped()
        }
        if let translationBounds {
            pages[pageIndex].regions[regionIndex].translationBounds = translationBounds.clamped()
        }
        if let bounds { pages[pageIndex].regions[regionIndex].bounds = bounds.clamped() }
        if let bubbleBounds { pages[pageIndex].regions[regionIndex].bubbleBounds = bubbleBounds.clamped() }
        if let maskPolygons {
            let sanitizedPolygons = maskPolygons
                .map { $0.map { $0.clamped() } }
                .filter { $0.count >= 3 }
            pages[pageIndex].regions[regionIndex].maskPolygons = sanitizedPolygons
            pages[pageIndex].regions[regionIndex].maskRefinementApplied = !sanitizedPolygons.isEmpty
            pages[pageIndex].regions[regionIndex].maskCoverageRatio = nil
            pages[pageIndex].regions[regionIndex].maskCoverageComplete = !sanitizedPolygons.isEmpty
        } else if shouldRefineMask {
            // bounds 是粗搜尋區，bubbleBounds 是不可越界的對話框內緣；
            // 任一幾何範圍改變後，舊的像素遮罩已失效，必須重新精修。
            pages[pageIndex].regions[regionIndex].maskPolygons = []
            pages[pageIndex].regions[regionIndex].maskRefinementApplied = false
            pages[pageIndex].regions[regionIndex].maskCoverageRatio = nil
            pages[pageIndex].regions[regionIndex].maskCoverageComplete = false
        }
        if let fontName, !fontName.isEmpty {
            pages[pageIndex].regions[regionIndex].style.fontName = fontName
        }
        if useAutomaticFontSize == true {
            pages[pageIndex].regions[regionIndex].style.fontSize = nil
        } else if let fontSize, fontSize.isFinite {
            pages[pageIndex].regions[regionIndex].style.fontSize = min(max(fontSize, 4), 512)
        }
        if let fontWeight {
            pages[pageIndex].regions[regionIndex].style.fontWeight = fontWeight
        }
        if let writingDirection {
            pages[pageIndex].regions[regionIndex].style.writingDirection = writingDirection
        }
        if let automaticMaskEnabled {
            pages[pageIndex].regions[regionIndex].automaticMaskEnabled = automaticMaskEnabled
        }
        markPageEdited(at: pageIndex)
        let shouldRegenerateMask = bounds != nil
            || bubbleBounds != nil
            || maskPolygons != nil
            || automaticMaskEnabled != nil
        if shouldRegenerateMask {
            scheduleMaskRegeneration(
                pageID: pageID,
                refineRegionID: shouldRefineMask ? regionID : nil
            )
        } else {
            persistEditedRegion(pageID: pageID)
        }
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

    func downloadModel(
        _ model: DownloadableModelDescriptor,
        to storageDirectoryURL: URL,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        guard modelDownloadTask == nil else { return }
        modelDownloadState = ModelDownloadState(
            capability: model.capability,
            variantID: model.id,
            progress: 0
        )
        statusMessage = "正在下載模型：\(model.displayName)…"
        let downloader = modelDownloader
        modelDownloadTask = Task { [weak self] in
            do {
                let directoryURL = try await downloader.download(
                    model: model,
                    storageDirectoryURL: storageDirectoryURL
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.modelDownloadState?.variantID == model.id else { return }
                        self?.modelDownloadState?.progress = min(max(progress.fraction, 0), 1)
                        self?.modelDownloadState?.downloadedByteCount = progress.downloadedByteCount
                        self?.modelDownloadState?.totalByteCount = progress.totalByteCount
                        self?.modelDownloadState?.bytesPerSecond = progress.bytesPerSecond
                    }
                }
                guard let self else { return }
                modelDownloadState = nil
                modelDownloadTask = nil
                statusMessage = "模型下載完成：\(model.displayName)"
                completion(.success(directoryURL))
            } catch {
                guard let self else { return }
                modelDownloadState = nil
                modelDownloadTask = nil
                if error is CancellationError || Task.isCancelled {
                    do {
                        try downloader.removeTemporaryFiles(
                            model: model,
                            storageDirectoryURL: storageDirectoryURL
                        )
                        statusMessage = "模型下載已停止，暫存檔已清除。"
                    } catch {
                        statusMessage = "模型下載已停止，但暫存檔清除失敗：\(error.localizedDescription)"
                    }
                    completion(.failure(CancellationError()))
                } else {
                    statusMessage = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    func cancelModelDownload() {
        guard let modelDownloadTask else {
            statusMessage = "目前沒有進行中的模型下載。"
            return
        }
        modelDownloadTask.cancel()
        statusMessage = "正在停止模型下載並清除暫存檔…"
    }

    func deleteInstalledModel(
        _ model: DownloadableModelDescriptor,
        from storageDirectoryURL: URL
    ) throws {
        guard modelDownloadTask == nil else {
            throw ModelDeletionError.downloadInProgress
        }
        guard !isProcessing else {
            throw ModelDeletionError.processingInProgress
        }
        try modelDownloader.removeInstalledModel(
            model: model,
            storageDirectoryURL: storageDirectoryURL
        )
        statusMessage = "已刪除模型：\(model.displayName)"
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
        var supportedValue = value
        supportedValue.useImageToImageRestoration = false
        options = supportedValue
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
        try Task.checkCancellation()
        switch operation {
        case .detectMasks:
            try await runDetection(pageID: pageID)
        case .translate:
            try await runTranslation(pageID: pageID)
        case .compose:
            try await runComposition(pageID: pageID)
        case .fullPage:
            if !hasMaskData(pageID: pageID) {
                try await runDetection(pageID: pageID)
                try Task.checkCancellation()
            }
            if !hasTranslationData(pageID: pageID) {
                try await runTranslation(pageID: pageID)
                try Task.checkCancellation()
            }
            if !hasCompletedOutput(pageID: pageID) {
                try await runComposition(pageID: pageID)
            }
        }
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
            $0.ocrTextRefined
                && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func hasCompletedOutput(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              page.stage == .completed,
              let outputURL = page.outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    private func runDetection(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        let useLocalTextModel = await models?.isLoaded(.imageToText) ?? false
        let result = try await pipeline.detectMasks(
            page: page,
            options: options,
            refineOCRText: useLocalTextModel,
            detectMissingRegions: useLocalTextModel,
            activity: activityHandler(pageID: pageID),
            progress: progressHandler(pageID: pageID)
        )
        try Task.checkCancellation()
        let previewURL: URL?
        var previewWarning: String?
        do {
            updateProcessingActivity(pageID: pageID, activity: .renderingMaskPreview)
            previewURL = try await pipeline.renderMaskPreview(
                page: page,
                regions: result.regions,
                maskURL: result.maskURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            previewURL = nil
            previewWarning = "遮罩已完成，但校對預覽建立失敗：\(error.localizedDescription)"
        }
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        undoneMaskStrokes[pageID] = nil
        pages[index].regions = result.regions
        pages[index].maskURL = result.maskURL
        pages[index].backgroundURL = previewURL
        pages[index].translationPreviewURL = nil
        pages[index].outputURL = nil
        pages[index].stage = .maskReady
        pages[index].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        let warnings = result.warnings + [previewWarning].compactMap { $0 }
        statusMessage = warnings.isEmpty
            ? "第 \(pages[index].index) 頁的文字遮罩與去字校對預覽已就緒。"
            : warnings.joined(separator: "\n")
        schedulePersistence()
    }

    private func runTranslation(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard !page.regions.isEmpty else { throw AppWorkflowError.maskRequired }
        var sourceRegions = page.regions
        if sourceRegions.contains(where: { !$0.ocrTextRefined }) {
            sourceRegions = try await pipeline.refineOCRText(
                page: page,
                regions: sourceRegions,
                options: options,
                activity: activityHandler(pageID: pageID),
                progress: progressHandler(pageID: pageID)
            )
            try Task.checkCancellation()
            guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
            pages[index].regions = sourceRegions
            try await persistStringTableNow(pageID: pageID)
        }
        let regions = try await pipeline.translate(
            page: page,
            regions: sourceRegions,
            options: options,
            glossary: glossary,
            activity: activityHandler(pageID: pageID),
            progress: progressHandler(pageID: pageID)
        )
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let composition = try await pipeline.compose(
            page: page,
            regions: regions,
            options: options,
            activity: activityHandler(pageID: pageID),
            progress: translationLayoutProgressHandler(pageID: pageID)
        )
        try Task.checkCancellation()
        pages[index].regions = composition.regions
        pages[index].maskURL = composition.maskURL
        pages[index].backgroundURL = composition.backgroundURL
        pages[index].translationPreviewURL = composition.outputURL
        pages[index].outputURL = nil
        pages[index].stage = .translationReady
        pages[index].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = composition.warnings.isEmpty
            ? "第 \(pages[index].index) 頁翻譯與自動排版完成，可逐區確認或調整。"
            : composition.warnings.joined(separator: "\n")
        schedulePersistence()
    }

    private func runComposition(pageID: UUID) async throws {
        guard let outputDirectoryURL else {
            throw AppWorkflowError.outputDirectoryRequired
        }
        if let previewTask = translationPreviewTasks[pageID] {
            await previewTask.value
        }
        try Task.checkCancellation()
        guard let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard let initialIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        pages[initialIndex].stage = .composing
        pages[initialIndex].progress = Self.totalProgress(stage: .composing, fraction: 0)
        pages[initialIndex].errorMessage = nil
        processingActivities[pageID] = .savingOutput
        statusMessage = "第 \(pages[initialIndex].index) 頁正在儲存輸出…"
        schedulePersistence()

        let paths = try pathResolver.paths(
            sourceURL: page.sourceURL,
            relativeSourcePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
            outputDirectoryURL: outputDirectoryURL
        )
        guard paths.outputURL.standardizedFileURL != page.sourceURL.standardizedFileURL else {
            throw AppWorkflowError.outputWouldOverwriteSource
        }
        guard let previewURL = page.translationPreviewURL,
              FileManager.default.fileExists(atPath: previewURL.path) else {
            throw AppWorkflowError.translationPreviewRequired
        }
        try FileManager.default.createDirectory(
            at: paths.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: paths.outputURL.path) {
            try FileManager.default.removeItem(at: paths.outputURL)
        }
        try FileManager.default.copyItem(at: previewURL, to: paths.outputURL)
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].translationPreviewURL = previewURL
        pages[index].outputURL = paths.outputURL
        pages[index].stage = .completed
        pages[index].progress = 1
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = "第 \(pages[index].index) 頁已確認並儲存至輸出目錄。"
        schedulePersistence()
    }

    private func progressHandler(pageID: UUID) -> PagePipelineProgress {
        { [weak self] stage, fraction in
            Task { @MainActor [weak self] in
                self?.updateProgress(pageID: pageID, stage: stage, fraction: fraction)
            }
        }
    }

    private func activityHandler(pageID: UUID) -> PagePipelineActivity {
        { [weak self] activity in
            Task { @MainActor [weak self] in
                self?.updateProcessingActivity(pageID: pageID, activity: activity)
            }
        }
    }

    private func updateProcessingActivity(
        pageID: UUID,
        activity: PageProcessingActivity
    ) {
        guard batchJobs.contains(where: {
            $0.status == .running && $0.currentPageID == pageID
        }) else { return }
        processingActivities[pageID] = activity
    }

    private func translationLayoutProgressHandler(pageID: UUID) -> PagePipelineProgress {
        { [weak self] _, fraction in
            Task { @MainActor [weak self] in
                self?.updateProgress(
                    pageID: pageID,
                    stage: .translating,
                    fraction: 0.85 + min(max(fraction, 0), 1) * 0.15
                )
            }
        }
    }

    private func updateProgress(pageID: UUID, stage: PageProcessingStage, fraction: Double) {
        guard batchJobs.contains(where: {
            $0.status == .running && $0.currentPageID == pageID
        }) else { return }
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].stage = stage
        pages[index].progress = Self.totalProgress(stage: stage, fraction: fraction)
        pages[index].errorMessage = nil
    }

    private func restoreStablePageStateAfterCancellation(_ pageID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let stage: PageProcessingStage
        if let outputURL = pages[index].outputURL,
           FileManager.default.fileExists(atPath: outputURL.path) {
            stage = .completed
        } else if pages[index].translationPreviewURL != nil
                    || pages[index].regions.contains(where: { !$0.translatedText.isEmpty }) {
            stage = .translationReady
        } else if pages[index].maskURL != nil || !pages[index].regions.isEmpty {
            stage = .maskReady
        } else {
            stage = .scanned
        }
        pages[index].stage = stage
        pages[index].progress = Self.totalProgress(stage: stage, fraction: 1)
        pages[index].errorMessage = nil
    }

    private func markPageEdited(at pageIndex: Int) {
        let hasTranslation = pages[pageIndex].regions.contains { !$0.translatedText.isEmpty }
        // 任何遮罩、文字或樣式修改都會讓舊輸出失效；保留檔案供復原，
        // 但不再讓 UI 把舊圖誤當成本次編輯後的結果。
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = hasTranslation ? .translationReady : .maskReady
        pages[pageIndex].progress = Self.totalProgress(stage: pages[pageIndex].stage, fraction: 1)
        pages[pageIndex].errorMessage = nil
    }

    private func scheduleMaskRegeneration(pageID: UUID, refineRegionID: UUID? = nil) {
        translationPreviewTasks[pageID]?.cancel()
        translationPreviewTasks[pageID] = nil
        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages[index].translationPreviewURL = nil
        }
        maskRegenerationTasks[pageID]?.cancel()
        maskRegenerationTasks[pageID] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  let pipeline = self.pipeline,
                  let page = self.pages.first(where: { $0.id == pageID }) else { return }
            do {
                var regions = page.regions
                if let refineRegionID,
                   let regionIndex = regions.firstIndex(where: { $0.id == refineRegionID }) {
                    let refined = try await pipeline.refineMasks(
                        page: page,
                        regions: [regions[regionIndex]]
                    )
                    guard !Task.isCancelled else { return }
                    if let region = refined.first {
                        regions[regionIndex] = region
                    }
                }
                let maskURL = try await pipeline.regenerateMask(
                    page: page,
                    regions: regions,
                    options: self.options
                )
                guard !Task.isCancelled else { return }
                let previewURL = try? await pipeline.renderMaskPreview(
                    page: page,
                    regions: regions,
                    maskURL: maskURL
                )
                guard !Task.isCancelled else { return }
                guard let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                if let refineRegionID,
                   let refined = regions.first(where: { $0.id == refineRegionID }),
                   let currentIndex = self.pages[index].regions.firstIndex(where: { $0.id == refineRegionID }) {
                    self.pages[index].regions[currentIndex] = refined
                }
                self.pages[index].maskURL = maskURL
                self.pages[index].backgroundURL = previewURL
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

    private func persistEditedRegion(pageID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persistStringTableNow(pageID: pageID)
                self.schedulePersistence()
                self.scheduleTranslationPreviewRegeneration(pageID: pageID)
            } catch {
                self.statusMessage = "更新文字區域失敗：\(error.localizedDescription)"
            }
        }
    }

    private func scheduleTranslationPreviewRegeneration(pageID: UUID) {
        translationPreviewTasks[pageID]?.cancel()
        translationPreviewTasks[pageID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let pipeline = self.pipeline,
                  let page = self.pages.first(where: { $0.id == pageID }),
                  let backgroundURL = page.backgroundURL,
                  let previewURL = page.translationPreviewURL,
                  page.regions.contains(where: { !$0.translatedText.isEmpty }) else { return }
            do {
                try await pipeline.rerender(
                    backgroundURL: backgroundURL,
                    regions: page.regions,
                    outputURL: previewURL
                )
                guard !Task.isCancelled,
                      let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                self.pages[index].translationPreviewURL = previewURL
                self.schedulePersistence()
            } catch is CancellationError {
                return
            } catch {
                self.statusMessage = "更新翻譯排版預覽失敗：\(error.localizedDescription)"
            }
        }
    }

    private func cancelMaskRegeneration() {
        maskRegenerationTasks.values.forEach { $0.cancel() }
        maskRegenerationTasks = [:]
    }

    private func cancelTranslationPreviewRegeneration() {
        translationPreviewTasks.values.forEach { $0.cancel() }
        translationPreviewTasks = [:]
    }

    // MARK: - 掃描合併與 .str

    private func mergeScannedPages(
        _ scanned: [ScannedComicPage],
        sourceDirectoryURL: URL
    ) async {
        let previousPages = pages
        let known = Dictionary(
            uniqueKeysWithValues: previousPages.map { ($0.sourceURL.standardizedFileURL.path, $0) }
        )
        let relocationGroups = Dictionary(grouping: previousPages) {
            Self.pageFingerprint(title: $0.title, width: $0.pixelWidth, height: $0.pixelHeight)
        }
        let relocated = relocationGroups.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var reusedPageIDs: Set<UUID> = []
        var merged: [ComicPage] = []

        for (offset, item) in scanned.enumerated() {
            let title = item.sourceURL.deletingPathExtension().lastPathComponent
            let fingerprint = Self.pageFingerprint(
                title: title,
                width: item.pixelWidth,
                height: item.pixelHeight
            )
            let movedPage = relocated[fingerprint].flatMap {
                reusedPageIDs.contains($0.id) ? nil : $0
            }
            var page = known[item.sourceURL.path] ?? movedPage ?? ComicPage(
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
        await migrateStringTablesToSource()
    }

    private static func pageFingerprint(title: String, width: Int, height: Int) -> String {
        "\(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\(width)x\(height)"
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
        pathResolver.stringTableURL(for: page.sourceURL)
    }

    /// 將舊版位於輸出目錄或專案 StringTables 的 sidecar 複製到原圖旁。
    /// 舊檔保留作為可復原備份，不在遷移過程刪除。
    private func migrateStringTablesToSource() async {
        var failures: [String] = []
        var migrated = false
        for index in pages.indices where !pages[index].regions.isEmpty {
            let page = pages[index]
            let targetURL = pathResolver.stringTableURL(for: page.sourceURL)
            if page.stringTableURL?.standardizedFileURL == targetURL.standardizedFileURL,
               FileManager.default.fileExists(atPath: targetURL.path) {
                continue
            }
            do {
                let table: ComicStringTable
                if let legacyURL = page.stringTableURL,
                   legacyURL.standardizedFileURL != targetURL.standardizedFileURL,
                   let legacy = try await stringTables.load(from: legacyURL) {
                    table = legacy
                } else {
                    table = ComicStringTable(
                        page: page,
                        targetLanguageCode: options.targetLanguageCode
                    )
                }
                try await stringTables.save(table, to: targetURL)
                pages[index].stringTableURL = targetURL
                migrated = true
            } catch {
                failures.append("\(page.title): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            statusMessage = "部分 .str 無法遷移到原圖旁：\n" + failures.joined(separator: "\n")
        }
        if migrated { schedulePersistence() }
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
            if let library = try await libraryRepository.load() {
                projects = library.projects
                batchJobs = library.jobs.map { job in
                    guard job.status == .queued || job.status == .running else { return job }
                    var value = job
                    value.status = .cancelled
                    value.currentPageID = nil
                    value.finishedAt = Date()
                    return value
                }
                guard !library.projects.isEmpty else {
                    activeProjectID = nil
                    return
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
                    await migrateStringTablesToSource()
                    await loadProjectModels(restored.modelDirectories)
                    statusMessage = "已復原專案「\(restored.name)」。"
                }
                await persistLibraryNow()
                return
            }
            try await migrateLegacyWorkspaceIfNeeded()
            if projects.isEmpty {
                try await createDefaultSamplesProjectIfAvailable()
            }
        } catch {
            statusMessage = "無法復原專案資料庫：\(error.localizedDescription)"
        }
    }

    private func createDefaultSamplesProjectIfAvailable() async throws {
        guard let sourceURL = try defaultSamplesDirectoryURL() else { return }
        let snapshot = WorkspaceSnapshot(
            projectID: UUID(),
            name: "Samples",
            options: ProcessingOptions(),
            glossary: ProjectGlossary(),
            pages: [],
            selectedPageID: nil,
            selectedPageIDs: [],
            modelDirectories: [],
            sourceDirectoryURL: sourceURL
        )
        projectSnapshots[snapshot.projectID] = snapshot
        projects = [Self.summary(from: snapshot)]
        apply(snapshot)
        await saveProject(snapshot)
        await persistLibraryNow()
        statusMessage = "已加入預設範例專案「Samples」。"
        scanActiveSourceDirectory()
    }

    private func defaultSamplesDirectoryURL() throws -> URL? {
        let fileManager = FileManager.default
        let currentDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("Samples", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: currentDirectoryURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return currentDirectoryURL.standardizedFileURL
        }

        guard let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("Samples", isDirectory: true),
              fileManager.fileExists(atPath: packagedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let applicationRoot else { return nil }
        let installedURL = applicationRoot.appendingPathComponent("Samples", isDirectory: true)
        if !fileManager.fileExists(atPath: installedURL.path) {
            try fileManager.copyItem(at: packagedURL, to: installedURL)
        }
        return installedURL.standardizedFileURL
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
        await migrateStringTablesToSource()
        if let migrated = makeActiveSnapshot() {
            await saveProject(migrated)
        }
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
            if let previewURL = page.translationPreviewURL,
               !fileManager.fileExists(atPath: previewURL.path) {
                page.translationPreviewURL = nil
            }
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
        cancelTranslationPreviewRegeneration()
        undoneMaskStrokes = [:]
        activeProjectID = snapshot.projectID
        activeProjectCreatedAt = snapshot.createdAt
        pages = snapshot.pages
        var restoredOptions = snapshot.options
        restoredOptions.useImageToImageRestoration = false
        options = restoredOptions
        glossary = snapshot.glossary
        sourceDirectoryURL = snapshot.sourceDirectoryURL
        outputDirectoryURL = snapshot.outputDirectoryURL
        selectedPageID = snapshot.selectedPageID
        selectedPageIDs = snapshot.selectedPageIDs
        activeModelDirectories = snapshot.modelDirectories
    }

    private func clearActiveProject() {
        cancelMaskRegeneration()
        cancelTranslationPreviewRegeneration()
        undoneMaskStrokes = [:]
        activeProjectID = nil
        activeProjectCreatedAt = Date()
        pages = []
        sourceDirectoryURL = nil
        outputDirectoryURL = nil
        selectedPageID = nil
        selectedPageIDs = []
        options = ProcessingOptions()
        glossary = ProjectGlossary()
        activeModelDirectories = []
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
        processingActivities[pageID] = nil
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

private enum ModelDeletionError: LocalizedError {
    case downloadInProgress
    case processingInProgress

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            "模型下載進行中，請先停止下載。"
        case .processingInProgress:
            "工作處理進行中，請先停止工作再刪除模型。"
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
    case translationPreviewRequired
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .projectNotFound: "找不到指定的專案資料。"
        case .pageNotFound: "找不到指定的漫畫頁面。"
        case .maskRequired: "請先執行文字與遮罩偵測，再進行翻譯。"
        case .outputDirectoryRequired: "輸出前請先選取輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內，以免重新掃描到輸出檔。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片，已中止輸出。"
        case .translationPreviewRequired: "找不到已完成自動排版的翻譯預覽，請重新執行翻譯。"
        case .runtimeUnavailable: "漫畫處理 Runtime 尚未就緒。"
        }
    }
}
