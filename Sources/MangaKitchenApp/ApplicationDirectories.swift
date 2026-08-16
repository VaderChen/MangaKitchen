import Foundation

enum ApplicationDirectories {
    static let currentName = "MangaKitchen"

    static func applicationSupportRoot(customPath: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        if let customPath {
            let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ApplicationDirectoryError.invalidCustomPath }
            let custom = URL(fileURLWithPath: trimmed).standardizedFileURL
            try fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let current = base.appendingPathComponent(currentName, isDirectory: true)
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }
}

private enum ApplicationDirectoryError: LocalizedError {
    case invalidCustomPath

    var errorDescription: String? { "自訂資料儲存位置不可為空。" }
}
