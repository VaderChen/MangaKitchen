import Combine
import Foundation
import ImageIO
import MangaKitchenCore
import MangaKitchenRuntime

struct ProcessingRegionProgress: Sendable {
    var current: Int
    var total: Int
}

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
    @Published private(set) var modelLoadingState: ModelLoadingState?
    @Published private(set) var automaticSuperResolutionEnabled = false
    @Published private(set) var processingActivities: [UUID: PageProcessingActivity] = [:]
    @Published private(set) var processingRegionProgress: [UUID: ProcessingRegionProgress] = [:]
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
    private let importService = ManagedImportService()
    private let htmlTypesetter: HTMLDialogueTypesetter?

    private var defaultOutputDirectoryURL: URL?
    private var projectSnapshots: [UUID: WorkspaceSnapshot] = [:]
    private var activeModelDirectories: [URL] = []
    private var preferredModelPaths: [ModelCapability: String] = [:]
    private var activeProjectCreatedAt = Date()
    private var processingTask: Task<Void, Never>?
    private var regionRecognitionTask: Task<Void, Never>?
    private var modelDownloadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var maskRegenerationTasks: [UUID: Task<Void, Never>] = [:]
    private var translationPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var undoneMaskStrokes: [UUID: [UUID: [MaskStroke]]] = [:]
    private var maskRevisions: [UUID: UInt64] = [:]
    private var regionUndoHistory: [UUID: [[DialogueRegion]]] = [:]
    private var regionRedoHistory: [UUID: [[DialogueRegion]]] = [:]
    private var excludedSourceRelativePaths: Set<String> = []

    init(
        dataDirectoryPath: String? = nil,
        defaultOutputDirectoryPath: String? = nil,
        imageCompositingBackend: ImageCompositingBackend = .cpu,
        imageToTextModelPath: String? = nil,
        imageToImageModelPath: String? = nil,
        automaticSuperResolutionEnabled: Bool = false,
        superResolutionModelPath: String? = nil
    ) {
        defaultOutputDirectoryURL = defaultOutputDirectoryPath
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
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
            let bubbleSegmenter = Self.bundledBubbleSegmenter()
            let htmlTypesetter = HTMLDialogueTypesetter()
            let vlmTextRecognizer = VLMRegionTranscriptionService(model: models)
            let textRecognizer: any RegionTextRecognizing
            if let ocrRuntime = Self.bundledOCRRuntime() {
                textRecognizer = OCRRegionTextRecognitionService(
                    locator: vlmTextRecognizer,
                    ocr: ocrRuntime
                )
            } else {
                textRecognizer = vlmTextRecognizer
            }
            let pipeline = ComicTranslationPipeline(
                regionDetector: MangaBubbleMaskRegionDetector(bubbleSegmenter: bubbleSegmenter),
                textRecognizer: textRecognizer,
                maskRefiner: MangaTextMaskRefiner(),
                translator: VLMRegionTranslationService(model: models),
                maskGenerator: DialogueMaskGenerator(),
                backgroundRestorer: backgroundRestorer,
                typesetter: htmlTypesetter,
                outputRoot: artifactsRoot,
                superResolver: models
            )
            self.models = models
            self.pipeline = pipeline
            self.backgroundRestorer = backgroundRestorer
            self.htmlTypesetter = htmlTypesetter
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
            self.automaticSuperResolutionEnabled = automaticSuperResolutionEnabled
        } catch {
            models = nil
            pipeline = nil
            backgroundRestorer = nil
            htmlTypesetter = nil
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
                imageToImagePath: imageToImageModelPath,
                superResolutionPath: superResolutionModelPath
            )
        }
    }

    var activeProjectName: String? {
        guard let activeProjectID else { return nil }
        return projects.first(where: { $0.id == activeProjectID })?.name
    }

    var applicationDataDirectoryPath: String? { applicationRoot?.path }

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

    /// OCR 模型是可選的：沒有隨 App 提供模型與字典時，翻譯仍使用原本的 VLM。
    /// 一旦放入 `Resources/Models/OCR/`，App 便會在步驟三以原生 Core ML OCR
    /// 保存該模型的獨立候選，不會改動 VLM 定位、sourceText 或遮罩。
    private static func bundledOCRRuntime() -> PPOCRRecognitionRuntime? {
        guard let modelURL = Bundle.module.url(
            forResource: "ppocrv6-small-rec-macos14",
            withExtension: "mlpackage",
            subdirectory: "Models/OCR"
        ), let characterURL = Bundle.module.url(
            forResource: "ppocrv6-small-rec-characters",
            withExtension: "json",
            subdirectory: "Models/OCR"
        ), let characters = try? PPOCRCharacterList.load(from: characterURL) else {
            return nil
        }
        return try? PPOCRRecognitionRuntime(
            modelURL: modelURL,
            modelID: "ppocrv6-small-rec",
            characters: characters
        )
    }

    func setImageCompositingBackend(_ backend: ImageCompositingBackend) {
        guard let backgroundRestorer else { return }
        Task { [weak self] in
            await backgroundRestorer.setCompositingBackend(backend)
            self?.statusMessage = backend == .gpu
                ? "圖像合成已切換為 GPU。"
                : "圖像合成已切換為 CPU。"
        }
    }

    func applyMCPState(_ state: MCPWorkspaceState) async {
        guard let sourceDirectoryURL = state.sourceDirectoryURL?.standardizedFileURL else { return }
        let isActiveSource = self.sourceDirectoryURL?.standardizedFileURL == sourceDirectoryURL
        if !isActiveSource {
            await persistActiveProjectNow()
        }
        let existingProject = projects.first {
            $0.sourceDirectoryURL.standardizedFileURL == sourceDirectoryURL
        }
        let projectID = existingProject?.id ?? state.workspaceID ?? UUID()
        let existingSnapshot: WorkspaceSnapshot?
        if isActiveSource {
            existingSnapshot = makeActiveSnapshot()
        } else if let cached = projectSnapshots[projectID] {
            existingSnapshot = cached
        } else {
            existingSnapshot = try? await projectRepository(for: projectID)?.load()
        }
        let selectionPages = existingSnapshot?.pages ?? []
        let selectedSourcePaths = Set(
            (existingSnapshot?.selectedPageIDs ?? []).compactMap { pageID in
                selectionPages.first(where: { $0.id == pageID })?
                    .sourceURL.standardizedFileURL.path
            }
        )
        let activeSourcePath = existingSnapshot?.selectedPageID.flatMap { pageID in
            selectionPages.first(where: { $0.id == pageID })?
                .sourceURL.standardizedFileURL.path
        }
        let incomingPages = state.pages
        let previousPages = Dictionary(
            uniqueKeysWithValues: selectionPages.map {
                ($0.sourceURL.standardizedFileURL.path, $0)
            }
        )
        let selectedIncomingPageID = incomingPages.first {
            $0.sourceURL.standardizedFileURL.path == activeSourcePath
        }?.id ?? incomingPages.first?.id
        let selectedIncomingPageIDs = Set(
            incomingPages.filter {
                selectedSourcePaths.contains($0.sourceURL.standardizedFileURL.path)
            }.map(\.id)
        )
        let snapshot = WorkspaceSnapshot(
            projectID: projectID,
            name: existingProject?.name ?? state.name ?? sourceDirectoryURL.lastPathComponent,
            createdAt: existingSnapshot?.createdAt ?? Date(),
            options: state.options,
            glossary: state.glossary,
            pages: incomingPages,
            selectedPageID: selectedIncomingPageID,
            selectedPageIDs: selectedIncomingPageIDs.isEmpty
                ? Set(selectedIncomingPageID.map { [$0] } ?? [])
                : selectedIncomingPageIDs,
            modelDirectories: existingSnapshot?.modelDirectories ?? [],
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: state.outputDirectoryURL?.standardizedFileURL,
            excludedSourceRelativePaths: existingSnapshot?.excludedSourceRelativePaths ?? []
        )
        let restored = validated(snapshot)
        for page in restored.pages {
            let path = page.sourceURL.standardizedFileURL.path
            if previousPages[path] != page {
                advanceMaskRevision(pageID: page.id)
            }
        }
        projectSnapshots[projectID] = restored
        cache(restored)
        apply(restored)
        schedulePersistence()
        statusMessage = "MCP 已同步專案資料。"
    }

    func snapshotForMCP(sourceDirectoryURL: URL) async -> WorkspaceSnapshot? {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        if self.sourceDirectoryURL?.standardizedFileURL == sourceURL {
            return makeActiveSnapshot()
        }
        guard let projectID = projects.first(where: {
            $0.sourceDirectoryURL.standardizedFileURL == sourceURL
        })?.id else { return nil }
        if let cached = projectSnapshots[projectID] {
            return cached
        }
        return try? await projectRepository(for: projectID)?.load()
    }

    // MARK: - 專案管理與步驟一

    /// 每個來源目錄對應一個專案；重複選取既有目錄時改為切換並重掃。
    func openProject(from directoryURL: URL, displayName: String? = nil) {
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
            let projectName = displayName.flatMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            } ?? sourceURL.lastPathComponent
            let snapshot = WorkspaceSnapshot(
                projectID: projectID,
                name: projectName,
                options: ProcessingOptions(),
                glossary: ProjectGlossary(),
                pages: [],
                selectedPageID: nil,
                selectedPageIDs: [],
                modelDirectories: [],
                sourceDirectoryURL: sourceURL,
                outputDirectoryURL: self.defaultOutputDirectoryURL(
                    for: sourceURL,
                    projectName: projectName
                )
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
        guard !inputURLs.isEmpty, let applicationRoot else { return }
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "工作或專案切換進行中，暫時無法匯入。"
            return
        }
        statusMessage = "正在建立可攜式匯入專案…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let managedRoot = applicationRoot.appendingPathComponent("Imported", isDirectory: true)
                let directory = try self.importService.materialize(inputURLs, under: managedRoot)
                let name = inputURLs.first?.deletingPathExtension().lastPathComponent
                self.openProject(from: directory, displayName: name)
            } catch {
                self.statusMessage = "匯入失敗：\(error.localizedDescription)"
            }
        }
    }

    func appendPages(from inputURLs: [URL]) {
        guard !inputURLs.isEmpty,
              let applicationRoot,
              let sourceDirectoryURL else { return }
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "工作或專案切換進行中，暫時無法追加頁面。"
            return
        }
        statusMessage = "正在追加漫畫頁面…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let importedRoot = applicationRoot.appendingPathComponent("Imported", isDirectory: true)
                let source = sourceDirectoryURL.standardizedFileURL
                let managedPrefix = importedRoot.standardizedFileURL.path + "/"
                let projectRoot: URL
                if source.path.hasPrefix(managedPrefix) {
                    let destination = source
                        .appendingPathComponent("Imported-\(UUID().uuidString)", isDirectory: true)
                    try self.importService.append(inputURLs, to: destination)
                    projectRoot = source
                } else {
                    projectRoot = try self.importService.materialize(
                        [source] + inputURLs,
                        under: importedRoot
                    )
                }
                let scanned = try self.scanner.scan(projectRoot)
                await self.mergeScannedPages(scanned, sourceDirectoryURL: projectRoot)
                self.statusMessage = "已追加頁面，專案目前共 \(self.pages.count) 頁。"
                self.schedulePersistence()
            } catch {
                self.statusMessage = "追加頁面失敗：\(error.localizedDescription)"
            }
        }
    }

    func exportPSD(pageIDs: [UUID], to directory: URL) {
        let selected = pages.filter { pageIDs.contains($0.id) }
        guard !selected.isEmpty else { statusMessage = "請先選取至少一張漫畫頁面。"; return }
        guard let htmlTypesetter else {
            statusMessage = "HTML 排版器尚未就緒。"
            return
        }
        statusMessage = "正在以 HTML/CSS 建立 PSD 圖層…"
        Task { [weak self] in
            guard let self else { return }
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MangaKitchen-PSD-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                var exportedCount = 0
                for page in selected {
                    try Task.checkCancellation()
                    let pageTemporaryDirectory = temporaryRoot
                        .appendingPathComponent(page.id.uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: pageTemporaryDirectory,
                        withIntermediateDirectories: true
                    )
                    let backgroundURL = page.superResolvedBackgroundURL
                        ?? page.backgroundURL
                        ?? page.sourceURL
                    let renderScale = Self.superResolutionRenderScale(for: page)
                    let compositeURL = pageTemporaryDirectory.appendingPathComponent("html-composite.png")
                    try await htmlTypesetter.typeset(
                        backgroundURL: backgroundURL,
                        regions: page.regions,
                        outputURL: compositeURL,
                        renderScale: renderScale
                    )
                    guard let composite = Self.loadImage(compositeURL) else { continue }
                    let renderedLayers = try await htmlTypesetter.renderTextLayers(
                        canvasURL: backgroundURL,
                        regions: page.regions,
                        outputDirectory: pageTemporaryDirectory,
                        renderScale: renderScale
                    )
                    var layers = renderedLayers.reversed().compactMap { layer -> PSDLayer? in
                        guard let image = Self.loadImage(layer.outputURL),
                              image.width == composite.width,
                              image.height == composite.height else { return nil }
                        return PSDLayer(
                            name: layer.name,
                            image: image,
                            opacity: 255,
                            visible: layer.visible
                        )
                    }
                    if let background = Self.loadImage(backgroundURL),
                       background.width == composite.width,
                       background.height == composite.height {
                        layers.append(PSDLayer(
                            name: "Clean Background",
                            image: background,
                            opacity: 255,
                            visible: true
                        ))
                    }
                    if let source = Self.loadImage(page.sourceURL),
                       source.width == composite.width,
                       source.height == composite.height {
                        layers.append(PSDLayer(
                            name: "Original Source",
                            image: source,
                            opacity: 255,
                            visible: false
                        ))
                    }
                    if layers.isEmpty {
                        layers.append(PSDLayer(
                            name: "HTML Composite",
                            image: composite,
                            opacity: 255,
                            visible: true
                        ))
                    }
                    let safeTitle = page.title.replacingOccurrences(of: ".", with: "_")
                    let filename = String(format: "%04d_%@.psd", page.index, safeTitle)
                    try PSDExporter().write(
                        layers: layers,
                        mergedImage: composite,
                        to: directory.appendingPathComponent(filename)
                    )
                    exportedCount += 1
                }
                self.statusMessage = "已由 HTML/CSS 輸出 \(exportedCount) 個分層 PSD。"
            } catch is CancellationError {
                self.statusMessage = "PSD 輸出已取消。"
            } catch {
                self.statusMessage = "PSD 匯出失敗：\(error.localizedDescription)"
            }
        }
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        }
    }

    private static func superResolutionRenderScale(for page: ComicPage) -> Double {
        guard let url = page.superResolvedBackgroundURL,
              let image = loadImage(url) else { return 1 }
        return max(
            1,
            min(
                Double(image.width) / Double(max(1, page.pixelWidth)),
                Double(image.height) / Double(max(1, page.pixelHeight))
            )
        )
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

    /// 設定全域預設輸出目錄。只會套用到尚未指定輸出目錄的目前／新專案，
    /// 不覆寫使用者已明確選取的專案輸出位置。
    func setDefaultOutputDirectory(_ directoryURL: URL?) {
        guard let directoryURL else {
            defaultOutputDirectoryURL = nil
            return
        }
        let normalized = directoryURL.standardizedFileURL
        do {
            try validateOutputDirectory(normalized)
            defaultOutputDirectoryURL = normalized
            if outputDirectoryURL == nil, let sourceDirectoryURL {
                let projectOutputURL = defaultOutputDirectoryURL(
                    for: sourceDirectoryURL,
                    projectName: activeProjectName
                ) ?? normalized
                try FileManager.default.createDirectory(
                    at: projectOutputURL,
                    withIntermediateDirectories: true
                )
                outputDirectoryURL = projectOutputURL
                schedulePersistence()
            }
            statusMessage = "預設輸出目錄已設定。"
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

    func renamePage(pageID: UUID, name: String) {
        guard !isProcessing,
              let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "頁面名稱不可空白。"
            return
        }
        pages[index].title = String(normalized.prefix(200))
        statusMessage = "已重新命名頁面。"
        schedulePersistence()
    }

    func movePage(pageID: UUID, offset: Int) {
        guard !isProcessing,
              offset != 0,
              let sourceIndex = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let destinationIndex = min(max(sourceIndex + offset, 0), pages.count - 1)
        guard destinationIndex != sourceIndex else { return }
        let page = pages.remove(at: sourceIndex)
        pages.insert(page, at: destinationIndex)
        normalizePageIndexes()
        schedulePersistence()
    }

    func removePages(_ pageIDs: [UUID]) {
        guard !isProcessing, !isSwitchingProject else {
            statusMessage = "請等待目前工作完成或先取消工作。"
            return
        }
        let requested = Set(pageIDs)
        let removed = pages.filter { requested.contains($0.id) }
        guard !removed.isEmpty else { return }
        for page in removed {
            if let relativePath = page.relativeSourcePath {
                excludedSourceRelativePaths.insert(relativePath)
            }
            maskRegenerationTasks[page.id]?.cancel()
            translationPreviewTasks[page.id]?.cancel()
            undoneMaskStrokes[page.id] = nil
            regionUndoHistory[page.id] = nil
            regionRedoHistory[page.id] = nil
        }
        pages.removeAll { requested.contains($0.id) }
        normalizePageIndexes()
        let validIDs = Set(pages.map(\.id))
        selectedPageIDs.formIntersection(validIDs)
        selectedPageID = selectedPageID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? pages.first?.id
        if selectedPageIDs.isEmpty, let selectedPageID { selectedPageIDs = [selectedPageID] }
        statusMessage = "已從專案移除 \(removed.count) 頁；來源檔案保留。"
        schedulePersistence()
    }

    private func normalizePageIndexes() {
        for index in pages.indices { pages[index].index = index + 1 }
    }

    func clearPages() {
        guard !isProcessing else { return }
        cancelMaskRegeneration()
        cancelTranslationPreviewRegeneration()
        undoneMaskStrokes = [:]
        excludedSourceRelativePaths.formUnion(pages.compactMap(\.relativeSourcePath))
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
                pages[pageIndex].superResolvedBackgroundURL = nil
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
            page.superResolvedBackgroundURL,
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

    func extractTextSelectedPage() {
        enqueueSelected(operation: .extractText, forceRecalculation: true)
    }

    func retranslateSelectedPage() {
        enqueueSelected(operation: .retranslate, forceRecalculation: true)
    }

    func composeAllPages() {
        enqueueBatch(operation: .compose, pageIDs: pages.map(\.id))
    }

    func composeSelectedPage() {
        enqueueSelected(operation: .compose)
    }

    func superResolveSelectedPage() {
        enqueueSelected(operation: .superResolve)
    }

    func processAllPages() {
        enqueueBatch(operation: .fullPage, pageIDs: pages.map(\.id))
    }

    func processSelectedPage() {
        enqueueSelected(operation: .fullPage)
    }

    @discardableResult
    func enqueueBatch(
        operation: BatchOperation,
        pageIDs: [UUID],
        forceRecalculation: Bool = false
    ) -> UUID? {
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
        if operation == .superResolve,
           !loadedModels.contains(where: { $0.capability == .superResolution }) {
            statusMessage = "請先在設定中下載並載入超解析模型。"
            return nil
        }
        if operation.requiresTextModel,
           !loadedModels.contains(where: { $0.capability == .imageToText }) {
            statusMessage = "本機文字區域辨識或翻譯前請先載入圖生文模型。"
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
            forceRecalculation: forceRecalculation,
            pageIDs: Array(orderedIDs)
        )
        batchJobs.append(job)
        statusMessage = "已將 \(job.pageIDs.count) 頁加入工作佇列。"
        schedulePersistence()
        startBatchQueueIfNeeded()
        return job.id
    }

    func cancelProcessing() {
        regionRecognitionTask?.cancel()
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
        cancelledPageIDs.forEach { processingRegionProgress[$0] = nil }
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
        enqueueBatch(
            operation: job.operation,
            pageIDs: job.failures.map(\.pageID),
            forceRecalculation: job.forceRecalculation
        )
    }

    func clearFinishedBatchJobs() {
        batchJobs.removeAll { $0.status != .queued && $0.status != .running }
        schedulePersistence()
    }

    private func enqueueSelected(
        operation: BatchOperation,
        forceRecalculation: Bool = false
    ) {
        let ids = selectedPageIDs.isEmpty
            ? selectedPageID.map { [$0] } ?? []
            : pages.lazy.map(\.id).filter(selectedPageIDs.contains)
        enqueueBatch(
            operation: operation,
            pageIDs: Array(ids),
            forceRecalculation: forceRecalculation
        )
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
                let forceRecalculation = self.batchJobs[jobIndex].forceRecalculation
                let pageIDs = self.batchJobs[jobIndex].pageIDs

                for pageID in pageIDs {
                    guard !Task.isCancelled,
                          let currentIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                          self.batchJobs[currentIndex].status == .running else { break }
                    self.batchJobs[currentIndex].currentPageID = pageID
                    self.processingActivities[pageID] = .preparingPage
                    self.processingRegionProgress[pageID] = nil
                    do {
                        try await self.run(
                            operation,
                            pageID: pageID,
                            forceRecalculation: forceRecalculation
                        )
                        try Task.checkCancellation()
                        guard let resultIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                              self.batchJobs[resultIndex].status == .running else {
                            self.processingActivities[pageID] = nil
                            self.processingRegionProgress[pageID] = nil
                            break
                        }
                        self.batchJobs[resultIndex].completedPageIDs.append(pageID)
                    } catch is CancellationError {
                        self.processingActivities[pageID] = nil
                        self.processingRegionProgress[pageID] = nil
                        break
                    } catch {
                        guard let resultIndex = self.batchJobs.firstIndex(where: { $0.id == jobID }),
                              self.batchJobs[resultIndex].status == .running else {
                            self.processingActivities[pageID] = nil
                            self.processingRegionProgress[pageID] = nil
                            break
                        }
                        self.batchJobs[resultIndex].failures.append(
                            BatchPageFailure(pageID: pageID, message: error.localizedDescription)
                        )
                        self.markFailed(pageID: pageID, message: error.localizedDescription)
                    }
                    self.processingActivities[pageID] = nil
                    self.processingRegionProgress[pageID] = nil
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
        recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
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
            // 新區域只有粗框，必須對齊並精修後才畫，否則會退回整框塗滿。
            scheduleMaskRegeneration(pageID: pageID, refineRegionID: region.id)
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
        recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
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

    func maskRevision(pageID: UUID) -> UInt64 {
        maskRevisions[pageID] ?? 0
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
        recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
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

    func moveRegion(pageID: UUID, regionID: UUID, offset: Int) {
        guard offset != 0,
              let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let sourceIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            return
        }
        let destinationIndex = min(
            max(sourceIndex + offset, 0),
            pages[pageIndex].regions.count - 1
        )
        guard destinationIndex != sourceIndex else { return }
        recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
        let region = pages[pageIndex].regions.remove(at: sourceIndex)
        pages[pageIndex].regions.insert(region, at: destinationIndex)
        markPageEdited(at: pageIndex)
        persistEditedRegion(pageID: pageID)
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
        textAlignment: DialogueTextAlignment?,
        textColorHex: String?,
        strokeColorHex: String?,
        strokeWidth: Double?,
        opacity: Double?,
        rotationDegrees: Double?,
        isVisible: Bool?,
        useAutomaticFontSize: Bool?,
        writingDirection: WritingDirection?,
        automaticMaskEnabled: Bool?
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            statusMessage = "找不到要更新的對話區域。"
            return
        }
        recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
        var edit = RegionEdit()
        edit.sourceText = sourceText
        edit.translatedText = translatedText
        if let translationAnchor { edit.translationAnchor = .set(translationAnchor) }
        if let translationBounds { edit.translationBounds = .set(translationBounds) }
        edit.bounds = bounds
        if let bubbleBounds { edit.bubbleBounds = .set(bubbleBounds) }
        edit.fontName = fontName
        if let fontSize, fontSize.isFinite { edit.fontSize = .set(fontSize) }
        edit.useAutomaticFontSize = useAutomaticFontSize
        edit.fontWeight = fontWeight
        edit.textAlignment = textAlignment
        edit.textColorHex = textColorHex
        edit.strokeColorHex = strokeColorHex
        edit.strokeWidth = strokeWidth
        edit.opacity = opacity
        edit.rotationDegrees = rotationDegrees
        edit.isVisible = isVisible
        edit.writingDirection = writingDirection
        edit.automaticMaskEnabled = automaticMaskEnabled
        var shouldRefineMask = PageRegionEditor.apply(
            edit,
            to: &pages[pageIndex].regions[regionIndex]
        )
        // 手動多邊形是 App 專屬能力：使用者已經給了精確遮罩，就不要再自動精修蓋掉。
        if let maskPolygons {
            let sanitizedPolygons = maskPolygons
                .map { $0.map { $0.clamped() } }
                .filter { $0.count >= 3 }
            pages[pageIndex].regions[regionIndex].maskPolygons = sanitizedPolygons
            pages[pageIndex].regions[regionIndex].maskRefinementApplied = !sanitizedPolygons.isEmpty
            pages[pageIndex].regions[regionIndex].maskCoverageRatio = nil
            pages[pageIndex].regions[regionIndex].maskCoverageComplete = !sanitizedPolygons.isEmpty
            shouldRefineMask = false
        }
        markPageEdited(at: pageIndex)
        let shouldRegenerateMask = shouldRefineMask
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

    /// 重新抽取並翻譯單一文字區域；不重建遮罩、不翻譯其他區域。
    @discardableResult
    func reextractRegion(pageID: UUID, regionID: UUID) -> Bool {
        guard !isProcessing else {
            statusMessage = "目前已有工作進行中，請稍候再重新抽取。"
            return false
        }
        guard loadedModels.contains(where: { $0.capability == .imageToText }) else {
            statusMessage = "請先載入圖生文模型，才能重新抽取文字。"
            return false
        }
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }),
              let region = page.regions.first(where: { $0.id == regionID }) else {
            statusMessage = "找不到要重新抽取的文字區域。"
            return false
        }
        guard let backgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: backgroundURL.path),
              let maskURL = page.maskURL,
              FileManager.default.fileExists(atPath: maskURL.path) else {
            statusMessage = "請先完成步驟二的遮罩與去字背景，再重新抽取並翻譯此區域。"
            return false
        }

        isProcessing = true
        processingActivities[pageID] = .preparingPage
        processingRegionProgress[pageID] = ProcessingRegionProgress(current: 0, total: 1)
        statusMessage = "正在重新抽取並翻譯第 \(page.index) 頁的單一文字區域…"
        regionRecognitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.regionRecognitionTask = nil
                self.processingActivities[pageID] = nil
                self.processingRegionProgress[pageID] = nil
                self.isProcessing = false
            }
            do {
                let recognized = try await pipeline.recognizeRegion(
                    page: page,
                    region: region,
                    options: self.options,
                    regionProgress: { current, total in
                        Task { @MainActor [weak self] in
                            self?.processingRegionProgress[pageID] = ProcessingRegionProgress(
                                current: current,
                                total: total
                            )
                        }
                    },
                    progress: { value in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                            self.pages[index].progress = Self.totalProgress(
                                stage: .translating,
                                fraction: min(max(value, 0), 0.45)
                            )
                            self.processingActivities[pageID] = .detectingRegions
                        }
                    }
                )
                try Task.checkCancellation()
                guard let pageIndex = self.pages.firstIndex(where: { $0.id == pageID }),
                      let regionIndex = self.pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
                    return
                }
                guard !recognized.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.statusMessage = "這個區域沒有重新抽取到可用原文；已保留原結果。"
                    return
                }

                self.processingActivities[pageID] = .translatingRegions
                self.processingRegionProgress[pageID] = ProcessingRegionProgress(current: 0, total: 1)
                let translated = try await pipeline.translate(
                    page: page,
                    regions: [recognized],
                    options: self.options,
                    glossary: self.glossary,
                    recognizeText: false,
                    activity: { activity in
                        Task { @MainActor [weak self] in
                            self?.processingActivities[pageID] = activity
                        }
                    },
                    regionProgress: { current, total in
                        Task { @MainActor [weak self] in
                            self?.processingRegionProgress[pageID] = ProcessingRegionProgress(
                                current: current,
                                total: total
                            )
                        }
                    },
                    progress: { stage, fraction in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                            self.pages[index].stage = stage
                            self.pages[index].progress = Self.totalProgress(
                                stage: stage,
                                fraction: min(max(fraction, 0), 1)
                            )
                        }
                    }
                ).first ?? recognized
                try Task.checkCancellation()

                var updated = self.pages[pageIndex].regions[regionIndex]
                updated.rawSourceText = recognized.rawSourceText
                updated.sourceText = recognized.sourceText
                updated.ocrResults = recognized.ocrResults
                updated.ocrTextRefined = recognized.ocrTextRefined
                updated.detectedWritingDirection = recognized.detectedWritingDirection
                updated.mcpExtractedSourceText = nil
                updated.translatedText = translated.translatedText
                updated.literalTranslatedText = translated.literalTranslatedText
                updated.speakerID = translated.speakerID
                updated.tone = translated.tone
                updated.translationConfidence = translated.translationConfidence
                updated.translationQAFlags = translated.translationQAFlags
                self.recordRegionHistory(pageID: pageID, regions: self.pages[pageIndex].regions)
                self.pages[pageIndex].regions[regionIndex] = updated
                self.markPageEdited(at: pageIndex)
                self.pages[pageIndex].translationPreviewURL = nil
                self.pages[pageIndex].outputURL = nil
                self.pages[pageIndex].stage = .typesetting
                self.pages[pageIndex].progress = Self.totalProgress(stage: .typesetting, fraction: 0)
                self.processingActivities[pageID] = .preparingTranslationPreview
                let previewPage = self.pages[pageIndex]
                let allRegions = previewPage.regions
                let previewBackgroundURL = previewPage.superResolvedBackgroundURL.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                } ?? backgroundURL
                let previewURL = try await pipeline.renderTranslationPreview(
                    page: previewPage,
                    backgroundURL: previewBackgroundURL,
                    regions: allRegions
                )
                try Task.checkCancellation()
                guard let updatedPageIndex = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                self.pages[updatedPageIndex].translationPreviewURL = previewURL
                self.pages[updatedPageIndex].stage = .translationReady
                self.pages[updatedPageIndex].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
                try await self.persistStringTableNow(pageID: pageID)
                self.schedulePersistence()
                self.statusMessage = "已重新抽取並翻譯單一文字區域。"
            } catch is CancellationError {
                self.statusMessage = "已取消單一文字區域重新抽取與翻譯。"
            } catch {
                self.statusMessage = "單一文字區域重新抽取與翻譯失敗：\(error.localizedDescription)"
            }
        }
        return true
    }

    func undoRegionEdit(pageID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              var history = regionUndoHistory[pageID], let previous = history.popLast() else {
            statusMessage = "沒有可復原的文字區域修改。"
            return
        }
        regionUndoHistory[pageID] = history.isEmpty ? nil : history
        regionRedoHistory[pageID, default: []].append(pages[pageIndex].regions)
        pages[pageIndex].regions = previous
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
        scheduleTranslationPreviewRegeneration(pageID: pageID)
    }

    func redoRegionEdit(pageID: UUID) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              var history = regionRedoHistory[pageID], let next = history.popLast() else {
            statusMessage = "沒有可重做的文字區域修改。"
            return
        }
        regionRedoHistory[pageID] = history.isEmpty ? nil : history
        regionUndoHistory[pageID, default: []].append(pages[pageIndex].regions)
        pages[pageIndex].regions = next
        markPageEdited(at: pageIndex)
        scheduleMaskRegeneration(pageID: pageID)
        scheduleTranslationPreviewRegeneration(pageID: pageID)
    }

    private func recordRegionHistory(pageID: UUID, regions: [DialogueRegion]) {
        var history = regionUndoHistory[pageID] ?? []
        if history.last != regions { history.append(regions) }
        if history.count > 50 { history.removeFirst(history.count - 50) }
        regionUndoHistory[pageID] = history
        regionRedoHistory[pageID] = nil
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

    func applyPreferredModels(
        imageToTextPath: String?,
        imageToImagePath: String?,
        superResolutionPath: String? = nil
    ) {
        Task {
            await applyPreferredModelsNow(
                imageToTextPath: imageToTextPath,
                imageToImagePath: imageToImagePath,
                superResolutionPath: superResolutionPath
            )
        }
    }

    func setAutomaticSuperResolutionEnabled(_ enabled: Bool) {
        automaticSuperResolutionEnabled = enabled
        schedulePersistence()
    }

    func setOptions(_ value: ProcessingOptions) {
        var supportedValue = value
        supportedValue.useImageToImageRestoration = false
        let previousDefaultFont = options.defaultStyle.fontName
        let nextDefaultFont = supportedValue.defaultStyle.fontName
        let eraseColorChanged = options.eraseColorHex != supportedValue.eraseColorHex
        var fontUpdatedPageIDs: [UUID] = []
        if previousDefaultFont != nextDefaultFont {
            for pageIndex in pages.indices {
                let matchingRegionIndexes = pages[pageIndex].regions.indices.filter {
                    pages[pageIndex].regions[$0].style.fontName == previousDefaultFont
                }
                guard !matchingRegionIndexes.isEmpty else { continue }
                let pageID = pages[pageIndex].id
                recordRegionHistory(pageID: pageID, regions: pages[pageIndex].regions)
                for regionIndex in matchingRegionIndexes {
                    pages[pageIndex].regions[regionIndex].style.fontName = nextDefaultFont
                }
                markPageEdited(at: pageIndex)
                fontUpdatedPageIDs.append(pageID)
            }
        }
        options = supportedValue
        var eraseColorUpdatedPageIDs = Set<UUID>()
        if eraseColorChanged {
            for pageIndex in pages.indices where pages[pageIndex].backgroundURL != nil {
                let pageID = pages[pageIndex].id
                eraseColorUpdatedPageIDs.insert(pageID)
                // 底色是步驟二設定。只讓舊去字背景失效，不在設定變更時
                // 暗中執行遮罩／背景步驟；使用者回到步驟二重新計算。
                pages[pageIndex].backgroundURL = nil
                pages[pageIndex].superResolvedBackgroundURL = nil
                pages[pageIndex].translationPreviewURL = nil
                pages[pageIndex].outputURL = nil
                pages[pageIndex].stage = .maskReady
                pages[pageIndex].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
            }
        }
        for pageID in fontUpdatedPageIDs where !eraseColorUpdatedPageIDs.contains(pageID) {
            scheduleTranslationPreviewRegeneration(pageID: pageID)
        }
        schedulePersistence()
        guard !fontUpdatedPageIDs.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for pageID in fontUpdatedPageIDs {
                    try await self.persistStringTableNow(pageID: pageID)
                }
                self.schedulePersistence()
            } catch {
                self.statusMessage = "更新預設字型失敗：\(error.localizedDescription)"
            }
        }
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

    private func run(
        _ operation: BatchOperation,
        pageID: UUID,
        forceRecalculation: Bool = false
    ) async throws {
        try Task.checkCancellation()
        switch operation {
        case .detectMasks:
            try await runDetection(pageID: pageID)
        case .translate:
            try await runTranslation(
                pageID: pageID,
                forceRecalculation: forceRecalculation
            )
        case .extractText:
            try await runTextExtraction(pageID: pageID)
        case .retranslate:
            try await runTranslation(
                pageID: pageID,
                forceRecalculation: true,
                recognizeText: false
            )
        case .superResolve:
            try await runSuperResolution(pageID: pageID)
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
        guard let page = pages.first(where: { $0.id == pageID }),
              let maskURL = page.maskURL,
              let backgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: maskURL.path),
              FileManager.default.fileExists(atPath: backgroundURL.path) else { return false }
        return true
    }

    private func hasTranslationData(pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }),
              let previewURL = page.translationPreviewURL else { return false }
        guard FileManager.default.fileExists(atPath: previewURL.path) else { return false }
        return page.regions.isEmpty || hasTranslatedRegions(page)
    }

    private func hasTranslatedRegions(_ page: ComicPage) -> Bool {
        guard !page.regions.isEmpty else { return false }
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

    private func runDetection(pageID: UUID) async throws {
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        // 沒有可用的圖生文模型時，步驟二仍可進入手動模式；不要呼叫
        // 氣泡／文字自動偵測，直接建立同尺寸全黑遮罩供畫筆編輯。
        guard loadedModels.contains(where: { $0.capability == .imageToText }) else {
            try await prepareEmptyMask(pageID: pageID, page: page, pipeline: pipeline)
            return
        }
        let result = try await pipeline.detectMasks(
            page: page,
            options: options,
            activity: activityHandler(pageID: pageID),
            progress: progressHandler(pageID: pageID)
        )
        try Task.checkCancellation()
        updateProcessingActivity(pageID: pageID, activity: .renderingMaskPreview)
        let previewURL = try await pipeline.renderMaskPreview(
            page: page,
            regions: result.regions,
            maskURL: result.maskURL,
            fillColorHex: options.eraseColorHex
        )
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        undoneMaskStrokes[pageID] = nil
        pages[index].regions = result.regions
        pages[index].maskURL = result.maskURL
        pages[index].backgroundURL = previewURL
        pages[index].superResolvedBackgroundURL = nil
        advanceMaskRevision(pageID: pageID)
        pages[index].translationPreviewURL = nil
        pages[index].outputURL = nil
        pages[index].stage = .maskReady
        pages[index].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        let warnings = result.warnings
        statusMessage = warnings.isEmpty
            ? "第 \(pages[index].index) 頁的文字遮罩與去字校對預覽已就緒。"
            : warnings.joined(separator: "\n")
        schedulePersistence()
    }

    /// 沒有圖生文模型時仍允許進入遮罩編輯：用空區域清單產生與原圖
    /// 同尺寸的全黑遮罩。既有人工區域保留在頁面資料中，不因降級流程被清除。
    private func prepareEmptyMask(
        pageID: UUID,
        page: ComicPage,
        pipeline: ComicTranslationPipeline
    ) async throws {
        updateProcessingActivity(pageID: pageID, activity: .generatingMask)
        updateProgress(pageID: pageID, stage: .detectingText, fraction: 0.9)
        let maskURL = try await pipeline.regenerateMask(
            page: page,
            regions: [],
            options: options
        )
        try Task.checkCancellation()

        updateProcessingActivity(pageID: pageID, activity: .renderingMaskPreview)
        let previewURL = try await pipeline.renderMaskPreview(
            page: page,
            regions: [],
            maskURL: maskURL,
            fillColorHex: options.eraseColorHex
        )
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        undoneMaskStrokes[pageID] = nil
        pages[index].maskURL = maskURL
        pages[index].backgroundURL = previewURL
        pages[index].superResolvedBackgroundURL = nil
        advanceMaskRevision(pageID: pageID)
        pages[index].translationPreviewURL = nil
        pages[index].outputURL = nil
        pages[index].stage = .maskReady
        pages[index].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        statusMessage = "尚未載入圖生文模型；已建立全黑遮罩與去字背景，可手動編輯。"
        schedulePersistence()
    }

    private func runTextExtraction(pageID: UUID) async throws {
        await stopTranslationPreviewRegeneration(pageID: pageID)
        try Task.checkCancellation()
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard let backgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: backgroundURL.path),
              let maskURL = page.maskURL,
              FileManager.default.fileExists(atPath: maskURL.path) else {
            throw AppWorkflowError.maskRequired
        }
        guard !page.regions.isEmpty else {
            statusMessage = "本頁沒有可重新抽取的文字區域。"
            return
        }
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].translationPreviewURL = nil
        pages[index].outputURL = nil
        pages[index].stage = .translating
        pages[index].progress = Self.totalProgress(stage: .translating, fraction: 0)
        pages[index].errorMessage = nil
        processingActivities[pageID] = .detectingRegions
        statusMessage = "第 \(page.index) 頁正在重新抽取文字…"
        schedulePersistence()

        let recognized = try await pipeline.recognizeRegions(
            page: page,
            regions: page.regions,
            options: options,
            force: true,
            activity: activityHandler(pageID: pageID),
            regionProgress: regionProgressHandler(pageID: pageID),
            progress: { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.updateProgress(
                        pageID: pageID,
                        stage: .translating,
                        fraction: value
                    )
                }
            }
        )
        try Task.checkCancellation()
        guard let updatedIndex = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let recognizedByID = Dictionary(uniqueKeysWithValues: recognized.map { ($0.id, $0) })
        pages[updatedIndex].regions = pages[updatedIndex].regions.map { original in
            guard let extracted = recognizedByID[original.id],
                  !extracted.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return original
            }
            var updated = original
            updated.rawSourceText = extracted.rawSourceText
            updated.sourceText = extracted.sourceText
            updated.ocrResults = extracted.ocrResults
            updated.ocrTextRefined = extracted.ocrTextRefined
            updated.detectedWritingDirection = extracted.detectedWritingDirection
            updated.translatedText = ""
            updated.literalTranslatedText = nil
            updated.mcpExtractedSourceText = nil
            updated.speakerID = nil
            updated.tone = nil
            updated.translationConfidence = nil
            updated.translationQAFlags = []
            return updated
        }
        pages[updatedIndex].translationPreviewURL = nil
        pages[updatedIndex].outputURL = nil
        pages[updatedIndex].stage = .translating
        pages[updatedIndex].progress = Self.totalProgress(stage: .translating, fraction: 1)
        pages[updatedIndex].errorMessage = nil
        processingActivities[pageID] = nil
        processingRegionProgress[pageID] = nil
        try await persistStringTableNow(pageID: pageID)
        schedulePersistence()
        statusMessage = "第 \(page.index) 頁已重新抽取文字；請按「重新翻譯」。"
    }

    private func runTranslation(
        pageID: UUID,
        forceRecalculation: Bool = false,
        recognizeText: Bool = true
    ) async throws {
        await stopTranslationPreviewRegeneration(pageID: pageID)
        try Task.checkCancellation()
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard let cleanBackgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: cleanBackgroundURL.path),
              let maskURL = page.maskURL,
              FileManager.default.fileExists(atPath: maskURL.path) else {
            // 步驟三不得在缺少步驟二產物時自行重建遮罩或背景。
            throw AppWorkflowError.maskRequired
        }
        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages[index].translationPreviewURL = nil
            pages[index].outputURL = nil
        }
        let regions: [DialogueRegion]
        if page.regions.isEmpty {
            regions = []
        } else if !forceRecalculation && hasTranslatedRegions(page) {
            regions = page.regions
        } else {
            guard await models?.isLoaded(.imageToText) == true else {
                throw ModelRuntimeError.capabilityNotLoaded(.imageToText)
            }
            regions = try await pipeline.translate(
                page: page,
                regions: page.regions,
                options: options,
                glossary: glossary,
                recognizeText: recognizeText,
                activity: activityHandler(pageID: pageID),
                regionProgress: regionProgressHandler(pageID: pageID),
                progress: progressHandler(pageID: pageID)
            )
        }
        try Task.checkCancellation()
        let untranslatedRegionCount = regions.count(where: {
            $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })

        var superResolvedBackgroundURL = page.superResolvedBackgroundURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if superResolvedBackgroundURL == nil,
           automaticSuperResolutionEnabled,
           loadedModels.contains(where: { $0.capability == .superResolution }) {
            updateProcessingActivity(pageID: pageID, activity: .superResolving)
            superResolvedBackgroundURL = try await pipeline.superResolve(
                page: page,
                inputURL: cleanBackgroundURL,
                progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(
                            pageID: pageID,
                            stage: .superResolving,
                            fraction: value
                        )
                    }
                }
            )
        }
        updateProcessingActivity(pageID: pageID, activity: .typesettingTranslation)
        guard let typesettingIndex = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[typesettingIndex].regions = regions
        pages[typesettingIndex].translationPreviewURL = nil
        pages[typesettingIndex].outputURL = nil
        pages[typesettingIndex].stage = .typesetting
        pages[typesettingIndex].errorMessage = nil
        let previewURL = try await pipeline.renderTranslationPreview(
            page: page,
            backgroundURL: superResolvedBackgroundURL ?? cleanBackgroundURL,
            regions: regions
        )
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].regions = regions
        // maskURL／backgroundURL 是步驟二產物；步驟三只能讀取，絕不覆寫。
        pages[index].superResolvedBackgroundURL = superResolvedBackgroundURL
        pages[index].translationPreviewURL = previewURL
        pages[index].outputURL = nil
        pages[index].stage = .translationReady
        pages[index].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
        pages[index].errorMessage = nil
        try await persistStringTableNow(pageID: pageID)
        var warnings: [String] = []
        if untranslatedRegionCount > 0 {
            warnings.append(
                "有 \(untranslatedRegionCount) 個文字區域翻譯失敗，已保留原有譯文並繼續處理。"
            )
        }
        let qualityWarningCount = regions.count {
            $0.translationQAFlags.contains(where: { $0 != .reviewAdjusted })
        }
        if qualityWarningCount > 0 {
            warnings.append("有 \(qualityWarningCount) 個文字區域需要翻譯品質檢查，已在文字區域面板標示。")
        }
        statusMessage = warnings.isEmpty
            ? "第 \(pages[index].index) 頁翻譯與自動排版完成，可逐區確認或調整。"
            : warnings.joined(separator: "\n")
        schedulePersistence()
    }

    private func runSuperResolution(pageID: UUID) async throws {
        try Task.checkCancellation()
        guard let pipeline,
              let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard let backgroundURL = page.backgroundURL,
              FileManager.default.fileExists(atPath: backgroundURL.path) else {
            throw AppWorkflowError.maskRequired
        }
        guard loadedModels.contains(where: { $0.capability == .superResolution }) else {
            throw ModelRuntimeError.capabilityNotLoaded(.superResolution)
        }
        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages[index].stage = .superResolving
            pages[index].progress = Self.totalProgress(stage: .superResolving, fraction: 0)
            pages[index].errorMessage = nil
        }
        processingActivities[pageID] = .superResolving
        statusMessage = "第 \(page.index) 頁正在執行超解析…"
        let resolvedURL = try await pipeline.superResolve(
            page: page,
            inputURL: backgroundURL,
            progress: { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.updateProgress(
                        pageID: pageID,
                        stage: .superResolving,
                        fraction: value
                    )
                }
            }
        )
        try Task.checkCancellation()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].superResolvedBackgroundURL = resolvedURL
        // SR 改變了步驟三的背景與排字尺寸，先讓舊預覽與步驟四輸出失效。
        // 否則步驟三會顯示 2x SR 背景，步驟四卻繼續讀取 SR 前的 1x 檔案。
        pages[index].translationPreviewURL = nil
        pages[index].outputURL = nil
        let previewURL = try await pipeline.renderTranslationPreview(
            page: pages[index],
            backgroundURL: resolvedURL,
            regions: pages[index].regions
        )
        pages[index].translationPreviewURL = previewURL
        pages[index].stage = .translationReady
        pages[index].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
        pages[index].errorMessage = nil
        statusMessage = "第 \(pages[index].index) 頁已完成超解析與重新排版。"
        try await persistStringTableNow(pageID: pageID)
        schedulePersistence()
    }

    private func runComposition(pageID: UUID) async throws {
        guard let outputDirectoryURL else {
            throw AppWorkflowError.outputDirectoryRequired
        }
        if let maskTask = maskRegenerationTasks[pageID] {
            await maskTask.value
        }
        if let previewTask = translationPreviewTasks[pageID] {
            await previewTask.value
        }
        try Task.checkCancellation()
        guard let page = pages.first(where: { $0.id == pageID }) else {
            throw AppWorkflowError.pageNotFound
        }
        guard hasMaskData(pageID: pageID) else {
            throw AppWorkflowError.maskRequired
        }
        guard hasTranslationData(pageID: pageID) else {
            throw AppWorkflowError.translationPreviewRequired
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
        let completedPreviewURL: URL
        if let translationPreviewURL = page.translationPreviewURL,
           FileManager.default.fileExists(atPath: translationPreviewURL.path) {
            completedPreviewURL = translationPreviewURL
        } else {
            throw AppWorkflowError.translationPreviewRequired
        }
        try FileManager.default.createDirectory(
            at: paths.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previewData = try Data(contentsOf: completedPreviewURL)
        try previewData.write(to: paths.outputURL, options: .atomic)
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
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

    private func regionProgressHandler(pageID: UUID) -> PageRegionProgress {
        { [weak self] current, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.batchJobs.contains(where: {
                    $0.status == .running && $0.currentPageID == pageID
                }) else { return }
                self.processingRegionProgress[pageID] = ProcessingRegionProgress(
                    current: max(0, current),
                    total: max(0, total)
                )
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
        if processingActivities[pageID] != activity {
            processingRegionProgress[pageID] = nil
        }
        processingActivities[pageID] = activity
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
        let stage = Self.completedArtifactStage(for: pages[index])
        pages[index].stage = stage
        pages[index].progress = Self.totalProgress(stage: stage, fraction: 1)
        pages[index].errorMessage = nil
    }

    private func markPageEdited(at pageIndex: Int) {
        let hasTranslation = pages[pageIndex].regions.contains { !$0.translatedText.isEmpty }
        // 任何遮罩、文字或樣式修改都會讓舊輸出失效；保留檔案供復原，
        // 但不再讓 UI 把舊圖誤當成本次編輯後的結果。
        pages[pageIndex].outputURL = nil
        pages[pageIndex].stage = hasTranslation ? .typesetting : .maskReady
        pages[pageIndex].progress = Self.totalProgress(stage: pages[pageIndex].stage, fraction: 1)
        pages[pageIndex].errorMessage = nil
    }

    /// 區域編輯的唯一實作，與 MCP 端共用。
    private var regionEditor: PageRegionEditor? {
        pipeline.map {
            PageRegionEditor(pipeline: $0, bubbleSegmenter: Self.bundledBubbleSegmenter())
        }
    }

    private func scheduleMaskRegeneration(pageID: UUID, refineRegionID: UUID? = nil) {
        translationPreviewTasks[pageID]?.cancel()
        translationPreviewTasks[pageID] = nil
        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages[index].maskURL = nil
            pages[index].backgroundURL = nil
            pages[index].translationPreviewURL = nil
            pages[index].superResolvedBackgroundURL = nil
            pages[index].outputURL = nil
            pages[index].stage = .masking
            pages[index].progress = Self.totalProgress(stage: .masking, fraction: 0)
        }
        maskRegenerationTasks[pageID]?.cancel()
        maskRegenerationTasks[pageID] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  let pipeline = self.pipeline,
                  let page = self.pages.first(where: { $0.id == pageID }) else { return }
            do {
                let outcome = try await PageRegionEditor(
                    pipeline: pipeline,
                    bubbleSegmenter: Self.bundledBubbleSegmenter()
                ).materialize(
                    regions: page.regions,
                    refining: refineRegionID.map { [$0] } ?? [],
                    page: page,
                    options: self.options,
                    regeneratesMask: true
                )
                guard !Task.isCancelled else { return }
                let regions = outcome.regions
                guard let maskURL = outcome.maskURL else { return }
                guard !Task.isCancelled else { return }
                let previewURL = try await pipeline.renderMaskPreview(
                    page: page,
                    regions: regions,
                    maskURL: maskURL,
                    fillColorHex: self.options.eraseColorHex
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
                self.pages[index].superResolvedBackgroundURL = nil
                self.pages[index].stage = .maskReady
                self.pages[index].progress = Self.totalProgress(stage: .maskReady, fraction: 1)
                self.pages[index].errorMessage = nil
                self.advanceMaskRevision(pageID: pageID)
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

    private func advanceMaskRevision(pageID: UUID) {
        objectWillChange.send()
        maskRevisions[pageID, default: 0] &+= 1
    }

    private func persistEditedRegion(pageID: UUID) {
        scheduleTranslationPreviewRegeneration(pageID: pageID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persistStringTableNow(pageID: pageID)
                self.schedulePersistence()
            } catch {
                self.statusMessage = "更新文字區域失敗：\(error.localizedDescription)"
            }
        }
    }

    private func scheduleTranslationPreviewRegeneration(pageID: UUID) {
        let previousTask = translationPreviewTasks[pageID]
        previousTask?.cancel()
        translationPreviewTasks[pageID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousTask?.value
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let pipeline = self.pipeline,
                  let page = self.pages.first(where: { $0.id == pageID }),
                  let backgroundURL = page.superResolvedBackgroundURL ?? page.backgroundURL,
                  let previewURL = page.translationPreviewURL,
                  page.regions.contains(where: { !$0.translatedText.isEmpty }) else { return }
            do {
                try await pipeline.rerender(
                    backgroundURL: backgroundURL,
                    regions: page.regions,
                    outputURL: previewURL,
                    renderScale: Self.superResolutionRenderScale(for: page)
                )
                guard !Task.isCancelled,
                      let index = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                self.pages[index].translationPreviewURL = previewURL
                self.pages[index].stage = .translationReady
                self.pages[index].progress = Self.totalProgress(stage: .translationReady, fraction: 1)
                self.pages[index].errorMessage = nil
                self.schedulePersistence()
            } catch is CancellationError {
                return
            } catch {
                if let index = self.pages.firstIndex(where: { $0.id == pageID }) {
                    self.pages[index].translationPreviewURL = nil
                    self.pages[index].outputURL = nil
                    self.pages[index].stage = .failed
                    self.pages[index].errorMessage = error.localizedDescription
                }
                self.statusMessage = "更新翻譯排版預覽失敗：\(error.localizedDescription)"
            }
        }
    }

    private func stopTranslationPreviewRegeneration(pageID: UUID) async {
        guard let task = translationPreviewTasks[pageID] else { return }
        task.cancel()
        await task.value
        translationPreviewTasks[pageID] = nil
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
        let knownRelative = Dictionary(
            uniqueKeysWithValues: previousPages.compactMap { page in
                page.relativeSourcePath.map { ($0, page) }
            }
        )
        let relocationGroups = Dictionary(grouping: previousPages) {
            Self.pageFingerprint(title: $0.title, width: $0.pixelWidth, height: $0.pixelHeight)
        }
        let relocated = relocationGroups.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var reusedPageIDs: Set<UUID> = []
        var merged: [ComicPage] = []
        let previousOrder = Dictionary(
            uniqueKeysWithValues: previousPages.enumerated().map { ($0.element.id, $0.offset) }
        )
        var discoveredOrder: [UUID: Int] = [:]

        let included = scanned.filter { !excludedSourceRelativePaths.contains($0.relativePath) }
        for (offset, item) in included.enumerated() {
            let title = item.sourceURL.deletingPathExtension().lastPathComponent
            let fingerprint = Self.pageFingerprint(
                title: title,
                width: item.pixelWidth,
                height: item.pixelHeight
            )
            let movedPage = relocated[fingerprint].flatMap {
                reusedPageIDs.contains($0.id) ? nil : $0
            }
            var page = known[item.sourceURL.path]
                ?? knownRelative[item.relativePath]
                ?? movedPage
                ?? ComicPage(
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
                page.stage = Self.completedArtifactStage(for: page)
            }
            discoveredOrder[page.id] = offset
            merged.append(page)
        }

        merged.sort { left, right in
            let leftPrevious = previousOrder[left.id]
            let rightPrevious = previousOrder[right.id]
            switch (leftPrevious, rightPrevious) {
            case let (.some(leftIndex), .some(rightIndex)):
                return leftIndex < rightIndex
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return (discoveredOrder[left.id] ?? .max) < (discoveredOrder[right.id] ?? .max)
            }
        }
        for index in merged.indices { merged[index].index = index + 1 }

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
        let table = ComicStringTable(
            page: pages[index],
            targetLanguageCode: options.resolvedTargetLanguageCode
        )
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
                        targetLanguageCode: options.resolvedTargetLanguageCode
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

    private func defaultOutputDirectoryURL(
        for sourceURL: URL,
        projectName: String? = nil
    ) -> URL? {
        guard let defaultOutputDirectoryURL else { return nil }
        let sourcePath = sourceURL.standardizedFileURL.path
        let baseURL = defaultOutputDirectoryURL.standardizedFileURL
        let outputPath = baseURL.path
        guard outputPath != sourcePath,
              !outputPath.hasPrefix(sourcePath + "/") else { return nil }
        guard let component = Self.safeOutputDirectoryComponent(
            projectName ?? sourceURL.lastPathComponent
        ) else {
            return baseURL
        }
        let projectURL = baseURL.appendingPathComponent(component, isDirectory: true).standardizedFileURL
        let projectPath = projectURL.path
        guard projectPath != sourcePath,
              !projectPath.hasPrefix(sourcePath + "/") else { return nil }
        return projectURL
    }

    /// 預設輸出子目錄只接受單一路徑元件，避免專案顯示名稱改變輸出根目錄或穿越目錄。
    private static func safeOutputDirectoryComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        let separators = CharacterSet(charactersIn: "/\\:")
        let sanitized = trimmed
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else { return nil }
        return sanitized
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
        snapshot.schemaVersion = 4
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
        let modificationDate: (URL) -> Date? = { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let existingPages: [ComicPage] = value.pages.compactMap { original -> ComicPage? in
            guard fileManager.fileExists(atPath: original.sourceURL.path) else { return nil }
            var page = original
            if let previewURL = page.translationPreviewURL,
               !fileManager.fileExists(atPath: previewURL.path) {
                page.translationPreviewURL = nil
            }
            if let maskURL = page.maskURL,
               !fileManager.fileExists(atPath: maskURL.path) {
                page.maskURL = nil
            }
            if let backgroundURL = page.backgroundURL,
               !fileManager.fileExists(atPath: backgroundURL.path) {
                page.backgroundURL = nil
            }
            if let superResolvedURL = page.superResolvedBackgroundURL,
               !fileManager.fileExists(atPath: superResolvedURL.path) {
                page.superResolvedBackgroundURL = nil
            }
            if let outputURL = page.outputURL,
               !fileManager.fileExists(atPath: outputURL.path) {
                page.outputURL = nil
                if page.stage == .completed {
                    page.stage = Self.completedArtifactStage(for: page)
                }
            }
            if let outputURL = page.outputURL,
               let previewURL = page.translationPreviewURL,
               let outputModifiedAt = modificationDate(outputURL),
               let previewModifiedAt = modificationDate(previewURL),
               outputModifiedAt < previewModifiedAt {
                // 步驟四只能儲存步驟三的現行預覽。舊版本在 SR 後沒有清掉
                // outputURL，導致重啟後仍把較早的 1x 檔案誤當成已完成輸出。
                page.outputURL = nil
                if page.stage == .completed {
                    page.stage = Self.completedArtifactStage(for: page)
                }
            }
            let stableStages: Set<PageProcessingStage> = [
                .pending, .scanned, .maskReady, .translationReady, .completed, .failed
            ]
            if !stableStages.contains(page.stage) {
                page.stage = Self.completedArtifactStage(for: page)
                page.errorMessage = "上次處理未完成，請重新執行該步驟。"
            } else if page.stage == .translationReady,
                      page.translationPreviewURL == nil {
                page.stage = Self.completedArtifactStage(for: page)
            } else if page.stage == .maskReady,
                      (page.maskURL == nil || page.backgroundURL == nil) {
                page.stage = Self.completedArtifactStage(for: page)
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
        var restoredOptions = snapshot.options
        restoredOptions.useImageToImageRestoration = false
        let previousDefaultFont = restoredOptions.defaultStyle.fontName
        let normalizedDefaultFont = FontFamilyCatalog.normalizedFontName(
            previousDefaultFont,
            for: restoredOptions.resolvedTargetLanguageCode
        )
        restoredOptions.defaultStyle.fontName = normalizedDefaultFont
        var restoredPages = snapshot.pages
        if previousDefaultFont != normalizedDefaultFont {
            for pageIndex in restoredPages.indices {
                for regionIndex in restoredPages[pageIndex].regions.indices
                where restoredPages[pageIndex].regions[regionIndex].style.fontName == previousDefaultFont {
                    restoredPages[pageIndex].regions[regionIndex].style.fontName = normalizedDefaultFont
                }
            }
        }
        pages = restoredPages
        options = restoredOptions
        glossary = snapshot.glossary
        sourceDirectoryURL = snapshot.sourceDirectoryURL
        outputDirectoryURL = snapshot.outputDirectoryURL
        selectedPageID = snapshot.selectedPageID
        selectedPageIDs = snapshot.selectedPageIDs
        excludedSourceRelativePaths = snapshot.excludedSourceRelativePaths
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
        excludedSourceRelativePaths = []
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
            outputDirectoryURL: outputDirectoryURL,
            excludedSourceRelativePaths: excludedSourceRelativePaths
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
        let loadableDirectories = directories.filter { directoryURL in
            guard fileManager.fileExists(atPath: directoryURL.path) else { return false }
            if let manifest = try? ModelManifest.load(from: directoryURL),
               preferredModelPaths[manifest.capability] != nil {
                return false
            }
            return true
        }
        let sessionID = UUID()
        for (offset, directoryURL) in loadableDirectories.enumerated() {
            let succeeded = await loadModelNow(
                from: directoryURL,
                models: models,
                persist: false,
                sessionID: sessionID,
                currentIndex: offset + 1,
                totalCount: loadableDirectories.count
            )
            if !succeeded { break }
        }
    }

    private func applyPreferredModelsNow(
        imageToTextPath: String?,
        imageToImagePath: String?,
        superResolutionPath: String?
    ) async {
        guard let models else { return }
        _ = await replacePreferredModel(
            capability: .imageToText,
            path: imageToTextPath,
            models: models
        )
        _ = await replacePreferredModel(
            capability: .imageToImage,
            path: imageToImagePath,
            models: models
        )
        _ = await replacePreferredModel(
            capability: .superResolution,
            path: superResolutionPath,
            models: models
        )
        loadedModels = await models.loadedModels()
    }

    private func replacePreferredModel(
        capability: ModelCapability,
        path: String?,
        models: ModelRuntimeHub
    ) async -> Bool {
        guard preferredModelPaths[capability] != path else { return true }
        await models.unloadModel(capability: capability)
        guard let path else {
            preferredModelPaths.removeValue(forKey: capability)
            return true
        }
        let directoryURL = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let manifest = try ModelManifest.load(from: directoryURL)
            guard manifest.capability == capability else {
                throw PreferredModelError.capabilityMismatch(expected: capability)
            }
            _ = try await loadRuntimeModel(
                from: directoryURL,
                models: models,
                sessionID: UUID(),
                currentIndex: 1,
                totalCount: 1
            )
            preferredModelPaths[capability] = path
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func loadModelNow(
        from directoryURL: URL,
        models: ModelRuntimeHub,
        persist: Bool,
        sessionID: UUID = UUID(),
        currentIndex: Int = 1,
        totalCount: Int = 1
    ) async -> Bool {
        do {
            let info = try await loadRuntimeModel(
                from: directoryURL,
                models: models,
                sessionID: sessionID,
                currentIndex: currentIndex,
                totalCount: totalCount
            )
            loadedModels = await models.loadedModels()
            if persist {
                let location = directoryURL.standardizedFileURL
                if !activeModelDirectories.contains(location) {
                    activeModelDirectories.append(location)
                }
                schedulePersistence()
            }
            statusMessage = "已載入 \(info.displayName)（\(info.backend.rawValue)／\(info.capability.rawValue)）。"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func loadRuntimeModel(
        from directoryURL: URL,
        models: ModelRuntimeHub,
        sessionID: UUID,
        currentIndex: Int,
        totalCount: Int
    ) async throws -> LoadedModelInfo {
        let safeTotalCount = max(1, totalCount)
        let safeCurrentIndex = min(max(1, currentIndex), safeTotalCount)
        let fallbackName = directoryURL.lastPathComponent
        let displayName = (try? ModelManifest.load(from: directoryURL))?.displayName
            ?? fallbackName
        modelLoadingState = ModelLoadingState(
            id: sessionID,
            phase: .loading,
            displayName: displayName,
            currentIndex: safeCurrentIndex,
            totalCount: safeTotalCount,
            progress: Double(safeCurrentIndex - 1) / Double(safeTotalCount),
            errorMessage: nil
        )
        statusMessage = "正在載入模型：\(displayName)…"

        do {
            let info = try await models.loadModel(at: directoryURL)
            guard modelLoadingState?.id == sessionID else { return info }
            modelLoadingState?.displayName = info.displayName
            modelLoadingState?.progress = Double(safeCurrentIndex) / Double(safeTotalCount)
            if safeCurrentIndex == safeTotalCount {
                modelLoadingState?.phase = .completed
                try? await Task.sleep(for: .milliseconds(450))
                if modelLoadingState?.id == sessionID,
                   modelLoadingState?.phase == .completed {
                    modelLoadingState = nil
                }
            }
            return info
        } catch {
            modelLoadingState = ModelLoadingState(
                id: sessionID,
                phase: .failed,
                displayName: displayName,
                currentIndex: safeCurrentIndex,
                totalCount: safeTotalCount,
                progress: Double(safeCurrentIndex - 1) / Double(safeTotalCount),
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private func markFailed(pageID: UUID, message: String) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        processingActivities[pageID] = nil
        processingRegionProgress[pageID] = nil
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
        self == .translate || self == .extractText || self == .retranslate || self == .fullPage
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
        case .maskRequired: "請先完成步驟二的文字區域、遮罩與去字背景，再進行翻譯。"
        case .outputDirectoryRequired: "輸出前請先選取輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內，以免重新掃描到輸出檔。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片，已中止輸出。"
        case .translationPreviewRequired: "步驟三的原文、譯文或自動排版預覽尚未完成，請先補齊後再輸出。"
        case .runtimeUnavailable: "漫畫處理 Runtime 尚未就緒。"
        }
    }
}
