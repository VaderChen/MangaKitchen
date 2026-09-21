import Foundation

/// 與網路／檔案操作分離的下載契約，方便在離線測試重現不一致的 metadata。
enum ModelDownloadValidation {
    static func pinnedRevision(_ revision: String?, previous: String? = nil) throws -> String {
        guard let revision, revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              previous == nil || previous == revision else { throw Failure.invalidRevision }
        return revision
    }

    static func totalByteCount(_ counts: [Int64]) throws -> Int64 {
        try counts.reduce(0) { total, count in
            let result = total.addingReportingOverflow(count)
            guard count >= 0, !result.overflow else { throw Failure.invalidSize }
            return result.partialValue
        }
    }

    static func acceptsResponse(
        statusCode: Int, contentRange: String?, start: Int64, end: Int64,
        total: Int64, usesRange: Bool
    ) -> Bool {
        guard start >= 0, end >= start, total > end else { return false }
        if usesRange {
            return statusCode == 206
                && contentRange?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == "bytes \(start)-\(end)/\(total)"
        }
        return statusCode == 200 && start == 0 && end == total - 1
    }

    private enum Failure: LocalizedError {
        case invalidRevision, invalidSize
        var errorDescription: String? {
            switch self {
            case .invalidRevision: "模型檔案缺少固定版本，或 repository 在下載期間出現不一致版本。"
            case .invalidSize: "模型檔案大小無效或總大小超出支援範圍。"
            }
        }
    }
}
