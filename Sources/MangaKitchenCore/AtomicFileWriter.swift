import Darwin
import Foundation

/// 先在相同目錄完成串流輸出，再以同檔案系統的 rename 原子替換目的檔。
/// 適用 ImageIO 等不能直接使用 Data.write(.atomic) 的寫入端。
public enum AtomicFileWriter {
    public static func write(to destination: URL, using writer: (URL) throws -> Void) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".mangakitchen-write-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        try writer(staged)
        try Task.checkCancellation()
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
