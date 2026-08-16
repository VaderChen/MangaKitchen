import Foundation
import ImageIO
import MangaKitchenCore

public struct ScannedComicPage: Hashable, Sendable {
    public var sourceURL: URL
    public var relativePath: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(sourceURL: URL, relativePath: String, pixelWidth: Int, pixelHeight: Int) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 遞迴掃描來源目錄並以相對路徑做自然排序。
public struct ComicDirectoryScanner: Sendable {
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"
    ]

    public init() {}

    public func scan(_ directoryURL: URL) throws -> [ScannedComicPage] {
        let root = directoryURL.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ComicDirectoryScannerError.cannotReadDirectory(root)
        }

        var pages: [ScannedComicPage] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true,
                  Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()),
                  let dimensions = dimensions(at: fileURL) else { continue }
            pages.append(ScannedComicPage(
                sourceURL: fileURL.standardizedFileURL,
                relativePath: relativePath(of: fileURL, under: root),
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height
            ))
        }

        return pages.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count))
    }

    private func dimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }
}

public enum ComicDirectoryScannerError: LocalizedError, Sendable {
    case cannotReadDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case let .cannotReadDirectory(url): "無法讀取漫畫來源目錄：\(url.path)"
        }
    }
}
