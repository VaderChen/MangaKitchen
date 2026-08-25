import Foundation
import MangaKitchenCore

/// 將頁面產物是否完整的判斷集中於 Application 層，避免 GUI、MCP 與未來 CLI
/// 各自維護一套容易分歧的工作流程規則。
public enum WorkflowArtifactState {
    public static func hasMaskData(in page: ComicPage) -> Bool {
        guard let maskURL = page.maskURL,
              let backgroundURL = page.backgroundURL else { return false }
        return exists(maskURL) && exists(backgroundURL)
    }

    public static func hasTranslationData(
        in page: ComicPage,
        requiresRegions: Bool
    ) -> Bool {
        if requiresRegions && page.regions.isEmpty { return false }
        guard let previewURL = page.translationPreviewURL,
              exists(previewURL) else { return false }
        return page.regions.isEmpty || hasTranslatedRegions(in: page)
    }

    /// 步驟四只要求步驟三預覽已存在；個別空白區域由互動層警告，不阻擋其他區域輸出。
    public static func hasTranslationPreview(in page: ComicPage) -> Bool {
        guard let previewURL = page.translationPreviewURL else { return false }
        return exists(previewURL)
    }

    public static func hasCompletedOutput(in page: ComicPage) -> Bool {
        guard page.stage == .completed,
              let outputURL = page.outputURL else { return false }
        return exists(outputURL)
    }

    public static func hasColorizationPreview(in page: ComicPage) -> Bool {
        guard let previewURL = page.colorizationPreviewURL else { return false }
        return exists(previewURL)
    }

    public static func hasCompletedColorizationOutput(in page: ComicPage) -> Bool {
        guard let outputURL = page.colorizationOutputURL else { return false }
        return exists(outputURL)
    }

    /// 依磁碟上的既有產物恢復最穩定的工作階段。上色與翻譯共用同一套優先序，
    /// 避免 MCP 同步後把 App 已完成的上色頁面降回較早階段。
    public static func completedStage(for page: ComicPage) -> PageProcessingStage {
        if hasCompletedColorizationOutput(in: page) { return .completed }
        if hasColorizationPreview(in: page) { return .translationReady }
        if let outputURL = page.outputURL, exists(outputURL) { return .completed }
        if hasTranslationPreview(in: page) { return .translationReady }
        if hasMaskData(in: page) { return .maskReady }
        return .scanned
    }

    public static func hasTranslatedRegions(in page: ComicPage) -> Bool {
        guard !page.regions.isEmpty else { return false }
        return page.regions.allSatisfy {
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
