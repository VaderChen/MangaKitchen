import Foundation
import MangaKitchenCore

struct MCPContractCoordinateSystem: Codable, Sendable {
    var origin: String
    var unit: String
    var range: String
    var rectangleFields: [String]
}

struct MCPContractLimits: Codable, Sendable {
    var maximumRegionsPerPage: Int
    var maximumBatchPatches: Int
    var maximumPageTitleLength: Int
    var maximumColorizationResultBytes: Int
}

struct MCPContractDescription: Codable, Sendable {
    var contractVersion: String
    var protocolVersion: String
    var revisionFormat: String
    var coordinateSystem: MCPContractCoordinateSystem
    var limits: MCPContractLimits
    var nullablePatchFields: [String]
    var styleFields: [String]
    var publicTools: [String]
    var resources: [String]
    var invariants: [String]

    static let current = MCPContractDescription(
        contractVersion: "1.3.0",
        protocolVersion: "2025-11-25",
        revisionFormat: "opaque page content token；呼叫端只能原樣回傳，不可解析或自行遞增",
        coordinateSystem: MCPContractCoordinateSystem(
            origin: "top-left",
            unit: "normalized",
            range: "0...1",
            rectangleFields: ["x", "y", "width", "height"]
        ),
        limits: MCPContractLimits(
            maximumRegionsPerPage: 64,
            maximumBatchPatches: 64,
            maximumPageTitleLength: 200,
            maximumColorizationResultBytes: 20_971_520
        ),
        nullablePatchFields: [
            "translation_anchor",
            "translation_bounds",
            "bubble_bounds",
            "font_size"
        ],
        styleFields: [
            "literal_translated_text",
            "speaker_id",
            "tone",
            "translation_confidence",
            "translation_qa_flags",
            "font_name",
            "font_size",
            "automatic_font_size",
            "font_weight",
            "writing_direction",
            "text_alignment",
            "text_color",
            "stroke_color",
            "stroke_width",
            "opacity",
            "rotation_degrees",
            "is_visible"
        ],
        publicTools: [
            "mangakitchen.contract.describe",
            "mangakitchen.workspace.list",
            "mangakitchen.workspace.open",
            "mangakitchen.workspace.pages",
            "mangakitchen.workspace.activate",
            "mangakitchen.workspace.rescan",
            "mangakitchen.workspace.set_output",
            "mangakitchen.workspace.configure",
            "mangakitchen.model.load",
            "mangakitchen.page.inspect",
            "mangakitchen.page.update",
            "mangakitchen.page.prepare_agent_task",
            "mangakitchen.page.submit_agent_result",
            "mangakitchen.page.render",
            "mangakitchen.page.colorize",
            "mangakitchen.page.prepare_colorization_task",
            "mangakitchen.page.submit_colorization_result",
            "mangakitchen.page.render_colorization",
            "mangakitchen.page.reset_colorization",
            "mangakitchen.region.batch_update",
            "mangakitchen.region.reorder",
            "mangakitchen.glossary.list",
            "mangakitchen.glossary.upsert",
            "mangakitchen.glossary.remove"
        ],
        resources: [
            "mangakitchen://contract/current",
            "mangakitchen://workspace/list",
            "mangakitchen://workspace/current",
            "mangakitchen://workspace/current/pages",
            "mangakitchen://workspace/current/colorization-pages",
            "mangakitchen://workspace/current/glossary",
            "mangakitchen://workspace/{workspace_id}/capabilities",
            "mangakitchen://page/{page_id}",
            "mangakitchen://page/{page_id}/regions",
            "mangakitchen://page/{page_id}/source",
            "mangakitchen://page/{page_id}/mask",
            "mangakitchen://page/{page_id}/output",
            "mangakitchen://page/{page_id}/colorization-preview",
            "mangakitchen://page/{page_id}/colorization-output"
        ],
        invariants: [
            "所有新寫入工具都必須帶入最近 inspect、prepare_agent_task 或 prepare_colorization_task 取得的 expected_revision。",
            "revision 不符時整筆拒絕，不得靜默覆蓋較新的 GUI 或 MCP 編輯。",
            "region.batch_update 先驗證完整批次，再一次提交；任一 patch 無效時不得部分套用。",
            "partial patch 省略欄位代表沿用；null 只允許清除 nullablePatchFields 列出的欄位。",
            "遮罩 geometry 與文字 presentation 分離；純文字或樣式修改不得重建像素遮罩。",
            "步驟二只建立區域、遮罩與去字背景；步驟三只翻譯並產生排字預覽；步驟四只把既有預覽儲存到輸出位置。",
            "Agent 不直接讀寫 .str；App 負責 sidecar、工作區狀態及產物持久化。",
            "HTML/CSS 是畫布、PNG 與 PSD 的唯一文字排版標準。",
            "translationQuality 啟用整頁語境、二次校稿與 QA 時，Agent 應保存直譯稿、顯示譯文、角色語氣、信心與 QA flags。",
            "MCP 步驟三必須由可讀取原圖的多模態 Agent 執行；App 不再提供文生文模型選項。",
            "App 不維護雲端 Provider 清單；Agent 可自行選擇 Provider，再依本契約回寫結果。",
            "上色狀態、進度、預覽與輸出獨立於翻譯 stage、progress、preview 與 output。",
            "DDColor 目前只使用模型預設推論；colorizationColorRange 與 colorizationMode 不屬於可生效的 MCP 推論參數。",
            "上色輸入優先使用已存在的翻譯輸出，否則回退到來源圖片；不得隱式執行翻譯輸出。",
            "Agent 上色工作包一次回傳實際輸入與反對話框遮罩；回寫圖片必須與工作包像素尺寸完全一致。",
            "submit_colorization_result 只建立上色預覽；只有 render_colorization 可以寫入最終輸出。"
        ]
    )
}

enum MCPWorkflowKind: String, Codable, Sendable {
    case translation
    case colorization
}

enum MCPColorizationInputSource: String, Codable, Sendable {
    case translatedOutput
    case source
}

struct MCPWorkspaceCapabilities: Codable, Sendable {
    var workspaceID: UUID
    var contractVersion: String
    var regionSource: MCPRegionSource
    var providerPolicy: String
    var tools: [String]
    var styleFields: [String]
    var supportsOptimisticConcurrency: Bool
    var supportsAtomicRegionBatchUpdate: Bool
    var supportsHTMLBasedPSD: Bool
    var requiresMultimodalTranslationAgent: Bool
    var supportsColorization: Bool
    var colorizationModelCapability: ModelCapability
    var supportsColorizationTuning: Bool
    var supportsAgentColorization: Bool
}

struct MCPPageArtifacts: Codable, Sendable {
    var hasSource: Bool
    var hasMask: Bool
    var hasBackground: Bool
    var hasSuperResolvedBackground: Bool
    var hasTranslationPreview: Bool
    var hasOutput: Bool
    var hasColorizationPreview: Bool
    var hasColorizationOutput: Bool
    var sourceURI: String
    var maskURI: String?
    var outputURI: String?
    var colorizationPreviewURI: String?
    var colorizationOutputURI: String?
}

struct MCPColorizationStatus: Codable, Sendable {
    var stage: ColorizationProcessingStage
    var progress: Double
    var errorMessage: String?
    var inputSource: MCPColorizationInputSource
    var inputURI: String
}

struct MCPPageInspection: Codable, Sendable {
    var workspaceID: UUID
    var contractVersion: String
    var revision: String
    var page: ComicPage
    var artifacts: MCPPageArtifacts
    var colorization: MCPColorizationStatus
    var availableOperations: [String]
    var regionsURI: String
}

struct MCPPageMutationResult: Codable, Sendable {
    var workspaceID: UUID
    var revision: String
    var page: ComicPage
}

struct MCPPageRegionsResource: Codable, Sendable {
    var workspaceID: UUID
    var pageID: UUID
    var revision: String
    var regions: [DialogueRegion]
}

struct MCPRegionBatchResult: Codable, Sendable {
    var workspaceID: UUID
    var pageID: UUID
    var revision: String
    var updatedRegionIDs: [UUID]
    var regions: [DialogueRegion]
}

struct MCPRegionPatch: Sendable {
    var regionID: UUID
    var sourceText: String?
    var translatedText: String?
    var translationAnchor: MCPFieldUpdate<NormalizedPoint>
    var translationBounds: MCPFieldUpdate<NormalizedRect>
    var bounds: NormalizedRect?
    var bubbleBounds: MCPFieldUpdate<NormalizedRect>
    var fontName: String?
    var fontSize: MCPFieldUpdate<Double>
    var automaticFontSize: Bool?
    var fontWeight: DialogueFontWeight?
    var writingDirection: WritingDirection?
    var textAlignment: DialogueTextAlignment?
    var textColorHex: String?
    var strokeColorHex: String?
    var strokeWidth: Double?
    var opacity: Double?
    var rotationDegrees: Double?
    var isVisible: Bool?
}
