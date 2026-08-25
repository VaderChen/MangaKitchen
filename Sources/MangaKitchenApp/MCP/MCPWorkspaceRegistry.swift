import Foundation
import MangaKitchenCore

/// MCP 服務可切換的工作區快照。
struct MCPWorkspaceContext: Sendable {
    var id: UUID
    var name: String
    var sourceDirectoryURL: URL
    var outputDirectoryURL: URL?
    var options: ProcessingOptions
    var glossary: ProjectGlossary
    var pages: [ComicPage]
    var regionSource: MCPRegionSource
}

/// 管理多工作區索引與查找；工作流服務只負責載入／儲存目前作用中的快照。
struct MCPWorkspaceRegistry {
    private var contexts: [UUID: MCPWorkspaceContext] = [:]

    var all: [MCPWorkspaceContext] {
        Array(contexts.values)
    }

    func context(for id: UUID) -> MCPWorkspaceContext? {
        contexts[id]
    }

    func context(sourceDirectoryURL: URL) -> MCPWorkspaceContext? {
        let normalizedURL = sourceDirectoryURL.standardizedFileURL
        return contexts.values.first {
            $0.sourceDirectoryURL.standardizedFileURL == normalizedURL
        }
    }

    func name(for id: UUID) -> String? {
        contexts[id]?.name
    }

    mutating func save(_ context: MCPWorkspaceContext) {
        contexts[context.id] = context
    }
}
