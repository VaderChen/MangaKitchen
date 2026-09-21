import Foundation
import MangaKitchenCore

/// GUI 與 MCP 共用的掃描合併。先保留精確匹配，再處理無歧義的檔案搬移。
public enum ComicPageScanMerger {
    public static func merge(
        _ scanned: [ScannedComicPage],
        previousPages: [ComicPage],
        excludedRelativePaths: Set<String> = []
    ) -> [ComicPage] {
        var seenPaths: Set<String> = []
        let items = scanned.filter {
            !excludedRelativePaths.contains($0.relativePath)
                && seenPaths.insert($0.sourceURL.standardizedFileURL.path).inserted
        }
        var seenIDs: Set<UUID> = []
        let previous = previousPages.filter { seenIDs.insert($0.id).inserted }
        let byPath = Dictionary(grouping: previous) { $0.sourceURL.standardizedFileURL.path }
        let byRelative = Dictionary(grouping: previous.filter { $0.relativeSourcePath != nil }) {
            $0.relativeSourcePath!
        }
        var matched: [Int: ComicPage] = [:]
        var reused: Set<UUID> = []
        // 分開兩輪：相對路徑或檔名 fallback 不能搶走後面檔案的精確匹配。
        for index in items.indices {
            if let candidates = byPath[items[index].sourceURL.standardizedFileURL.path],
               candidates.count == 1, let page = candidates.first, reused.insert(page.id).inserted {
                matched[index] = page
            }
        }
        for index in items.indices where matched[index] == nil {
            if let candidates = byRelative[items[index].relativePath],
               candidates.count == 1, let page = candidates.first, reused.insert(page.id).inserted {
                matched[index] = page
            }
        }
        let oldMoves = Dictionary(grouping: previous.filter { !reused.contains($0.id) }) {
            fingerprint($0.sourceURL, width: $0.pixelWidth, height: $0.pixelHeight)
        }
        let newMoves = Dictionary(grouping: items.indices.filter { matched[$0] == nil }) {
            fingerprint(items[$0].sourceURL, width: items[$0].pixelWidth, height: items[$0].pixelHeight)
        }
        for (key, indices) in newMoves where indices.count == 1 {
            guard let candidates = oldMoves[key], candidates.count == 1,
                  let page = candidates.first, let index = indices.first else { continue }
            matched[index] = page
        }
        let previousOrder = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
        var result = items.enumerated().map { offset, item in
            var page = matched[offset] ?? ComicPage(
                index: offset + 1,
                title: item.sourceURL.deletingPathExtension().lastPathComponent,
                sourceURL: item.sourceURL,
                relativeSourcePath: item.relativePath,
                pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, stage: .scanned
            )
            page.sourceURL = item.sourceURL
            page.relativeSourcePath = item.relativePath
            page.pixelWidth = item.pixelWidth
            page.pixelHeight = item.pixelHeight
            if page.stage == .pending { page.stage = .scanned }
            return (page: page, scannedIndex: offset)
        }
        result.sort {
            let left = previousOrder[$0.page.id]
            let right = previousOrder[$1.page.id]
            switch (left, right) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0.scannedIndex < $1.scannedIndex
            }
        }
        return result.enumerated().map { offset, item in
            var page = item.page
            page.index = offset + 1
            return page
        }
    }

    private static func fingerprint(_ url: URL, width: Int, height: Int) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return "\(filename)|\(width)x\(height)"
    }
}
