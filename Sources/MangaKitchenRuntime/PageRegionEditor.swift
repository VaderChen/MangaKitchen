import Foundation
import MangaKitchenCore

/// 可選欄位的三態更新：不動、清成 nil、設成新值。
public enum FieldUpdate<Value> {
    case unchanged
    case clear
    case set(Value)

    public func applied(to current: Value?) -> Value? {
        switch self {
        case .unchanged: current
        case .clear: nil
        case let .set(value): value
        }
    }

    public var isChange: Bool {
        if case .unchanged = self { return false }
        return true
    }
}

extension FieldUpdate: Sendable where Value: Sendable {}

/// 一次區域編輯要改的欄位。App 與 MCP 兩邊送進來的都是這個型別。
public struct RegionEdit {
    public var sourceText: String?
    public var translatedText: String?
    public var translationAnchor: FieldUpdate<NormalizedPoint> = .unchanged
    public var translationBounds: FieldUpdate<NormalizedRect> = .unchanged
    public var bounds: NormalizedRect?
    public var bubbleBounds: FieldUpdate<NormalizedRect> = .unchanged
    public var fontName: String?
    public var fontSize: FieldUpdate<Double> = .unchanged
    public var useAutomaticFontSize: Bool?
    public var fontWeight: DialogueFontWeight?
    public var textAlignment: DialogueTextAlignment?
    public var textColorHex: String?
    public var strokeColorHex: String?
    public var strokeWidth: Double?
    public var opacity: Double?
    public var rotationDegrees: Double?
    public var isVisible: Bool?
    public var writingDirection: WritingDirection?
    public var automaticMaskEnabled: Bool?
    /// MCP 步驟三只補文字時設為 false，保留步驟二已完成的像素遮罩。
    /// GUI 編輯預設為 true，修改原文時仍可依需要重新精修。
    public var sourceTextChangesMaskGeometry: Bool = true

    public init() {}
}

/// 區域編輯的單一實作。
///
/// App 與 MCP 過去各自維護一份「套用欄位 → 要不要重新精修 → 要不要重畫遮罩」的流程，
/// 兩份會漂移：MCP 的 `region.create` 沒有精修、App 的也沒有對齊粗框，於是同一張圖
/// 走兩條路會得到不同的遮罩。這裡是唯一的實作，兩邊都只負責保存與 UI。
public struct PageRegionEditor: Sendable {
    private let pipeline: ComicTranslationPipeline
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?

    public init(
        pipeline: ComicTranslationPipeline,
        bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?
    ) {
        self.pipeline = pipeline
        self.bubbleSegmenter = bubbleSegmenter
    }

    public struct Outcome: Sendable {
        public var regions: [DialogueRegion]
        /// nil 代表這次編輯不需要重畫遮罩。
        public var maskURL: URL?
    }

    /// 套用欄位變更。回傳是否動到遮罩幾何 —— 動到才代表舊的像素遮罩已經失效。
    ///
    /// 純資料轉換，沒有 I/O，兩邊共用同一份判斷。
    @discardableResult
    public static func apply(_ edit: RegionEdit, to region: inout DialogueRegion) -> Bool {
        if let sourceText = edit.sourceText {
            let previous = region.sourceText
            region.rawSourceText = region.rawSourceText ?? previous
            region.sourceText = sourceText
            region.ocrTextRefined = true
            if sourceText != previous, edit.translatedText == nil {
                region.translatedText = ""
            }
        }
        if let translatedText = edit.translatedText {
            if region.translatedText != translatedText {
                region.translationConfidence = nil
                region.translationQAFlags = []
            }
            region.translatedText = translatedText
        }
        if edit.translationAnchor.isChange {
            region.translationAnchor = edit.translationAnchor
                .applied(to: region.translationAnchor)?.clamped()
        }
        if edit.translationBounds.isChange {
            region.translationBounds = edit.translationBounds
                .applied(to: region.translationBounds)?.clamped()
        }
        if let bounds = edit.bounds { region.bounds = bounds.clamped() }
        if edit.bubbleBounds.isChange {
            region.bubbleBounds = edit.bubbleBounds
                .applied(to: region.bubbleBounds)?.clamped()
        }
        if let fontName = edit.fontName, !fontName.isEmpty {
            region.style.fontName = fontName
        }
        if edit.useAutomaticFontSize == true {
            region.style.fontSize = nil
        } else if edit.fontSize.isChange {
            region.style.fontSize = edit.fontSize
                .applied(to: region.style.fontSize)
                .map { min(max($0, 4), 512) }
        }
        if let fontWeight = edit.fontWeight { region.style.fontWeight = fontWeight }
        if let textAlignment = edit.textAlignment { region.style.textAlignment = textAlignment }
        if let textColorHex = edit.textColorHex {
            region.style.textColorHex = DialogueStyle.normalizedHexColor(
                textColorHex,
                fallback: region.style.textColorHex
            )
        }
        if let strokeColorHex = edit.strokeColorHex {
            region.style.strokeColorHex = DialogueStyle.normalizedHexColor(
                strokeColorHex,
                fallback: region.style.strokeColorHex
            )
        }
        if let strokeWidth = edit.strokeWidth, strokeWidth.isFinite {
            region.style.strokeWidth = min(max(strokeWidth, 0), 20)
        }
        if let opacity = edit.opacity, opacity.isFinite {
            region.style.opacity = min(max(opacity, 0), 1)
        }
        if let rotationDegrees = edit.rotationDegrees, rotationDegrees.isFinite {
            region.style.rotationDegrees = min(max(rotationDegrees, -180), 180)
        }
        if let isVisible = edit.isVisible { region.style.isVisible = isVisible }
        if let writingDirection = edit.writingDirection {
            region.style.writingDirection = writingDirection
        }
        if let automaticMaskEnabled = edit.automaticMaskEnabled {
            region.automaticMaskEnabled = automaticMaskEnabled
        }

        // 粗框與對話框邊界直接決定搜尋範圍。MCP 步驟三可明確保留既有遮罩，
        // 因為 Agent 回傳 sourceText／translatedText 只是補上文字資料。
        let geometryChanged = (edit.sourceText != nil && edit.sourceTextChangesMaskGeometry)
            || edit.bounds != nil
            || edit.bubbleBounds.isChange
        if geometryChanged {
            region.maskPolygons = []
            region.maskRefinementApplied = false
            region.maskCoverageRatio = nil
            region.maskCoverageComplete = false
        }
        return geometryChanged
    }

    /// 把指定區域重新對齊粗框、精修，然後重畫整頁遮罩。
    ///
    /// 對齊必須跟精修綁在一起：精修的前提是「粗框大致就是文字」，而 Agent 目測與
    /// 使用者手拉的框都不保證這件事。只精修不對齊，鬆框會圈進速度線、小框只蓋住半段字。
    public func materialize(
        regions: [DialogueRegion],
        refining refinedIDs: [UUID],
        page: ComicPage,
        options: ProcessingOptions,
        regeneratesMask: Bool
    ) async throws -> Outcome {
        var result = regions
        if !refinedIDs.isEmpty {
            let targets = Set(refinedIDs)
            let indices = result.indices.filter { targets.contains(result[$0].id) }
            if !indices.isEmpty {
                let snapped = MangaAgentRegionSnapper.snapped(
                    regions: indices.map { result[$0] },
                    pageURL: page.sourceURL,
                    using: bubbleSegmenter
                )
                let refined = try await pipeline.refineMasks(page: page, regions: snapped)
                let refinedByID = Dictionary(uniqueKeysWithValues: refined.map { ($0.id, $0) })
                for index in indices {
                    if let region = refinedByID[result[index].id] { result[index] = region }
                }
            }
        }
        guard regeneratesMask else { return Outcome(regions: result, maskURL: nil) }
        let maskURL = try await pipeline.regenerateMask(
            page: page,
            regions: result,
            options: options
        )
        return Outcome(regions: result, maskURL: maskURL)
    }

    /// 新增區域：一律先對齊再精修，兩條路徑不得再各自決定要不要做。
    public func created(
        _ region: DialogueRegion,
        appendingTo regions: [DialogueRegion],
        page: ComicPage,
        options: ProcessingOptions
    ) async throws -> Outcome {
        try await materialize(
            regions: regions + [region],
            refining: region.automaticMaskEnabled ? [region.id] : [],
            page: page,
            options: options,
            regeneratesMask: true
        )
    }
}
