import Foundation

/// 所有入口共用的來源／輸出路徑安全規則。
public enum OutputDirectoryPolicy {
    public static func isInsideSource(_ output: URL, source: URL) -> Bool {
        let sourcePath = source.standardizedFileURL.path
        let outputPath = output.standardizedFileURL.path
        return outputPath == sourcePath || outputPath.hasPrefix(sourcePath + "/")
    }

    public static func wouldOverwriteSource(_ output: URL, source: URL) -> Bool {
        output.standardizedFileURL == source.standardizedFileURL
    }
}
