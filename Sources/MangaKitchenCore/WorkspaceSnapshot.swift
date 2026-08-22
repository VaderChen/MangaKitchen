import Foundation

/// 單一漫畫目錄的完整專案快照。名稱沿用 WorkspaceSnapshot 以相容既有檔案。
public struct WorkspaceSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var projectID: UUID
    public var name: String
    public var createdAt: Date
    public var savedAt: Date
    public var options: ProcessingOptions
    public var glossary: ProjectGlossary
    public var pages: [ComicPage]
    /// 中央畫布目前顯示的單頁。
    public var selectedPageID: UUID?
    /// 準備套用批次命令的頁面集合。
    public var selectedPageIDs: Set<UUID>
    public var modelDirectories: [URL]
    public var sourceDirectoryURL: URL?
    public var outputDirectoryURL: URL?
    /// 使用者從專案移除、但不刪除來源檔案的相對路徑。
    public var excludedSourceRelativePaths: Set<String>

    public init(
        schemaVersion: Int = 4,
        projectID: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        savedAt: Date = Date(),
        options: ProcessingOptions,
        glossary: ProjectGlossary = ProjectGlossary(),
        pages: [ComicPage],
        selectedPageID: UUID?,
        selectedPageIDs: Set<UUID> = [],
        modelDirectories: [URL],
        sourceDirectoryURL: URL? = nil,
        outputDirectoryURL: URL? = nil,
        excludedSourceRelativePaths: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.name = name
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.options = options
        self.glossary = glossary
        self.pages = pages
        self.selectedPageID = selectedPageID
        self.selectedPageIDs = selectedPageIDs
        self.modelDirectories = modelDirectories
        self.sourceDirectoryURL = sourceDirectoryURL
        self.outputDirectoryURL = outputDirectoryURL
        self.excludedSourceRelativePaths = excludedSourceRelativePaths
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID
        case name
        case createdAt
        case savedAt
        case options
        case glossary
        case pages
        case selectedPageID
        case selectedPageIDs
        case modelDirectories
        case sourceDirectoryURL
        case outputDirectoryURL
        case excludedSourceRelativePaths
    }

    /// schema 1 沒有專案識別與複選欄位，讀入時自動補齊供遷移使用。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        savedAt = try values.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? savedAt
        options = try values.decode(ProcessingOptions.self, forKey: .options)
        glossary = try values.decodeIfPresent(ProjectGlossary.self, forKey: .glossary)
            ?? ProjectGlossary()
        pages = try values.decode([ComicPage].self, forKey: .pages)
        selectedPageID = try values.decodeIfPresent(UUID.self, forKey: .selectedPageID)
        selectedPageIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .selectedPageIDs)
            ?? Set(selectedPageID.map { [$0] } ?? [])
        modelDirectories = try values.decodeIfPresent([URL].self, forKey: .modelDirectories) ?? []
        sourceDirectoryURL = try values.decodeIfPresent(URL.self, forKey: .sourceDirectoryURL)
        outputDirectoryURL = try values.decodeIfPresent(URL.self, forKey: .outputDirectoryURL)
        excludedSourceRelativePaths = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .excludedSourceRelativePaths
        ) ?? []
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? sourceDirectoryURL?.lastPathComponent
            ?? "未命名專案"
    }
}

public struct ComicProjectSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceDirectoryURL: URL
    public var outputDirectoryURL: URL?
    public var pageCount: Int
    public var completedPageCount: Int
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        sourceDirectoryURL: URL,
        outputDirectoryURL: URL?,
        pageCount: Int,
        completedPageCount: Int,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceDirectoryURL = sourceDirectoryURL
        self.outputDirectoryURL = outputDirectoryURL
        self.pageCount = pageCount
        self.completedPageCount = completedPageCount
        self.updatedAt = updatedAt
    }
}

public enum BatchOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case detectMasks
    case translate
    case extractText
    case retranslate
    case superResolve
    case compose
    case fullPage
}

public enum BatchJobStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case running
    case completed
    case completedWithErrors
    case cancelled
}

public struct BatchPageFailure: Codable, Hashable, Sendable {
    public var pageID: UUID
    public var message: String

    public init(pageID: UUID, message: String) {
        self.pageID = pageID
        self.message = message
    }
}

public struct BatchJob: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var projectName: String
    public var operation: BatchOperation
    public var forceRecalculation: Bool
    public var pageIDs: [UUID]
    public var status: BatchJobStatus
    public var currentPageID: UUID?
    public var completedPageIDs: [UUID]
    public var failures: [BatchPageFailure]
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        projectName: String,
        operation: BatchOperation,
        forceRecalculation: Bool = false,
        pageIDs: [UUID],
        status: BatchJobStatus = .queued,
        currentPageID: UUID? = nil,
        completedPageIDs: [UUID] = [],
        failures: [BatchPageFailure] = [],
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.operation = operation
        self.forceRecalculation = forceRecalculation
        self.pageIDs = pageIDs
        self.status = status
        self.currentPageID = currentPageID
        self.completedPageIDs = completedPageIDs
        self.failures = failures
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case projectName
        case operation
        case forceRecalculation
        case pageIDs
        case status
        case currentPageID
        case completedPageIDs
        case failures
        case createdAt
        case startedAt
        case finishedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        projectName = try values.decode(String.self, forKey: .projectName)
        operation = try values.decode(BatchOperation.self, forKey: .operation)
        forceRecalculation = try values.decodeIfPresent(Bool.self, forKey: .forceRecalculation) ?? false
        pageIDs = try values.decode([UUID].self, forKey: .pageIDs)
        status = try values.decode(BatchJobStatus.self, forKey: .status)
        currentPageID = try values.decodeIfPresent(UUID.self, forKey: .currentPageID)
        completedPageIDs = try values.decode([UUID].self, forKey: .completedPageIDs)
        failures = try values.decode([BatchPageFailure].self, forKey: .failures)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    public var progress: Double {
        guard !pageIDs.isEmpty else { return 0 }
        return Double(completedPageIDs.count + failures.count) / Double(pageIDs.count)
    }
}

public struct ProjectLibrarySnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var activeProjectID: UUID?
    public var projects: [ComicProjectSummary]
    public var jobs: [BatchJob]

    public init(
        schemaVersion: Int = 1,
        activeProjectID: UUID?,
        projects: [ComicProjectSummary],
        jobs: [BatchJob] = []
    ) {
        self.schemaVersion = schemaVersion
        self.activeProjectID = activeProjectID
        self.projects = projects
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeProjectID
        case projects
        case jobs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        activeProjectID = try values.decodeIfPresent(UUID.self, forKey: .activeProjectID)
        projects = try values.decodeIfPresent([ComicProjectSummary].self, forKey: .projects) ?? []
        jobs = try values.decodeIfPresent([BatchJob].self, forKey: .jobs) ?? []
    }
}
