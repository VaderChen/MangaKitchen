import Foundation
import MangaKitchenCore

// MCP 的翻譯一律由外部 Agent 產生：本檔的替身把管線上「需要內建圖生文模型」的
// 位置封死，讓這件事是結構上的保證，而不是靠呼叫端每次記得傳對旗標。
// 區域來源則可切換（見 MCPRegionSource）。
//
// 影像生成（imageToImage）不在此限；背景修補仍可使用已載入的圖生圖模型。

/// 區域（文字位置與原文）從哪裡來。
///
/// **翻譯不在此列**：兩種模式下譯文都固定由 Agent 以 region.update 寫入，
/// 後端永遠不會呼叫內建圖生文模型翻譯。
enum MCPRegionSource: String, Codable, Sendable, CaseIterable {
    /// 全部交給 Agent：後端連 Vision OCR 都不跑。
    case agent
    /// 區域由本機計算（Vision OCR ＋ 已載入的圖生文模型做語意分類與 OCR 校正），
    /// 只有翻譯交給 Agent。座標由本機的傳統演算法決定，不會有模型座標漂移。
    case local
}


/// 不執行 Vision OCR。區域一律由 Agent 透過 page.supplement_regions／region.create 提供。
struct AgentDrivenTextRecognizer: PageTextRecognizing {
    func recognizeText(
        in imageURL: URL,
        languageCodes: [String],
        readingDirection: ReadingDirection
    ) async throws -> [DialogueRegion] {
        []
    }
}

/// 不執行 VLM 語意區域偵測，原樣退回呼叫端既有的區域。
struct AgentDrivenRegionDetector: SemanticRegionDetecting {
    func detectRegions(
        pageURL: URL,
        existingRegions: [DialogueRegion],
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        progress(1)
        return existingRegions
    }
}

/// 不執行 VLM OCR 校正。Agent 以 region.update 寫回 source_text 即視為已校正。
struct AgentDrivenOCRTextRefiner: OCRTextRefining {
    func refineOCRText(
        regions: [DialogueRegion],
        pageURL: URL,
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        progress(1)
        return regions
    }
}

/// 不執行 VLM 翻譯。譯文必須由 Agent 以 region.update 的 translated_text 寫入。
struct AgentDrivenTranslator: RegionTranslating {
    func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        throw MCPServiceError.agentTranslationRequired
    }
}
