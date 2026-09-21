import Foundation

/// 解壓工具的共用執行邊界：持續排空 stderr，僅保留有界診斷資料。
enum ArchiveProcessRunner {
    struct Result {
        let terminationStatus: Int32
        let diagnostic: String
    }

    static func run(executableURL: URL, arguments: [String]) throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        defer { try? errors.fileHandleForReading.close() }
        try process.run()
        // 必須在 waitUntilExit 前讀取；否則子程序可能卡在已滿的 pipe。
        var diagnostic = Data()
        let limit = 64 * 1024
        while true {
            let chunk = errors.fileHandleForReading.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            diagnostic.append(chunk.prefix(max(0, limit - diagnostic.count)))
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        return Result(
            terminationStatus: process.terminationStatus,
            diagnostic: String(decoding: diagnostic, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
