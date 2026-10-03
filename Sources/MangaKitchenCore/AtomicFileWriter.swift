import Darwin
import Foundation

/// 先在相同目錄完成串流輸出，再以同檔案系統的 rename 原子替換目的檔。
/// 適用 ImageIO 等不能直接使用 Data.write(.atomic) 的寫入端。
public enum AtomicFileWriter {
    /// 以固定大小的緩衝複製檔案內容，保留原子替換、符號連結來源及取消語意。
    /// 不直接 copyItem，避免把來源符號連結本身複製成輸出檔。
    public static func copy(from source: URL, to destination: URL) throws {
        try write(to: destination) { staged in
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try Data().write(to: staged, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else {
                    return false
                }
                try output.write(contentsOf: chunk)
                return true
            }) {}
            try output.close()
        }
    }

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
