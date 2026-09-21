import Foundation
import MangaKitchenCore

public actor ComicStringTableRepository {
    public init() {}

    public func load(from fileURL: URL) throws -> ComicStringTable? {
        try RecoverableFile.load(from: fileURL, decode: decode)
    }

    public func save(_ table: ComicStringTable, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(table)
        try RecoverableFile.save(data, to: fileURL) { _ = try decode($0) }
    }

    private func decode(_ data: Data) throws -> ComicStringTable {
        let version = try RecoverableFile.schemaVersion(in: data) ?? 1
        guard version == 1 else {
            throw ComicStringTableRepositoryError.unsupportedSchema(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ComicStringTable.self, from: data)
        guard value.schemaVersion == 1 else {
            throw ComicStringTableRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

public enum ComicStringTableRepositoryError: LocalizedError, Sendable, NonRecoverableFileError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支援 .str 資料版本：\(version)"
        }
    }
}
