import Foundation
import MangaKitchenCore

// MCP 的翻譯一律由外部 Agent 產生：本檔的替身把管線上「需要內建圖生文模型」的
// 位置封死，讓這件事是結構上的保證，而不是靠呼叫端每次記得傳對旗標。
// 區域預設由 App 內建 Core ML 建立，只有明確切換時才由 Agent 提供粗框
//（見 MCPRegionSource）。
//
// 影像生成（imageToImage）不在此限；背景修補仍可使用已載入的圖生圖模型。

/// 區域（文字位置與原文）從哪裡來。
///
/// **翻譯不在此列**：兩種模式下譯文都固定由 Agent 以 region.update 寫入，
/// 後端永遠不會呼叫內建圖生文模型翻譯。
enum MCPRegionSource: String, Codable, Sendable, CaseIterable {
    /// 區域 BBOX 與氣泡形狀由本機 Core ML 定位；原文、翻譯與排版仍由 Agent 提供。
    case local
    /// 相容後備：區域粗框與原文由 Agent 提供；遮罩仍由後端依粗框與原圖像素產生。
    case agent
}

/// 不執行本機語意區域偵測；Agent 模式會走專用遮罩路徑，不呼叫此替身。
struct AgentDrivenRegionDetector: SemanticRegionDetecting {
    func detectRegions(
        pageURL: URL,
        sourceLanguageCodes: [String],
        fineScanEnabled: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        progress(1)
        return []
    }
}

/// 不執行 VLM 翻譯。譯文必須由 Agent 以 region.update 的 translated_text 寫入。
struct AgentDrivenTranslator: RegionTranslating {
    func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        readingDirection: ReadingDirection,
        qualityOptions: TranslationQualityOptions,
        activity: @escaping PagePipelineActivity,
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        throw MCPServiceError.agentTranslationRequired
    }
}
