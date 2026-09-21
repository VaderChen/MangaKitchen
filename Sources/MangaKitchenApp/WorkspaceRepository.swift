import Foundation
import MangaKitchenCore

actor WorkspaceRepository {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> WorkspaceSnapshot? {
        try RecoverableFile.load(from: fileURL, decode: decode)
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)

        try RecoverableFile.save(data, to: fileURL) { _ = try decode($0) }
    }

    private func decode(_ data: Data) throws -> WorkspaceSnapshot {
        let version = try RecoverableFile.schemaVersion(in: data) ?? 1
        guard (1...4).contains(version) else {
            throw WorkspaceRepositoryError.unsupportedSchema(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(WorkspaceSnapshot.self, from: data)
        guard (1...4).contains(value.schemaVersion) else {
            throw WorkspaceRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

actor ProjectLibraryRepository {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> ProjectLibrarySnapshot? {
        try RecoverableFile.load(from: fileURL, decode: decode)
    }

    func save(_ snapshot: ProjectLibrarySnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)

        try RecoverableFile.save(data, to: fileURL) { _ = try decode($0) }
    }

    private func decode(_ data: Data) throws -> ProjectLibrarySnapshot {
        let version = try RecoverableFile.schemaVersion(in: data) ?? 1
        guard version == 1 else {
            throw WorkspaceRepositoryError.unsupportedSchema(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ProjectLibrarySnapshot.self, from: data)
        guard value.schemaVersion == 1 else {
            throw WorkspaceRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

private enum WorkspaceRepositoryError: LocalizedError, NonRecoverableFileError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支援工作區資料版本：\(version)"
        }
    }
}
