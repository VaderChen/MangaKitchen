import Foundation

/// 逐段解析符號連結，包括尚未建立的輸出檔與 dangling link。
public enum FilePathBoundary {
    public static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL, !url.path.contains("\0") else { return nil }
        return resolve(url, remainingLinks: 40)
    }

    private static func resolve(_ url: URL, remainingLinks: Int) -> URL? {
        guard remainingLinks > 0 else { return nil }
        let components = url.pathComponents.dropFirst()
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            if component == "." { continue }
            if component == ".." { current.deleteLastPathComponent(); continue }
            current.appendPathComponent(component)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
                var redirected = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : current.deletingLastPathComponent().appendingPathComponent(destination)
                for tail in components.dropFirst(index + 1) { redirected.appendPathComponent(tail) }
                return resolve(redirected, remainingLinks: remainingLinks - 1)
            }
        }
        // 不再交給 Foundation standardize：macOS 會依檔案是否存在，選擇性把
        // /private/var 折回 /var，造成同一棵目錄的新檔與既有根目錄比較失敗。
        return current
    }

    public static func contains(_ child: URL, in root: URL, allowEqual: Bool = false) -> Bool {
        guard let child = canonicalURL(child), let root = canonicalURL(root) else { return false }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return (allowEqual && child.path == root.path)
            || (child.path != root.path && child.path.hasPrefix(prefix))
    }
}
