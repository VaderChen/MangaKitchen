import Foundation

/// 表示資料本身可能健康，只是目前程式不能安全解讀；不可用舊備份掩蓋。
public protocol NonRecoverableFileError: Error {}

/// 主檔與備份共用的原子保存策略；僅以可解碼的舊版本更新備份。
public enum RecoverableFile {
    // GUI 與 MCP 可能持有不同 repository actor，仍必須序列化檔案交易。
    private static let lock = NSLock()

    public static func load<Value>(
        from url: URL,
        decode: (Data) throws -> Value
    ) throws -> Value? {
        try lock.withLock {
            try Task.checkCancellation()
            let backup = url.appendingPathExtension("bak")
            guard FileManager.default.fileExists(atPath: url.path) else {
                guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
                return try decode(Data(contentsOf: backup))
            }
            do {
                return try decode(Data(contentsOf: url))
            } catch {
                guard !(error is any NonRecoverableFileError) else { throw error }
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
                return try decode(Data(contentsOf: backup))
            }
        }
    }

    public static func save(
        _ data: Data,
        to url: URL,
        validate: (Data) throws -> Void
    ) throws {
        try lock.withLock {
            try Task.checkCancellation()
            try validate(data)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                // 讀取權限或 I/O 錯誤不可視為壞 JSON，否則可能覆蓋不可讀的健康主檔。
                let previous = try Data(contentsOf: url)
                var valid = true
                do { try validate(previous) }
                catch {
                    guard !(error is any NonRecoverableFileError) else { throw error }
                    valid = false
                }
                if valid {
                    try Task.checkCancellation()
                    try previous.write(to: url.appendingPathExtension("bak"), options: .atomic)
                }
            }
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }
    }

    /// 在解碼完整內容前檢查版本，避免新版欄位不相容被誤當作 JSON 損壞。
    public static func schemaVersion(in data: Data) throws -> Int? {
        struct Header: Decodable { var schemaVersion: Int? }
        return try JSONDecoder().decode(Header.self, from: data).schemaVersion
    }
}
