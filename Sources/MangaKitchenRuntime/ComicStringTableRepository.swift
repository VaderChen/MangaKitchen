import Foundation
import MangaKitchenCore

public actor ComicStringTableRepository {
    public init() {}

    public func load(from fileURL: URL) throws -> ComicStringTable? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try decode(fileURL)
        } catch {
            let backupURL = fileURL.appendingPathExtension("bak")
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
            return try decode(backupURL)
        }
    }

    public func save(_ table: ComicStringTable, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(table)
        let fileManager = FileManager.default
        let parentURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let backupURL = fileURL.appendingPathExtension("bak")
        if fileManager.fileExists(atPath: fileURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ fileURL: URL) throws -> ComicStringTable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ComicStringTable.self, from: Data(contentsOf: fileURL))
        guard value.schemaVersion == 1 else {
            throw ComicStringTableRepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }
}

public enum ComicStringTableRepositoryError: LocalizedError, Sendable {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支援 .str 資料版本：\(version)"
        }
    }
}
