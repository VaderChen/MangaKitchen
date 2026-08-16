import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

struct MCPWorkspaceState: Codable, Sendable {
    var workspaceID: UUID?
    var name: String?
    var sourceDirectoryURL: URL?
    var outputDirectoryURL: URL?
    var options: ProcessingOptions
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
}

struct MCPWorkflowResult: Codable, Sendable {
    var workspaceID: UUID
    var operation: String
    var processedPageIDs: [UUID]
    var pages: [ComicPage]
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
    private let pipeline: ComicTranslationPipeline
    private let scanner = ComicDirectoryScanner()
    private let stringTables = ComicStringTableRepository()
    private let pathResolver = WorkflowPathResolver()
    private let workspaceRoot: URL

    private var workspaceID: UUID?
    private var sourceDirectoryURL: URL?
    private var outputDirectoryURL: URL?
    private var options = ProcessingOptions()
    private var glossary = ProjectGlossary()
    private var pages: [ComicPage] = []
    private var workspaces: [UUID: MCPWorkspaceContext] = [:]

    init(dataDirectoryPath: String?) throws {
        let metal = try MetalContext()
        let models = ModelRuntimeHub(metal: metal)
        let root = try Self.makeWorkspaceRoot(dataDirectoryPath: dataDirectoryPath)
        self.models = models
        self.workspaceRoot = root
        self.pipeline = ComicTranslationPipeline(
            recognizer: VisionOCRService(),
            translator: VLMRegionTranslationService(model: models),
            maskGenerator: DialogueMaskGenerator(),
            backgroundRestorer: try HybridBackgroundRestorer(models: models, metal: metal),
            typesetter: CoreTextDialogueTypesetter(),
            outputRoot: root.appendingPathComponent("Artifacts", isDirectory: true)
        )
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
        let oldPages = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.sourceURL.standardizedFileURL.path, $0) }
        )
        let scanner = self.scanner
        let scanned = try await Task.detached {
            try scanner.scan(sourceDirectoryURL)
        }.value
        pages = scanned.enumerated().map { offset, item in
            var page = oldPages[item.sourceURL.path] ?? ComicPage(
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
        return await state()
    }

    func setOutputDirectory(workspaceID: UUID, directoryURL: URL) async throws -> MCPWorkspaceState {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard let sourceDirectoryURL else { throw MCPServiceError.workspaceNotOpen }
        try validateOutputDirectory(directoryURL, sourceDirectoryURL: sourceDirectoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        outputDirectoryURL = directoryURL.standardizedFileURL
        for page in pages where !page.regions.isEmpty {
            try await persistStringTable(pageID: page.id)
        }
        return await state()
    }

    func configure(
        workspaceID: UUID,
        targetLanguageCode: String?,
        readingDirection: ReadingDirection?,
        writingDirection: WritingDirection?,
        fontName: String?,
        useImageToImageRestoration: Bool?
    ) throws -> ProcessingOptions {
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
        if let useImageToImageRestoration {
            options.useImageToImageRestoration = useImageToImageRestoration
        }
        return options
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
        if step == .translate || step == .fullPage {
            let loaded = await models.loadedModels()
            guard loaded.contains(where: { $0.capability == .imageToText }) else {
                throw MCPServiceError.textModelRequired
            }
        }
        if step == .compose || step == .fullPage {
            guard outputDirectoryURL != nil else { throw MCPServiceError.outputDirectoryRequired }
        }

        let targetIDs = try resolvePageIDs(requestedPageIDs)
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
                try await translate(pageID: pageID, progress: pageProgress)
            case .compose:
                try await compose(pageID: pageID, progress: pageProgress)
            case .fullPage:
                try await detect(pageID: pageID, progress: pageProgress)
                try await translate(pageID: pageID, progress: pageProgress)
                try await compose(pageID: pageID, progress: pageProgress)
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

    func updateRegion(
        workspaceID: UUID,
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
    ) async throws -> DialogueRegion {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        if let sourceText { pages[pageIndex].regions[regionIndex].sourceText = sourceText }
        if let translatedText { pages[pageIndex].regions[regionIndex].translatedText = translatedText }
        if let bounds { pages[pageIndex].regions[regionIndex].bounds = bounds.clamped() }
        if let fontName, !fontName.isEmpty { pages[pageIndex].regions[regionIndex].style.fontName = fontName }
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
        try await refreshEditedPage(pageIndex: pageIndex)
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
        pages[pageIndex].regions.append(region)
        try await refreshEditedPage(pageIndex: pageIndex)
        return region
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

    func addStroke(
        workspaceID: UUID,
        pageID: UUID,
        regionID: UUID,
        mode: MaskStrokeMode,
        diameter: Double,
        points: [NormalizedPoint]
    ) async throws -> DialogueRegion {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard !points.isEmpty else { throw MCPServiceError.invalidArguments("points 不可為空。") }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        pages[pageIndex].regions[regionIndex].maskStrokes.append(MaskStroke(
            mode: mode,
            points: points,
            diameter: diameter
        ))
        try await refreshEditedPage(pageIndex: pageIndex)
        return pages[pageIndex].regions[regionIndex]
    }

    func undoStroke(workspaceID: UUID, pageID: UUID, regionID: UUID) async throws -> DialogueRegion {
        try requireWorkspace(workspaceID)
        defer { saveActiveWorkspace() }
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let regionIndex = pages[pageIndex].regions.firstIndex(where: { $0.id == regionID }) else {
            throw MCPServiceError.regionNotFound
        }
        guard !pages[pageIndex].regions[regionIndex].maskStrokes.isEmpty else {
            throw MCPServiceError.invalidArguments("這個區域沒有可復原的筆劃。")
        }
        pages[pageIndex].regions[regionIndex].maskStrokes.removeLast()
        try await refreshEditedPage(pageIndex: pageIndex)
        return pages[pageIndex].regions[regionIndex]
    }

    func state() async -> MCPWorkspaceState {
        saveActiveWorkspace()
        return MCPWorkspaceState(
            workspaceID: workspaceID,
            name: sourceDirectoryURL?.lastPathComponent,
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            options: options,
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

    private func detect(pageID: UUID, progress: @escaping PagePipelineProgress) async throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw MCPServiceError.pageNotFound
        }
        let result = try await pipeline.detectMasks(page: pages[index], options: options, progress: progress)
        pages[index].regions = result.regions
        pages[index].maskURL = result.maskURL
        pages[index].stage = .maskReady
        pages[index].progress = 0.25
        pages[index].errorMessage = nil
        try await persistStringTable(pageID: pageID)
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
            progress: progress
        )
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
        let root = outputDirectoryURL
            ?? workspaceRoot
                .appendingPathComponent(workspaceID?.uuidString ?? "Unassigned", isDirectory: true)
                .appendingPathComponent("StringTables", isDirectory: true)
        return try pathResolver.paths(
            relativeSourcePath: page.relativeSourcePath ?? page.sourceURL.lastPathComponent,
            outputDirectoryURL: root
        ).stringTableURL
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
        options = context.options
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
            pages: pages
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
    case textModelRequired
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
        case .textModelRequired: "翻譯前必須先載入 imageToText 模型。"
        case .outputDirectoryRequired: "合成前必須設定輸出目錄。"
        case .outputInsideSource: "輸出目錄不可等於來源目錄或位於來源目錄內。"
        case .outputWouldOverwriteSource: "輸出路徑會覆寫來源圖片。"
        case let .resourceNotFound(uri): "找不到 MCP resource：\(uri)"
        case let .invalidArguments(message): message
        }
    }
}
