import AppKit
import Foundation
import ImageIO
import MangaKitchenCore

struct WebPage: Encodable {
    var id: UUID
    var index: Int
    var title: String
    var pixelWidth: Int
    var pixelHeight: Int
    var sourcePreviewURL: String
    var maskPreviewURL: String?
    var maskRevision: UInt64?
    var maskAppliedPreviewURL: String?
    var superResolvedBackgroundPreviewURL: String?
    var superResolutionApplied: Bool
    var superResolutionScale: Double
    var superResolutionPixelWidth: Int?
    var superResolutionPixelHeight: Int?
    var translationPreviewURL: String?
    var outputPreviewURL: String?
    var relativeSourcePath: String?
    var stringTablePath: String?
    var regions: [DialogueRegion]
    var maskRedoRegionIDs: [UUID]
    var stage: PageProcessingStage
    var progress: Double
    var processingActivity: PageProcessingActivity?
    var processingRegionIndex: Int?
    var processingRegionCount: Int?
    var errorMessage: String?

    init(
        page: ComicPage,
        maskRevision: UInt64 = 0,
        maskRedoRegionIDs: [UUID] = [],
        processingActivity: PageProcessingActivity? = nil,
        processingRegionProgress: ProcessingRegionProgress? = nil
    ) {
        let maskURL = Self.existingFileURL(page.maskURL)
        let backgroundURL = Self.existingFileURL(page.backgroundURL)
        let superResolvedBackgroundURL = Self.existingFileURL(page.superResolvedBackgroundURL)
        let superResolvedDimensions = superResolvedBackgroundURL.flatMap(Self.pixelDimensions)
        let translationPreviewFileURL = Self.existingFileURL(page.translationPreviewURL)
        let outputURL = Self.existingFileURL(page.outputURL)
        id = page.id
        index = page.index
        title = page.title
        pixelWidth = page.pixelWidth
        pixelHeight = page.pixelHeight
        sourcePreviewURL = "mangakitchen-asset://\(page.id.uuidString.lowercased())/source"
        maskPreviewURL = maskURL == nil
            ? nil
            : "mangakitchen-asset://\(page.id.uuidString.lowercased())/mask"
        self.maskRevision = maskURL == nil ? nil : maskRevision
        maskAppliedPreviewURL = backgroundURL == nil
            ? nil
            : "mangakitchen-asset://\(page.id.uuidString.lowercased())/background"
        superResolvedBackgroundPreviewURL = superResolvedBackgroundURL.map {
            let revision = Self.modificationTimestamp(for: $0) ?? 0
            return "mangakitchen-asset://\(page.id.uuidString.lowercased())/background-2x?updated=\(revision)"
        }
        superResolutionApplied = superResolvedBackgroundURL != nil
        superResolutionScale = superResolvedDimensions.map { dimensions in
            min(
                Double(dimensions.width) / Double(max(1, page.pixelWidth)),
                Double(dimensions.height) / Double(max(1, page.pixelHeight))
            )
        } ?? 1
        superResolutionPixelWidth = superResolvedDimensions?.width
        superResolutionPixelHeight = superResolvedDimensions?.height
        translationPreviewURL = translationPreviewFileURL.map {
            let revision = Self.modificationTimestamp(for: $0) ?? 0
            return "mangakitchen-asset://\(page.id.uuidString.lowercased())/translation-preview?updated=\(revision)"
        }
        outputPreviewURL = outputURL.map {
            let revision = Self.modificationTimestamp(for: $0) ?? 0
            return "mangakitchen-asset://\(page.id.uuidString.lowercased())/output?updated=\(revision)"
        }
        relativeSourcePath = page.relativeSourcePath
        stringTablePath = page.stringTableURL?.path
        regions = page.regions
        self.maskRedoRegionIDs = maskRedoRegionIDs
        stage = page.stage
        progress = page.progress
        self.processingActivity = processingActivity
        processingRegionIndex = processingRegionProgress?.current
        processingRegionCount = processingRegionProgress?.total
        errorMessage = page.errorMessage
    }

    private static func existingFileURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    private static func modificationTimestamp(for url: URL?) -> TimeInterval? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private static func pixelDimensions(for url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}

struct WebProject: Encodable {
    var id: UUID
    var name: String
    var sourceDirectoryPath: String
    var outputDirectoryPath: String?
    var pageCount: Int
    var completedPageCount: Int
    var updatedAt: Date

    init(project: ComicProjectSummary) {
        id = project.id
        name = project.name
        sourceDirectoryPath = project.sourceDirectoryURL.path
        outputDirectoryPath = project.outputDirectoryURL?.path
        pageCount = project.pageCount
        completedPageCount = project.completedPageCount
        updatedAt = project.updatedAt
    }
}

struct WebBatchFailure: Encodable {
    var pageID: UUID
    var pageTitle: String
    var message: String
}

struct WebBatchJob: Encodable {
    var id: UUID
    var projectID: UUID
    var projectName: String
    var operation: BatchOperation
    var status: BatchJobStatus
    var pageIDs: [UUID]
    var pageCount: Int
    var completedCount: Int
    var failureCount: Int
    var currentPageID: UUID?
    var currentPageTitle: String?
    var progress: Double
    var failures: [WebBatchFailure]

    init(job: BatchJob, pages: [ComicPage]) {
        let pageNames = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.title) })
        id = job.id
        projectID = job.projectID
        projectName = job.projectName
        operation = job.operation
        status = job.status
        pageIDs = job.pageIDs
        pageCount = job.pageIDs.count
        completedCount = job.completedPageIDs.count
        failureCount = job.failures.count
        currentPageID = job.currentPageID
        currentPageTitle = job.currentPageID.flatMap { pageNames[$0] }
        progress = job.progress
        failures = job.failures.map {
            WebBatchFailure(
                pageID: $0.pageID,
                pageTitle: pageNames[$0.pageID] ?? $0.pageID.uuidString,
                message: $0.message
            )
        }
    }
}

struct WebGlossaryEntry: Encodable {
    var id: UUID
    var sourceTerm: String
    var translations: [String: String]
    var note: String?
    var currentTranslation: String?

    init(entry: GlossaryEntry, targetLanguageCode: String) {
        id = entry.id
        sourceTerm = entry.sourceTerm
        translations = entry.translations
        note = entry.note
        currentTranslation = entry.translation(for: targetLanguageCode)
    }
}

struct WebGlobalSettings: Encodable {
    struct ModelOption: Encodable {
        var id: String
        var displayName: String
        var recommended: Bool
        var installed: Bool
    }

    var interfaceLanguage: String
    var colorScheme: String
    var selectionColorHex: String
    var dataDirectoryPath: String?
    var configuredDataDirectoryPath: String?
    var defaultOutputDirectoryPath: String?
    var activeDataDirectoryPath: String?
    var dataDirectoryRestartRequired: Bool
    var imageCompositingBackend: ImageCompositingBackend
    var imageToTextModelPath: String?
    var imageToTextModelDownloadDirectoryPath: String?
    var imageToTextModelVariant: String
    var imageToTextModelOptions: [ModelOption]
    var imageToTextModelInstalled: Bool
    var modelDownloadState: ModelDownloadState?
    var imageToImageModelPath: String?
    var automaticSuperResolutionEnabled: Bool
    var superResolutionModelPath: String?
    var superResolutionModelDownloadDirectoryPath: String?
    var superResolutionModelVariant: String
    var superResolutionModelOptions: [ModelOption]
    var superResolutionModelInstalled: Bool
    var mcpEnabled: Bool
    var mcpPort: Int
    var mcpEndpointURL: String?
    var mcpAllowedClients: [String]
    var appVersion: String

    @MainActor
    init(
        preferences: AppPreferences,
        store: AppStore,
        mcpController: MCPServiceController
    ) {
        interfaceLanguage = preferences.interfaceLanguage
        colorScheme = preferences.colorScheme
        selectionColorHex = preferences.selectionColorHex
        dataDirectoryPath = preferences.dataDirectoryPath
        activeDataDirectoryPath = store.applicationDataDirectoryPath
        configuredDataDirectoryPath = preferences.dataDirectoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(ApplicationDirectories.currentName, isDirectory: true)
            .standardizedFileURL.path
        dataDirectoryRestartRequired = configuredDataDirectoryPath != store.applicationDataDirectoryPath
        defaultOutputDirectoryPath = preferences.defaultOutputDirectoryPath
        imageCompositingBackend = preferences.resolvedImageCompositingBackend
        imageToTextModelPath = preferences.imageToTextModelPath
        imageToTextModelDownloadDirectoryPath = preferences.imageToTextModelDownloadDirectoryPath
        let selectedImageToTextModelVariant = preferences.resolvedImageToTextModelVariant
        imageToTextModelVariant = selectedImageToTextModelVariant
        let modelStorageDirectoryURL = preferences.imageToTextModelDownloadDirectoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        imageToTextModelOptions = DownloadableModelCatalog.imageToTextModels.map { model in
            ModelOption(
                id: model.id,
                displayName: model.displayName,
                recommended: model.recommended,
                installed: modelStorageDirectoryURL.flatMap {
                    DownloadableModelCatalog.installedModelDirectory(
                        storageDirectoryURL: $0,
                        model: model
                    )
                } != nil
            )
        }
        imageToTextModelInstalled = imageToTextModelOptions.first {
            $0.id == selectedImageToTextModelVariant
        }?.installed ?? false
        modelDownloadState = store.modelDownloadState
        imageToImageModelPath = preferences.imageToImageModelPath
        automaticSuperResolutionEnabled = preferences.automaticSuperResolutionEnabled
        superResolutionModelPath = preferences.superResolutionModelPath
        superResolutionModelDownloadDirectoryPath = preferences.superResolutionModelDownloadDirectoryPath
        let selectedSuperResolutionModelVariant = preferences.resolvedSuperResolutionModelVariant
        superResolutionModelVariant = selectedSuperResolutionModelVariant
        let superResolutionStorageURL = preferences.superResolutionModelDownloadDirectoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        superResolutionModelOptions = DownloadableModelCatalog.superResolutionModels.map { model in
            ModelOption(
                id: model.id,
                displayName: model.displayName,
                recommended: model.recommended,
                installed: superResolutionStorageURL.flatMap {
                    DownloadableModelCatalog.installedModelDirectory(
                        storageDirectoryURL: $0,
                        model: model
                    )
                } != nil
            )
        }
        superResolutionModelInstalled = superResolutionModelOptions.first {
            $0.id == selectedSuperResolutionModelVariant
        }?.installed ?? false
        mcpEnabled = preferences.mcpEnabled
        mcpPort = preferences.mcpPort
        mcpEndpointURL = mcpController.enabled
            ? mcpController.endpointURL?.absoluteString
                ?? "http://127.0.0.1:\(mcpController.port)/mcp"
            : nil
        mcpAllowedClients = preferences.mcpAllowedClients
        let marketingVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        appVersion = buildVersion.map { "\(marketingVersion) build \($0)" } ?? marketingVersion
    }
}

struct WebAppState: Encodable {
    var schemaVersion = 7
    var globalSettings: WebGlobalSettings
    var projects: [WebProject]
    var activeProjectID: UUID?
    var activeProjectName: String?
    var pages: [WebPage]
    var selectedPageID: UUID?
    var selectedPageIDs: [UUID]
    var options: ProcessingOptions
    var availableFontFamilies: [String]
    var loadedModels: [LoadedModelInfo]
    var modelLoadingState: ModelLoadingState?
    var glossary: [WebGlossaryEntry]
    var batchJobs: [WebBatchJob]
    var sourceDirectoryPath: String?
    var outputDirectoryPath: String?
    var isProcessing: Bool
    var isSwitchingProject: Bool
    var statusMessage: String?
    var availableUpdate: GitHubReleaseUpdate?

    @MainActor
    init(
        store: AppStore,
        preferences: AppPreferences,
        mcpController: MCPServiceController,
        availableUpdate: GitHubReleaseUpdate?
    ) {
        globalSettings = WebGlobalSettings(
            preferences: preferences,
            store: store,
            mcpController: mcpController
        )
        projects = store.projects.map(WebProject.init)
        activeProjectID = store.activeProjectID
        activeProjectName = store.activeProjectName
        pages = store.pages.map {
            WebPage(
                page: $0,
                maskRevision: store.maskRevision(pageID: $0.id),
                maskRedoRegionIDs: store.maskRedoRegionIDs(pageID: $0.id),
                processingActivity: store.processingActivities[$0.id],
                processingRegionProgress: store.processingRegionProgress[$0.id]
            )
        }
        selectedPageID = store.selectedPageID
        selectedPageIDs = store.pages.lazy.map(\.id).filter(store.selectedPageIDs.contains)
        options = store.options
        availableFontFamilies = FontFamilyCatalog.compatibleFamilies(
            for: store.options.resolvedTargetLanguageCode
        )
        loadedModels = store.loadedModels
        modelLoadingState = store.modelLoadingState
        glossary = store.glossary.entries.map {
            WebGlossaryEntry(entry: $0, targetLanguageCode: store.options.resolvedTargetLanguageCode)
        }
        batchJobs = store.batchJobs.map { WebBatchJob(job: $0, pages: store.pages) }
        sourceDirectoryPath = store.sourceDirectoryURL?.path
        outputDirectoryPath = store.outputDirectoryURL?.path
        isProcessing = store.isProcessing
        isSwitchingProject = store.isSwitchingProject
        statusMessage = store.statusMessage
        self.availableUpdate = availableUpdate
    }
}
