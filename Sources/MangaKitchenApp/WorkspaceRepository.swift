import Foundation
import MangaKitchenCore

actor WorkspaceRepository {
    private let fileURL: URL
    private let backupURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.backupURL = fileURL.appendingPathExtension("bak")
    }

    func load() throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try decode(fileURL)
        } catch {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
            return try decode(backupURL)
        }
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ url: URL) throws -> WorkspaceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(WorkspaceSnapshot.self, from: Data(contentsOf: url))
        guard (1...3).contains(value.schemaVersion) else {
            throw WorkspaceRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

actor ProjectLibraryRepository {
    private let fileURL: URL
    private let backupURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        backupURL = fileURL.appendingPathExtension("bak")
    }

    func load() throws -> ProjectLibrarySnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try decode(fileURL)
        } catch {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
            return try decode(backupURL)
        }
    }

    func save(_ snapshot: ProjectLibrarySnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ url: URL) throws -> ProjectLibrarySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ProjectLibrarySnapshot.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else {
            throw WorkspaceRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

private enum WorkspaceRepositoryError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支援工作區資料版本：\(version)"
        }
    }
}
