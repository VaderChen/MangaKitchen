import Foundation

public struct WorkflowPagePaths: Hashable, Sendable {
    public var stringTableURL: URL
    public var outputURL: URL

    public init(stringTableURL: URL, outputURL: URL) {
        self.stringTableURL = stringTableURL
        self.outputURL = outputURL
    }
}

public struct WorkflowPathResolver: Sendable {
    public init() {}

    public func paths(
        sourceURL: URL,
        relativeSourcePath: String,
        outputDirectoryURL: URL
    ) throws -> WorkflowPagePaths {
        WorkflowPagePaths(
            stringTableURL: stringTableURL(for: sourceURL),
            outputURL: try outputURL(
                relativeSourcePath: relativeSourcePath,
                outputDirectoryURL: outputDirectoryURL
            )
        )
    }

    /// `.str` 是原圖的 sidecar，永遠與原圖同目錄且共用檔名主體。
    public func stringTableURL(for sourceURL: URL) -> URL {
        sourceURL.deletingPathExtension().appendingPathExtension("str")
    }

    public func outputURL(
        relativeSourcePath: String,
        outputDirectoryURL: URL
    ) throws -> URL {
        let safeComponents = try validatedComponents(relativeSourcePath)
        let relativeURL = safeComponents.reduce(outputDirectoryURL) {
            $0.appendingPathComponent($1)
        }
        let baseURL = relativeURL.deletingPathExtension()
        return baseURL.appendingPathExtension("png")
    }

    private func validatedComponents(_ path: String) throws -> [String] {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              !path.hasPrefix("/"),
              !components.contains("."),
              !components.contains("..") else {
            throw WorkflowPathResolverError.invalidRelativePath(path)
        }
        return components
    }
}

public enum WorkflowPathResolverError: LocalizedError, Sendable {
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): "不安全的來源相對路徑：\(path)"
        }
    }
}
