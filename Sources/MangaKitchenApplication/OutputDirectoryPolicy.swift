import Foundation
import MangaKitchenCore

/// 所有入口共用的來源／輸出路徑安全規則。
public enum OutputDirectoryPolicy {
    public static func isInsideSource(_ output: URL, source: URL) -> Bool {
        guard let sourcePath = FilePathBoundary.canonicalURL(source)?.path,
              let outputPath = FilePathBoundary.canonicalURL(output)?.path else { return true }
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        return outputPath == sourcePath || outputPath.hasPrefix(prefix)
    }

    public static func wouldOverwriteSource(_ output: URL, source: URL) -> Bool {
        guard let output = FilePathBoundary.canonicalURL(output),
              let source = FilePathBoundary.canonicalURL(source) else { return true }
        return output.path == source.path
    }
}
