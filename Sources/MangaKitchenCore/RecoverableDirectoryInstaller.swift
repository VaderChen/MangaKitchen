import Foundation

/// 目錄安裝先驗證候選，再保留舊目錄；提交失敗時復原，不先刪掉可用版本。
public enum RecoverableDirectoryInstaller {
    private static let lock = NSLock()

    public static func install(
        from staged: URL, to destination: URL, validate: (URL) throws -> Void
    ) throws {
        try lock.withLock {
            guard !FilePathBoundary.contains(staged, in: destination, allowEqual: true),
                  !FilePathBoundary.contains(destination, in: staged, allowEqual: true),
                  FilePathBoundary.canonicalURL(staged) != nil,
                  FilePathBoundary.canonicalURL(destination) != nil else {
                throw InstallationError.overlappingPaths
            }
            try Task.checkCancellation()
            try validate(staged)
            let manager = FileManager.default
            let parent = destination.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            let backup = parent.appendingPathComponent(".mangakitchen-install-backup-\(UUID().uuidString)")
            var backedUp = false
            var installed = false
            do {
                if manager.fileExists(atPath: destination.path) {
                    try manager.moveItem(at: destination, to: backup)
                    backedUp = true
                }
                try manager.moveItem(at: staged, to: destination)
                installed = true
                try validate(destination)
                try Task.checkCancellation()
            } catch {
                let installationError = error
                do {
                    if installed { try manager.moveItem(at: destination, to: staged) }
                    if backedUp { try manager.moveItem(at: backup, to: destination) }
                } catch {
                    // 不刪除任一版本；回報保留位置，讓呼叫端能安全復原。
                    throw InstallationError.rollbackFailed(backup: backup, reason: error.localizedDescription)
                }
                throw installationError
            }
            if backedUp { try? manager.removeItem(at: backup) }
        }
    }

    private enum InstallationError: LocalizedError {
        case overlappingPaths
        case rollbackFailed(backup: URL, reason: String)
        var errorDescription: String? {
            switch self {
            case .overlappingPaths: "安裝來源與目的目錄不可重疊或包含無法解析的路徑。"
            case let .rollbackFailed(backup, reason): "安裝復原失敗，舊版本保留於 \(backup.path)：\(reason)"
            }
        }
    }
}
