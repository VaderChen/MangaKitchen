import Foundation
import MangaKitchenCore

struct WebPage: Encodable {
    var id: UUID
    var index: Int
    var title: String
    var pixelWidth: Int
    var pixelHeight: Int
    var sourcePreviewURL: String
    var maskPreviewURL: String?
    var outputPreviewURL: String?
    var relativeSourcePath: String?
    var stringTablePath: String?
    var regions: [DialogueRegion]
    var stage: PageProcessingStage
    var progress: Double
    var errorMessage: String?

    init(page: ComicPage) {
        id = page.id
        index = page.index
        title = page.title
        pixelWidth = page.pixelWidth
        pixelHeight = page.pixelHeight
        sourcePreviewURL = "mangakitchen-asset://\(page.id.uuidString.lowercased())/source"
        maskPreviewURL = page.maskURL == nil
            ? nil
            : "mangakitchen-asset://\(page.id.uuidString.lowercased())/mask"
        outputPreviewURL = page.outputURL == nil
            ? nil
            : "mangakitchen-asset://\(page.id.uuidString.lowercased())/output"
        relativeSourcePath = page.relativeSourcePath
        stringTablePath = page.stringTableURL?.path
        regions = page.regions
        stage = page.stage
        progress = page.progress
        errorMessage = page.errorMessage
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
    var interfaceLanguage: String
    var colorScheme: String
    var dataDirectoryPath: String?
    var configuredDataDirectoryPath: String?
    var activeDataDirectoryPath: String?
    var dataDirectoryRestartRequired: Bool
    var imageToTextModelPath: String?
    var imageToImageModelPath: String?
    var mcpEnabled: Bool
    var mcpPort: Int
    var mcpAllowedClients: [String]
    var appVersion: String

    @MainActor
    init(preferences: AppPreferences, store: AppStore) {
        interfaceLanguage = preferences.interfaceLanguage
        colorScheme = preferences.colorScheme
        dataDirectoryPath = preferences.dataDirectoryPath
        activeDataDirectoryPath = store.applicationDataDirectoryPath
        configuredDataDirectoryPath = preferences.dataDirectoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(ApplicationDirectories.currentName, isDirectory: true)
            .standardizedFileURL.path
        dataDirectoryRestartRequired = configuredDataDirectoryPath != store.applicationDataDirectoryPath
        imageToTextModelPath = preferences.imageToTextModelPath
        imageToImageModelPath = preferences.imageToImageModelPath
        mcpEnabled = preferences.mcpEnabled
        mcpPort = preferences.mcpPort
        mcpAllowedClients = preferences.mcpAllowedClients
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
    }
}

struct WebAppState: Encodable {
    var schemaVersion = 4
    var globalSettings: WebGlobalSettings
    var projects: [WebProject]
    var activeProjectID: UUID?
    var activeProjectName: String?
    var pages: [WebPage]
    var selectedPageID: UUID?
    var selectedPageIDs: [UUID]
    var options: ProcessingOptions
    var loadedModels: [LoadedModelInfo]
    var glossary: [WebGlossaryEntry]
    var batchJobs: [WebBatchJob]
    var sourceDirectoryPath: String?
    var outputDirectoryPath: String?
    var isProcessing: Bool
    var isSwitchingProject: Bool
    var statusMessage: String?

    @MainActor
    init(store: AppStore, preferences: AppPreferences) {
        globalSettings = WebGlobalSettings(preferences: preferences, store: store)
        projects = store.projects.map(WebProject.init)
        activeProjectID = store.activeProjectID
        activeProjectName = store.activeProjectName
        pages = store.pages.map(WebPage.init)
        selectedPageID = store.selectedPageID
        selectedPageIDs = store.pages.lazy.map(\.id).filter(store.selectedPageIDs.contains)
        options = store.options
        loadedModels = store.loadedModels
        glossary = store.glossary.entries.map {
            WebGlossaryEntry(entry: $0, targetLanguageCode: store.options.targetLanguageCode)
        }
        batchJobs = store.batchJobs.map { WebBatchJob(job: $0, pages: store.pages) }
        sourceDirectoryPath = store.sourceDirectoryURL?.path
        outputDirectoryPath = store.outputDirectoryURL?.path
        isProcessing = store.isProcessing
        isSwitchingProject = store.isSwitchingProject
        statusMessage = store.statusMessage
    }
}
