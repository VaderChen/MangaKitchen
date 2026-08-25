import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

/// 將頁面領域狀態投影為 MCP 契約，並集中管理 optimistic revision。
enum MCPPageContractPresenter {
    static func makePageTask(
        _ page: ComicPage,
        regionSource: MCPRegionSource,
        workflow: MCPWorkflowKind
    ) -> MCPPageTask {
        let missingSourceText = page.regions.reduce(into: 0) { count, region in
            if region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        let missingTranslation = page.regions.reduce(into: 0) { count, region in
            if region.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        let incompleteMask = page.regions.reduce(into: 0) { count, region in
            if !region.maskCoverageComplete { count += 1 }
        }
        let hasMask = fileExists(page.maskURL)
        let hasBackground = fileExists(page.backgroundURL)
        let hasTranslationPreview = fileExists(page.translationPreviewURL)
        let hasOutput = fileExists(page.outputURL)
        let hasColorizationPreview = fileExists(page.colorizationPreviewURL)
        let hasColorizationOutput = fileExists(page.colorizationOutputURL)
        let colorizationState = resolvedColorizationState(
            for: page,
            hasMaskData: hasMask && hasBackground,
            hasPreview: hasColorizationPreview,
            hasOutput: hasColorizationOutput
        )
        let identifier = page.id.uuidString.lowercased()
        let hasCompleteMaskData = hasMask && hasBackground

        let nextAction: MCPPageNextAction
        switch workflow {
        case .translation:
            if page.regions.isEmpty {
                nextAction = regionSource == .local ? .detectMasks : .submitRegions
            } else if !hasCompleteMaskData {
                nextAction = .detectMasks
            } else if missingSourceText > 0 {
                nextAction = .writeSourceText
            } else if missingTranslation > 0 || !hasTranslationPreview {
                nextAction = .writeTranslation
            } else if !hasOutput {
                nextAction = .compose
            } else {
                nextAction = .done
            }
        case .colorization:
            if page.regions.isEmpty || !hasCompleteMaskData {
                nextAction = .prepareColorizationMask
            } else if !hasColorizationPreview {
                nextAction = .colorize
            } else if !hasColorizationOutput {
                nextAction = .exportColorization
            } else {
                nextAction = .done
            }
        }

        return MCPPageTask(
            pageID: page.id,
            index: page.index,
            title: page.title,
            relativeSourcePath: page.relativeSourcePath,
            stage: page.stage,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            regionCount: page.regions.count,
            regionsMissingSourceText: missingSourceText,
            regionsMissingTranslation: missingTranslation,
            regionsWithIncompleteMask: incompleteMask,
            hasMask: hasMask,
            hasBackground: hasBackground,
            hasTranslationPreview: hasTranslationPreview,
            hasOutput: hasOutput,
            colorizationStage: colorizationState.stage,
            colorizationProgress: colorizationState.progress,
            hasColorizationPreview: hasColorizationPreview,
            hasColorizationOutput: hasColorizationOutput,
            nextAction: nextAction,
            nextActionInstruction: nextActionInstruction(for: nextAction),
            sourceURI: "mangakitchen://page/\(identifier)/source",
            pageURI: "mangakitchen://page/\(identifier)",
            revision: (try? revision(for: page)) ?? "unavailable",
            errorMessage: page.errorMessage,
            colorizationErrorMessage: colorizationState.errorMessage
        )
    }

    static func makeInspection(
        workspaceID: UUID,
        page: ComicPage
    ) throws -> MCPPageInspection {
        let identifier = page.id.uuidString.lowercased()
        let sourceExists = FileManager.default.fileExists(atPath: page.sourceURL.path)
        let maskExists = fileExists(page.maskURL)
        let backgroundExists = fileExists(page.backgroundURL)
        let superResolvedExists = fileExists(page.superResolvedBackgroundURL)
        let translationPreviewExists = fileExists(page.translationPreviewURL)
        let outputExists = fileExists(page.outputURL)
        let colorizationPreviewExists = fileExists(page.colorizationPreviewURL)
        let colorizationOutputExists = fileExists(page.colorizationOutputURL)
        let colorizationState = resolvedColorizationState(
            for: page,
            hasMaskData: maskExists && backgroundExists,
            hasPreview: colorizationPreviewExists,
            hasOutput: colorizationOutputExists
        )
        let colorizationInputSource: MCPColorizationInputSource = outputExists
            ? .translatedOutput
            : .source
        let colorizationInputURI = outputExists
            ? "mangakitchen://page/\(identifier)/output"
            : "mangakitchen://page/\(identifier)/source"
        var operations = [
            "mangakitchen.page.inspect",
            "mangakitchen.page.update"
        ]
        if maskExists, backgroundExists, !page.regions.isEmpty {
            operations.append("mangakitchen.page.prepare_agent_task")
        }
        if !page.regions.isEmpty {
            operations.append("mangakitchen.region.batch_update")
        }
        if page.regions.count > 1 {
            operations.append("mangakitchen.region.reorder")
        }
        if translationPreviewExists,
           page.regions.allSatisfy({ !$0.translatedText.isEmpty }) {
            operations.append("mangakitchen.page.render")
        }
        if maskExists, backgroundExists, !page.regions.isEmpty {
            operations.append("mangakitchen.page.colorize")
            operations.append("mangakitchen.page.prepare_colorization_task")
            operations.append("mangakitchen.page.submit_colorization_result")
        }
        if colorizationPreviewExists {
            operations.append("mangakitchen.page.render_colorization")
        }
        if page.colorizationState != nil
            || !(page.colorizationMaskStrokes?.isEmpty ?? true)
            || colorizationPreviewExists
            || colorizationOutputExists {
            operations.append("mangakitchen.page.reset_colorization")
        }
        return MCPPageInspection(
            workspaceID: workspaceID,
            contractVersion: MCPContractDescription.current.contractVersion,
            revision: try revision(for: page),
            page: page,
            artifacts: MCPPageArtifacts(
                hasSource: sourceExists,
                hasMask: maskExists,
                hasBackground: backgroundExists,
                hasSuperResolvedBackground: superResolvedExists,
                hasTranslationPreview: translationPreviewExists,
                hasOutput: outputExists,
                hasColorizationPreview: colorizationPreviewExists,
                hasColorizationOutput: colorizationOutputExists,
                sourceURI: "mangakitchen://page/\(identifier)/source",
                maskURI: maskExists ? "mangakitchen://page/\(identifier)/mask" : nil,
                outputURI: outputExists ? "mangakitchen://page/\(identifier)/output" : nil,
                colorizationPreviewURI: colorizationPreviewExists
                    ? "mangakitchen://page/\(identifier)/colorization-preview"
                    : nil,
                colorizationOutputURI: colorizationOutputExists
                    ? "mangakitchen://page/\(identifier)/colorization-output"
                    : nil
            ),
            colorization: MCPColorizationStatus(
                stage: colorizationState.stage,
                progress: colorizationState.progress,
                errorMessage: colorizationState.errorMessage,
                inputSource: colorizationInputSource,
                inputURI: colorizationInputURI
            ),
            availableOperations: operations,
            regionsURI: "mangakitchen://page/\(identifier)/regions"
        )
    }

    static func makeMutationResult(
        workspaceID: UUID,
        page: ComicPage
    ) throws -> MCPPageMutationResult {
        MCPPageMutationResult(
            workspaceID: workspaceID,
            revision: try revision(for: page),
            page: page
        )
    }

    static func revision(for page: ComicPage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(page)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "page-%016llx", hash)
    }

    static func requireRevision(_ expected: String, for page: ComicPage) throws {
        let current = try revision(for: page)
        guard expected == current else {
            throw MCPServiceError.revisionConflict(expected: expected, current: current)
        }
    }

    static func regionEdit(from patch: MCPRegionPatch) -> RegionEdit {
        var edit = RegionEdit()
        edit.sourceText = patch.sourceText
        edit.translatedText = patch.translatedText
        edit.translationAnchor = patch.translationAnchor
        edit.translationBounds = patch.translationBounds
        edit.bounds = patch.bounds
        edit.bubbleBounds = patch.bubbleBounds
        edit.fontName = patch.fontName
        edit.fontSize = patch.fontSize
        edit.useAutomaticFontSize = patch.automaticFontSize
        edit.fontWeight = patch.fontWeight
        edit.writingDirection = patch.writingDirection
        edit.textAlignment = patch.textAlignment
        edit.textColorHex = patch.textColorHex
        edit.strokeColorHex = patch.strokeColorHex
        edit.strokeWidth = patch.strokeWidth
        edit.opacity = patch.opacity
        edit.rotationDegrees = patch.rotationDegrees
        edit.isVisible = patch.isVisible
        edit.sourceTextChangesMaskGeometry = false
        return edit
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func imageMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    private static func fileExists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private static func resolvedColorizationState(
        for page: ComicPage,
        hasMaskData: Bool,
        hasPreview: Bool,
        hasOutput: Bool
    ) -> ColorizationPageState {
        if hasOutput { return ColorizationPageState(stage: .completed, progress: 1) }
        if hasPreview { return ColorizationPageState(stage: .previewReady, progress: 0.75) }
        if let state = page.colorizationState,
           [.colorizing, .exporting, .failed].contains(state.stage) {
            return state
        }
        if hasMaskData || !(page.colorizationMaskStrokes?.isEmpty ?? true) {
            return ColorizationPageState(stage: .maskReady, progress: 0.25)
        }
        return ColorizationPageState()
    }

    private static func nextActionInstruction(for action: MCPPageNextAction) -> String {
        switch action {
        case .detectMasks:
            "狀態提示：步驟二的區域、遮罩或去字背景尚未完成；請先在 App 完成步驟二。"
        case .submitRegions:
            "狀態提示：目前沒有 App 區域；只有使用者要求補區域時才提交。"
        case .writeSourceText:
            "狀態提示：部分區域缺少原文；優先使用單頁 Agent 工作包一次處理。"
        case .writeTranslation:
            "狀態提示：步驟三的原文、譯文或排字預覽尚未完成；請使用單頁 Agent 工作包一次處理。"
        case .compose:
            "狀態提示：步驟三預覽已完成；只有使用者要求輸出時才呼叫 page.render 儲存。"
        case .prepareColorizationMask:
            "狀態提示：上色步驟二尚未完成；請先在 App 建立並確認反對話框遮罩。"
        case .colorize:
            "狀態提示：上色遮罩已完成；可呼叫 page.prepare_colorization_task 交由 Agent 上色並以 page.submit_colorization_result 回寫，或載入 imageColorization 模型後呼叫 page.colorize。"
        case .exportColorization:
            "狀態提示：上色預覽已完成；只有使用者要求輸出時才呼叫 page.render_colorization。"
        case .done:
            "狀態提示：本頁已有完整產物，除非使用者明確要求修改，否則不需操作。"
        }
    }
}
