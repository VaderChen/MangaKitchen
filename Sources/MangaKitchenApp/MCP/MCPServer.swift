import Foundation
import MCP
import MangaKitchenCore

struct MangaKitchenMCPServer {
    static func makeHTTPHost(
        port: Int,
        allowedClients: [String],
        dataDirectoryPath: String?,
        imageCompositingBackend: ImageCompositingBackend = .cpu
    ) throws -> MangaKitchenMCPHTTPHost {
        let service = try MCPWorkflowService(
            dataDirectoryPath: dataDirectoryPath,
            imageCompositingBackend: imageCompositingBackend
        )
        return try MangaKitchenMCPHTTPHost(
            configuration: .init(port: port, allowedClients: allowedClients),
            service: service
        )
    }

    static func makeServer(service: MCPWorkflowService) async -> Server {
        let server = Server(
            name: "mangakitchen",
            version: "0.1.0",
            title: "MangaKitchen 漫畫翻譯",
            instructions: "先用 mangakitchen.workspace.open 建立目錄專案；可保留多個 workspace_id 並用 workspace.list／activate 切換。譯文一律由你提供：後端永遠不會用內建圖生文模型翻譯，請以 region.update 寫入 translated_text。區域來源可用 workspace.configure 的 region_source 切換 —— agent（預設）表示不執行本機區域辨識，由你讀 mangakitchen://page/{page_id}/source 原圖後以 page.supplement_regions 提交區域與原文；local 表示由本機封閉區域演算法定位，再由已載入的 imageToText 模型分類並轉錄，你只負責翻譯。後端只做確定性的像素遮罩收斂、背景修補與排版。單頁流程：page.detect_masks →（agent 模式才需要）supplement_regions → region.update 寫譯文 → page.compose。使用者要求整批處理時，用 mangakitchen.workspace.pages 取得檔案工作清單，依每頁的 nextAction 逐頁執行，完成一頁後再取一次清單即可續跑；該清單不含 regions 內容，整個專案列出來也很輕量。除非使用者明確要求整批處理，否則不要自行對整個專案迴圈。",

            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await registerTools(on: server, service: service)
        await registerResources(on: server, service: service)
        return server
    }

    private static func registerTools(on server: Server, service: MCPWorkflowService) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }

        await server.withMethodHandler(CallTool.self) { [weak server] request in
            do {
                let arguments = request.arguments ?? [:]
                switch request.name {
                case "mangakitchen.workspace.list":
                    let states = await service.listWorkspaces()
                    return try success("目前共有 \(states.count) 個工作區。", states)

                case "mangakitchen.workspace.open":
                    let source = try requiredFileURL(arguments, "source_directory")
                    let output = try optionalFileURL(arguments, "output_directory")
                    let state = try await service.openWorkspace(
                        sourceDirectoryURL: source,
                        outputDirectoryURL: output,
                        targetLanguageCode: arguments["target_language_code"]?.stringValue
                    )
                    return try success("工作區已開啟，共 \(state.pages.count) 頁。", state)

                case "mangakitchen.workspace.pages":
                    let list = try await service.pageTasks(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        pendingOnly: arguments["pending_only"]?.boolValue ?? true
                    )
                    return try success(
                        "共 \(list.totalPageCount) 頁，其中 \(list.pendingPageCount) 頁仍有待辦。",
                        list
                    )

                case "mangakitchen.workspace.activate":
                    let id = try requiredUUID(arguments, "workspace_id")
                    let state = try await service.activateWorkspace(workspaceID: id)
                    return try success("已切換目前工作區。", state)

                case "mangakitchen.workspace.rescan":
                    let id = try requiredUUID(arguments, "workspace_id")
                    let state = try await service.rescanWorkspace(workspaceID: id)
                    return try success("來源目錄已重新掃描，共 \(state.pages.count) 頁。", state)

                case "mangakitchen.workspace.set_output":
                    let id = try requiredUUID(arguments, "workspace_id")
                    let directory = try requiredFileURL(arguments, "output_directory")
                    let state = try await service.setOutputDirectory(workspaceID: id, directoryURL: directory)
                    return try success("輸出目錄已設定。", state)

                case "mangakitchen.workspace.configure":
                    let id = try requiredUUID(arguments, "workspace_id")
                    let reading = try optionalEnum(arguments, "reading_direction", as: ReadingDirection.self)
                    let writing = try optionalEnum(arguments, "writing_direction", as: WritingDirection.self)
                    let configuration = try await service.configure(
                        workspaceID: id,
                        targetLanguageCode: arguments["target_language_code"]?.stringValue,
                        readingDirection: reading,
                        writingDirection: writing,
                        fontName: arguments["font_name"]?.stringValue,
                        maskExpansion: number(arguments["mask_expansion"]),
                        useImageToImageRestoration: arguments["use_image_to_image_restoration"]?.boolValue,
                        regionSource: try optionalEnum(arguments, "region_source", as: MCPRegionSource.self)
                    )
                    return try success(
                        "工作流設定已更新；區域來源為 \(configuration.regionSource.rawValue)，翻譯一律由 Agent 提供。",
                        configuration
                    )

                case "mangakitchen.glossary.list":
                    let id = try requiredUUID(arguments, "workspace_id")
                    let entries = try await service.glossaryEntries(workspaceID: id)
                    return try success("專有名詞表共有 \(entries.count) 筆。", entries)

                case "mangakitchen.glossary.upsert":
                    let entry = try await service.upsertGlossaryEntry(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        entryID: optionalUUID(arguments, "entry_id"),
                        sourceTerm: requiredString(arguments, "source_term"),
                        translations: requiredStringDictionary(arguments, "translations"),
                        note: arguments["note"]?.stringValue
                    )
                    return try success("專有名詞詞條已儲存。", entry)

                case "mangakitchen.glossary.remove":
                    let entries = try await service.removeGlossaryEntry(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        entryID: requiredUUID(arguments, "entry_id")
                    )
                    return try success("專有名詞詞條已移除。", entries)

                case "mangakitchen.model.load":
                    let directory = try requiredFileURL(arguments, "model_directory")
                    let model = try await service.loadModel(directoryURL: directory)
                    return try success("模型已載入：\(model.displayName)", model)

                case "mangakitchen.page.detect_masks":
                    return try await runWorkflow(
                        .detectMasks,
                        request: request,
                        arguments: arguments,
                        server: server,
                        service: service
                    )

                case "mangakitchen.page.translate":
                    return try await runWorkflow(
                        .translate,
                        request: request,
                        arguments: arguments,
                        server: server,
                        service: service
                    )

                case "mangakitchen.page.compose":
                    return try await runWorkflow(
                        .compose,
                        request: request,
                        arguments: arguments,
                        server: server,
                        service: service
                    )

                case "mangakitchen.page.run_full":
                    return try await runWorkflow(
                        .fullPage,
                        request: request,
                        arguments: arguments,
                        server: server,
                        service: service
                    )

                case "mangakitchen.page.supplement_regions":
                    let result = try await service.supplementRegions(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        pageID: requiredUUID(arguments, "page_id"),
                        proposals: try requiredAgentRegionProposals(arguments, "regions")
                    )
                    return try success(
                        "Agent 已補入 \(result.acceptedRegionIDs.count) 個區域，略過 \(result.skippedCount) 個重複區域。",
                        result
                    )

                case "mangakitchen.region.create":
                    let workspaceID = try requiredUUID(arguments, "workspace_id")
                    let pageID = try requiredUUID(arguments, "page_id")
                    let region = try await service.createRegion(
                        workspaceID: workspaceID,
                        pageID: pageID,
                        bounds: try requiredRect(arguments, "bounds")
                    )
                    return try success("已新增對話區域。", region)

                case "mangakitchen.region.update":
                    let workspaceID = try requiredUUID(arguments, "workspace_id")
                    let pageID = try requiredUUID(arguments, "page_id")
                    let regionID = try requiredUUID(arguments, "region_id")
                    let region = try await service.updateRegion(
                        workspaceID: workspaceID,
                        pageID: pageID,
                        regionID: regionID,
                        sourceText: arguments["source_text"]?.stringValue,
                        translatedText: arguments["translated_text"]?.stringValue,
                        translationAnchor: try optionalPointUpdate(arguments, "translation_anchor"),
                        bounds: try optionalRect(arguments, "bounds"),
                        bubbleBounds: try optionalRectUpdate(arguments, "bubble_bounds"),
                        maskPolygons: try optionalPolygons(arguments, "mask_polygons"),
                        fontName: arguments["font_name"]?.stringValue,
                        fontSize: try optionalNumberUpdate(arguments, "font_size"),
                        fontWeight: try optionalEnum(
                            arguments,
                            "font_weight",
                            as: DialogueFontWeight.self
                        ),
                        useAutomaticFontSize: arguments["automatic_font_size"]?.boolValue,
                        writingDirection: try optionalEnum(arguments, "writing_direction", as: WritingDirection.self),
                        automaticMaskEnabled: arguments["automatic_mask_enabled"]?.boolValue
                    )
                    return try success("對話區域已更新並寫入 .str。", region)

                case "mangakitchen.region.remove":
                    let page = try await service.removeRegion(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        pageID: requiredUUID(arguments, "page_id"),
                        regionID: requiredUUID(arguments, "region_id")
                    )
                    return try success("對話區域已移除並更新 .str。", page)

                case "mangakitchen.mask.add_stroke":
                    let workspaceID = try requiredUUID(arguments, "workspace_id")
                    let pageID = try requiredUUID(arguments, "page_id")
                    let regionID = try requiredUUID(arguments, "region_id")
                    let mode = try requiredEnum(arguments, "mode", as: MaskStrokeMode.self)
                    guard let diameter = number(arguments["diameter"]) else {
                        throw MCPServiceError.invalidArguments("缺少 diameter。")
                    }
                    let region = try await service.addStroke(
                        workspaceID: workspaceID,
                        pageID: pageID,
                        regionID: regionID,
                        mode: mode,
                        diameter: diameter,
                        points: try requiredPoints(arguments, "points")
                    )
                    return try success("遮罩筆劃已加入並重新產生 mask。", region)

                case "mangakitchen.mask.undo_stroke":
                    let region = try await service.undoStroke(
                        workspaceID: requiredUUID(arguments, "workspace_id"),
                        pageID: requiredUUID(arguments, "page_id"),
                        regionID: requiredUUID(arguments, "region_id")
                    )
                    return try success("上一筆遮罩筆劃已復原。", region)

                default:
                    return .init(content: [.text(text: "未知工具：\(request.name)", annotations: nil, _meta: nil)], isError: true)
                }
            } catch is CancellationError {
                return .init(content: [.text(text: "操作已取消。", annotations: nil, _meta: nil)], isError: true)
            } catch {
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }
        }
    }

    private static func registerResources(on server: Server, service: MCPWorkflowService) async {
        await server.withMethodHandler(ListResources.self) { _ in
            let pages = await service.resources()
            var resources = [
                Resource(
                    name: "MangaKitchen 工作區列表",
                    uri: "mangakitchen://workspace/list",
                    description: "目前 MCP process 內已開啟的所有目錄專案",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "MangaKitchen 工作區",
                    uri: "mangakitchen://workspace/current",
                    description: "目前工作區、處理設定、頁面與模型狀態",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "目前專案待處理頁面",
                    uri: "mangakitchen://workspace/current/pages",
                    description: "每頁的進度與 next_action 工作清單；不含 regions 內容，適合 Agent 迴圈取用",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "目前專案專有名詞表",
                    uri: "mangakitchen://workspace/current/glossary",
                    description: "目前工作區的一詞對多語言專有名詞對照",
                    mimeType: "application/json"
                )
            ]
            for page in pages {
                let base = "mangakitchen://page/\(page.id.uuidString.lowercased())"
                resources.append(Resource(
                    name: "頁面 \(page.index)：\(page.title)",
                    uri: base,
                    description: "漫畫頁面狀態與所有對話區域",
                    mimeType: "application/json"
                ))
                resources.append(Resource(
                    name: "\(page.title).str",
                    uri: base + "/strings",
                    description: "此頁的文字、位置、字型與遮罩筆劃映射",
                    mimeType: "application/json"
                ))
                resources.append(Resource(
                    name: "\(page.title) 原圖",
                    uri: base + "/source",
                    description: "來源漫畫圖片",
                    mimeType: imageMIMEType(for: page.sourceURL)
                ))
                if page.maskURL != nil {
                    resources.append(Resource(
                        name: "\(page.title) 遮罩",
                        uri: base + "/mask",
                        description: "目前合併後的文字遮罩",
                        mimeType: "image/png"
                    ))
                }
                if page.outputURL != nil {
                    resources.append(Resource(
                        name: "\(page.title) 輸出",
                        uri: base + "/output",
                        description: "翻譯排版後的合成圖片",
                        mimeType: "image/png"
                    ))
                }
            }
            return .init(resources: resources)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [
                .init(
                    uriTemplate: "mangakitchen://page/{page_id}",
                    name: "MangaKitchen 頁面",
                    description: "依 page_id 讀取頁面及對話區域狀態",
                    mimeType: "application/json"
                ),
                .init(
                    uriTemplate: "mangakitchen://page/{page_id}/strings",
                    name: "MangaKitchen .str",
                    description: "依 page_id 讀取可攜式文字映射",
                    mimeType: "application/json"
                ),
                .init(
                    uriTemplate: "mangakitchen://page/{page_id}/source",
                    name: "MangaKitchen 原圖",
                    description: "依 page_id 讀取來源圖片"
                ),
                .init(
                    uriTemplate: "mangakitchen://page/{page_id}/mask",
                    name: "MangaKitchen 遮罩",
                    description: "依 page_id 讀取二值遮罩",
                    mimeType: "image/png"
                ),
                .init(
                    uriTemplate: "mangakitchen://page/{page_id}/output",
                    name: "MangaKitchen 輸出",
                    description: "依 page_id 讀取合成結果",
                    mimeType: "image/png"
                )
            ])
        }

        await server.withMethodHandler(ReadResource.self) { request in
            switch try await service.readResource(uri: request.uri) {
            case let .text(text, mimeType):
                return .init(contents: [.text(text, uri: request.uri, mimeType: mimeType)])
            case let .binary(data, mimeType):
                return .init(contents: [.binary(data, uri: request.uri, mimeType: mimeType)])
            }
        }
    }

    private static func runWorkflow(
        _ step: MCPWorkflowStep,
        request: CallTool.Parameters,
        arguments: [String: Value],
        server: Server?,
        service: MCPWorkflowService
    ) async throws -> CallTool.Result {
        let workspaceID = try requiredUUID(arguments, "workspace_id")
        let pageIDs = try optionalUUIDArray(arguments, "page_ids")
        let token = request._meta?.progressToken
        let progress: MCPWorkflowService.Progress = { completed, message in
            guard let token else { return }
            Task {
                try? await server?.notify(ProgressNotification.message(.init(
                    progressToken: token,
                    progress: completed,
                    total: 1,
                    message: message
                )))
            }
        }
        let result = try await service.run(
            workspaceID: workspaceID,
            step: step,
            pageIDs: pageIDs,
            progress: progress
        )
        return try success("\(step.rawValue) 已完成 \(result.processedPageIDs.count) 頁。", result)
    }

    private static func success<T: Codable>(_ message: String, _ value: T) throws -> CallTool.Result {
        try .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: value,
            isError: false
        )
    }

    private static func requiredString(_ arguments: [String: Value], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPServiceError.invalidArguments("缺少必要字串參數：\(key)")
        }
        return value
    }

    private static func requiredUUID(_ arguments: [String: Value], _ key: String) throws -> UUID {
        let raw = try requiredString(arguments, key)
        guard let value = UUID(uuidString: raw) else {
            throw MCPServiceError.invalidArguments("\(key) 不是有效 UUID。")
        }
        return value
    }

    private static func optionalUUID(_ arguments: [String: Value], _ key: String) throws -> UUID? {
        guard arguments[key] != nil else { return nil }
        return try requiredUUID(arguments, key)
    }

    private static func requiredStringDictionary(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> [String: String] {
        guard let object = arguments[key]?.objectValue else {
            throw MCPServiceError.invalidArguments("\(key) 必須是語言代碼對字串的物件。")
        }
        var result: [String: String] = [:]
        for (languageCode, value) in object {
            guard let term = value.stringValue else {
                throw MCPServiceError.invalidArguments("\(key) 的每個值都必須是字串。")
            }
            result[languageCode] = term
        }
        return result
    }

    private static func optionalUUIDArray(_ arguments: [String: Value], _ key: String) throws -> [UUID]? {
        guard let raw = arguments[key] else { return nil }
        guard let values = raw.arrayValue else {
            throw MCPServiceError.invalidArguments("\(key) 必須是 UUID 字串陣列。")
        }
        return try values.map { item in
            guard let rawID = item.stringValue, let id = UUID(uuidString: rawID) else {
                throw MCPServiceError.invalidArguments("\(key) 包含無效 UUID。")
            }
            return id
        }
    }

    private static func requiredFileURL(_ arguments: [String: Value], _ key: String) throws -> URL {
        let path = try requiredString(arguments, key)
        guard path.hasPrefix("/") else {
            throw MCPServiceError.invalidArguments("\(key) 必須是絕對路徑。")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func optionalFileURL(_ arguments: [String: Value], _ key: String) throws -> URL? {
        guard arguments[key] != nil else { return nil }
        return try requiredFileURL(arguments, key)
    }

    private static func number(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    private static func requiredRect(_ arguments: [String: Value], _ key: String) throws -> NormalizedRect {
        guard let result = try optionalRect(arguments, key) else {
            throw MCPServiceError.invalidArguments("缺少矩形參數：\(key)")
        }
        return result
    }

    /// bubbleBounds 為 nil 是有意義的狀態（沒有對話框 → 遮罩與排版不設硬邊界），
    /// 因此欄位必須能區分「沒帶」與「明確清除」。省略＝不變，null＝清除。
    private static func optionalRectUpdate(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> MCPFieldUpdate<NormalizedRect> {
        guard let raw = arguments[key] else { return .unchanged }
        if raw.isNull { return .clear }
        return .set(try optionalRect(arguments, key) ?? {
            throw MCPServiceError.invalidArguments("\(key) 必須是矩形或 null。")
        }())
    }

    private static func optionalRect(_ arguments: [String: Value], _ key: String) throws -> NormalizedRect? {
        guard let raw = arguments[key], !raw.isNull else { return nil }
        guard let object = raw.objectValue,
              let x = number(object["x"]),
              let y = number(object["y"]),
              let width = number(object["width"]),
              let height = number(object["height"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw MCPServiceError.invalidArguments("\(key) 必須包含有限數值 x、y、width、height。")
        }
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    /// style.fontSize 為 nil 代表「自動配適字級」。既有的 automatic_font_size 旗標
    /// 仍可用，這裡讓 font_size: null 成為等價寫法，整個更新介面統一為「null 即清除」。
    private static func optionalNumberUpdate(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> MCPFieldUpdate<Double> {
        guard let raw = arguments[key] else { return .unchanged }
        if raw.isNull { return .clear }
        guard let value = number(raw), value.isFinite else {
            throw MCPServiceError.invalidArguments("\(key) 必須是有限數值或 null。")
        }
        return .set(value)
    }

    /// translationAnchor 為 nil 代表「用預設落點」，同樣是有意義的狀態，
    /// 因此和 bubbleBounds 一樣需要三態：省略＝不變，null＝還原預設。
    private static func optionalPointUpdate(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> MCPFieldUpdate<NormalizedPoint> {
        guard let raw = arguments[key] else { return .unchanged }
        if raw.isNull { return .clear }
        guard let point = try optionalPoint(arguments, key) else {
            throw MCPServiceError.invalidArguments("\(key) 必須是座標點或 null。")
        }
        return .set(point)
    }

    private static func optionalPoint(_ arguments: [String: Value], _ key: String) throws -> NormalizedPoint? {
        guard let raw = arguments[key], !raw.isNull else { return nil }
        guard let object = raw.objectValue,
              let x = number(object["x"]),
              let y = number(object["y"]),
              x.isFinite, y.isFinite else {
            throw MCPServiceError.invalidArguments("\(key) 必須包含有限數值 x、y。")
        }
        return NormalizedPoint(x: x, y: y).clamped()
    }

    private static func requiredPoints(_ arguments: [String: Value], _ key: String) throws -> [NormalizedPoint] {
        guard let values = arguments[key]?.arrayValue, !values.isEmpty else {
            throw MCPServiceError.invalidArguments("\(key) 必須是非空座標陣列。")
        }
        return try values.map { item in
            guard let object = item.objectValue,
                  let x = number(object["x"]),
                  let y = number(object["y"]),
                  x.isFinite, y.isFinite else {
                throw MCPServiceError.invalidArguments("\(key) 的每一點必須包含有限數值 x、y。")
            }
            return NormalizedPoint(x: x, y: y)
        }
    }

    private static func optionalPolygons(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> [[NormalizedPoint]]? {
        guard let raw = arguments[key] else { return nil }
        guard let polygons = raw.arrayValue else {
            throw MCPServiceError.invalidArguments("\(key) 必須是多邊形陣列。")
        }
        return try polygons.map { polygon in
            guard let points = polygon.arrayValue, points.count >= 3 else {
                throw MCPServiceError.invalidArguments("\(key) 的每個多邊形至少需要三個點。")
            }
            return try points.map { item in
                guard let object = item.objectValue,
                      let x = number(object["x"]),
                      let y = number(object["y"]),
                      x.isFinite, y.isFinite else {
                    throw MCPServiceError.invalidArguments("\(key) 的每一點必須包含有限數值 x、y。")
                }
                return NormalizedPoint(x: x, y: y)
            }
        }
    }

    private static func requiredAgentRegionProposals(
        _ arguments: [String: Value],
        _ key: String
    ) throws -> [MCPAgentRegionProposal] {
        guard let values = arguments[key]?.arrayValue, (1...64).contains(values.count) else {
            throw MCPServiceError.invalidArguments("\(key) 必須是含 1...64 筆資料的陣列。")
        }
        return try values.enumerated().map { offset, item in
            guard let object = item.objectValue else {
                throw MCPServiceError.invalidArguments("\(key)[\(offset)] 必須是物件。")
            }
            return MCPAgentRegionProposal(
                bounds: try requiredRect(object, "bounds"),
                sourceText: try requiredString(object, "source_text"),
                bubbleBounds: try optionalRect(object, "bubble_bounds"),
                maskPolygons: try optionalPolygons(object, "mask_polygons"),
                writingDirection: try optionalEnum(object, "writing_direction", as: WritingDirection.self)
            )
        }
    }

    private static func requiredEnum<T: RawRepresentable>(
        _ arguments: [String: Value],
        _ key: String,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        let raw = try requiredString(arguments, key)
        guard let value = T(rawValue: raw) else {
            throw MCPServiceError.invalidArguments("\(key) 的值不受支援：\(raw)")
        }
        return value
    }

    private static func optionalEnum<T: RawRepresentable>(
        _ arguments: [String: Value],
        _ key: String,
        as type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard arguments[key] != nil else { return nil }
        return try requiredEnum(arguments, key, as: type)
    }

    private static func imageMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    private static var toolDefinitions: [Tool] {
        let workspaceID = property("string", "由 workspace.open 回傳的工作區 UUID")
        let pageIDs = Value.object([
            "type": "array",
            "description": "要處理的 page_id；省略或空陣列代表全部頁面",
            "items": property("string", "頁面 UUID")
        ])
        let bounds = Value.object([
            "type": "object",
            "description": "左上原點的正規化矩形；區域 bounds 是涵蓋完整原文的粗搜尋範圍，不會直接成為最終遮罩。請貼著文字本身給，不要放大到整個對話框或整格分鏡 —— bounds 同時決定譯文的落點與字級推估，給太鬆會讓譯文排到空白處。",
            "properties": .object([
                "x": property("number", "0...1"),
                "y": property("number", "0...1"),
                "width": property("number", "0...1"),
                "height": property("number", "0...1")
            ]),
            "required": ["x", "y", "width", "height"],
            "additionalProperties": false
        ])
        let bubbleBounds = Value.object([
            "type": "object",
            "description": "涵蓋整個對話框內緣的左上原點正規化矩形；像素搜尋與最終遮罩都不得越界。只在文字確實被封閉對話框、旁白框或標題框包住時提供；無框台詞（直接排在畫面或放射線上的字）請省略，代表沒有硬邊界，遮罩與譯文改為只依 maskExpansion 由文字向外擴。切勿為無框文字或整格分鏡杜撰一個框，那會把譯文推到分鏡中央。region.update 傳 null 可清除既有的錯誤框。",
            "properties": .object([
                "x": property("number", "0...1"),
                "y": property("number", "0...1"),
                "width": property("number", "0...1"),
                "height": property("number", "0...1")
            ]),
            "required": ["x", "y", "width", "height"],
            "additionalProperties": false
        ])
        let point = Value.object([
            "type": "object",
            "description": "左上原點的正規化座標點。region.update 傳 null 可還原成預設落點。",
            "properties": .object([
                "x": property("number", "0...1"),
                "y": property("number", "0...1")
            ]),
            "required": ["x", "y"],
            "additionalProperties": false
        ])
        let maskPolygons = Value.object([
            "type": "array",
            "description": "覆蓋原文字的一個或多個左上原點正規化多邊形",
            "items": .object([
                "type": "array",
                "minItems": 3,
                "items": point
            ])
        ])
        let agentRegion = Value.object([
            "type": "object",
            "description": "外部 Agent 在原圖辨識到、但目前頁面資料遺漏的文字區域",
            "properties": .object([
                "bounds": bounds,
                "source_text": property("string", "Agent 轉錄並校正後的原文；不可為空"),
                "bubble_bounds": bubbleBounds,
                "mask_polygons": maskPolygons,
                "writing_direction": enumProperty(["automatic", "horizontal", "vertical"])
            ]),
            "required": ["bounds", "source_text"],
            "additionalProperties": false
        ])
        let translations = Value.object([
            "type": "object",
            "description": "BCP-47 語言代碼到固定譯詞，例如 {\"zh-Hant\":\"王都\",\"en\":\"Royal Capital\"}",
            "additionalProperties": property("string", "該語言的固定譯詞")
        ])
        let mutating = Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        let idempotent = Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

        return [
            Tool(
                name: "mangakitchen.workspace.list",
                title: "列出漫畫工作區",
                description: "列出目前 MCP process 內已開啟的所有目錄專案與頁面狀態。",
                inputSchema: objectSchema([:], required: []),
                annotations: readOnly,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.open",
                title: "開啟漫畫工作區",
                description: "遞迴掃描來源目錄、建立頁面列表，並載入各原圖旁既有的 .str sidecar。",
                inputSchema: objectSchema([
                    "source_directory": property("string", "來源目錄的絕對路徑"),
                    "output_directory": property("string", "可選的輸出目錄絕對路徑"),
                    "target_language_code": property("string", "可選 BCP-47 目標語言，例如 zh-Hant")
                ], required: ["source_directory"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.pages",
                title: "列出待處理頁面",
                description: "取得專案的檔案工作清單，供 Agent 收到使用者指令後自行迴圈處理。回傳每頁的 stage、缺原文／缺譯文／遮罩未通過的區域數，以及 next_action（submitRegions／writeSourceText／writeTranslation／compose／done）與該頁的原圖 URI。刻意不含 regions 內容，因此整個專案列出來也很輕量；需要細節時再讀 mangakitchen://page/{page_id}。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "pending_only": property("boolean", "預設 true，只回傳 next_action 不是 done 的頁面")
                ], required: ["workspace_id"]),
                annotations: readOnly,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.activate",
                title: "切換目前工作區",
                description: "將指定 workspace_id 設為 current resource 使用的專案；其他工具仍可直接傳入任一 workspace_id。",
                inputSchema: objectSchema(["workspace_id": workspaceID], required: ["workspace_id"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.rescan",
                title: "重新掃描來源",
                description: "重新遞迴掃描來源目錄，保留路徑相同頁面的既有狀態。",
                inputSchema: objectSchema(["workspace_id": workspaceID], required: ["workspace_id"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.set_output",
                title: "設定輸出目錄",
                description: "設定合成輸出位置並同步每頁 .str；輸出不可位於來源目錄內。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "output_directory": property("string", "輸出目錄的絕對路徑")
                ], required: ["workspace_id", "output_directory"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.workspace.configure",
                title: "設定漫畫工作流",
                description: "調整目標語言、閱讀順序、預設排字方向、字型、遮罩擴張、圖生圖修補與區域來源。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "target_language_code": property("string", "BCP-47 目標語言"),
                    "reading_direction": enumProperty(["rightToLeft", "leftToRight", "topToBottom"]),
                    "writing_direction": enumProperty(["automatic", "horizontal", "vertical"]),
                    "font_name": property("string", "macOS 字型名稱"),
                    "mask_expansion": property("number", "自動遮罩擴張比例 0...0.75"),
                    "use_image_to_image_restoration": property("boolean", "是否優先使用圖生圖修補"),
                    "region_source": .object([
                        "type": "string",
                        "enum": .array(["agent", "local"]),
                        "description": "區域（文字位置與原文）從哪裡來。agent（預設）＝後端不執行本機區域辨識，你用 page.supplement_regions 提交；local＝由本機演算法偵測封閉區域，再由已載入的 imageToText 模型分類並轉錄，你只負責翻譯。兩種模式的譯文都必須由你以 region.update 寫入，後端永遠不會用內建模型翻譯。切到 local 後 page.detect_masks 會重新產生區域並覆寫該頁既有結果（含已寫入的譯文）。"
                    ])
                ], required: ["workspace_id"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.model.load",
                title: "載入本機模型",
                description: "從含 mangakitchen-model.json 的本機目錄載入模型。region_source 為 local 時，imageToText 模型會負責封閉區域分類與原文轉錄；imageToImage 則供 page.compose 的生成式背景修補使用。",
                inputSchema: objectSchema([
                    "model_directory": property("string", "模型目錄的絕對路徑")
                ], required: ["model_directory"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.glossary.list",
                title: "列出專有名詞表",
                description: "讀取指定工作區的一詞對多語言專有名詞對照。",
                inputSchema: objectSchema(["workspace_id": workspaceID], required: ["workspace_id"]),
                annotations: readOnly,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.glossary.upsert",
                title: "新增或更新專有名詞",
                description: "新增詞條，或以 entry_id 更新原詞、備註及完整的多語譯詞映射。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "entry_id": property("string", "更新時提供的詞條 UUID；新增時省略"),
                    "source_term": property("string", "來源漫畫中的固定原詞"),
                    "translations": translations,
                    "note": property("string", "可選的語境或角色備註")
                ], required: ["workspace_id", "source_term", "translations"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.glossary.remove",
                title: "移除專有名詞",
                description: "從指定工作區移除一筆專有名詞詞條。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "entry_id": property("string", "詞條 UUID")
                ], required: ["workspace_id", "entry_id"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            ),
            workflowTool(
                name: "mangakitchen.page.detect_masks",
                title: "重建像素遮罩",
                description: "步驟二，行為取決於 workspace.configure 的 region_source。agent（預設）：不呼叫內建區域辨識或圖生文模型，只把目前已提交的區域收斂成像素級遮罩，既有區域不會被覆寫；頁面還沒有區域時輸出空白遮罩，請接著用 page.supplement_regions 提交。local：由本機演算法偵測封閉區域，再由已載入的 imageToText 模型分類並轉錄，你只需負責翻譯；此模式會重新產生區域並覆寫該頁既有結果（含已寫入的譯文）。",
                workspaceID: workspaceID,
                pageIDs: pageIDs,
                annotations: idempotent
            ),
            Tool(
                name: "mangakitchen.page.supplement_regions",
                title: "由 Agent 補完遺漏遮罩",
                description: "外部 Agent 讀取頁面原圖與目前區域後，批次提交涵蓋完整原文的粗框及原文。bounds 貼著文字給（決定譯文落點與字級），bubble_bounds 只在文字確實被封閉對話框包住時給（決定不可越界的硬邊界）；無框台詞請省略 bubble_bounds。後端先以粗框定位，若對話框內緣還有文字前景就擴大搜尋，再縮減為字形級多邊形，絕不把粗框或整個泡泡直接當遮罩。提供 mask_polygons 時則視為 Agent 已完成精確遮罩。高度重疊候選會略過，可安全重送。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "regions": .object([
                        "type": "array",
                        "description": "只提交目前遺漏的文字區域，每次最多 64 筆",
                        "items": agentRegion,
                        "minItems": 1,
                        "maxItems": 64
                    ])
                ], required: ["workspace_id", "page_id", "regions"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            workflowTool(
                name: "mangakitchen.page.translate",
                title: "翻譯對話文字",
                description: "步驟三在 MCP 為純 Agent 模式下不可用：後端不會呼叫內建圖生文模型翻譯。請改以 region.update 的 translated_text 逐區寫入譯文，再執行 page.compose。",
                workspaceID: workspaceID,
                pageIDs: pageIDs,
                annotations: idempotent
            ),
            workflowTool(
                name: "mangakitchen.page.compose",
                title: "合成翻譯頁面",
                description: "步驟四：依目前遮罩修補背景、排版並輸出圖片。",
                workspaceID: workspaceID,
                pageIDs: pageIDs,
                annotations: idempotent
            ),
            workflowTool(
                name: "mangakitchen.page.run_full",
                title: "一鍵處理完整頁",
                description: "保留的一鍵功能：依序執行遮罩偵測、翻譯與合成；頁面列表來自步驟一。",
                workspaceID: workspaceID,
                pageIDs: pageIDs,
                annotations: idempotent
            ),
            Tool(
                name: "mangakitchen.region.create",
                title: "新增對話區域",
                description: "新增一個可編輯文字與遮罩的區域。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "bounds": bounds
                ], required: ["workspace_id", "page_id", "bounds"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.region.update",
                title: "更新對話區域",
                description: "逐區調整原文、譯文、位置、對話框邊界、多邊形遮罩、字型、字級、字重與排字方向。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "region_id": property("string", "區域 UUID"),
                    "source_text": property("string", "來源原文"),
                    "translated_text": property("string", "翻譯文字"),
                    "translation_anchor": point,
                    "bounds": bounds,
                    "bubble_bounds": bubbleBounds,
                    "mask_polygons": maskPolygons,
                    "font_name": property("string", "macOS 字型名稱"),
                    "font_size": property("number", "固定字級 4...512；傳 null 等同 automatic_font_size: true，恢復自動配適"),
                    "font_weight": enumProperty(["regular", "bold"]),
                    "automatic_font_size": property("boolean", "true 代表恢復自動配適字級"),
                    "writing_direction": enumProperty(["automatic", "horizontal", "vertical"]),
                    "automatic_mask_enabled": property("boolean", "是否保留由 bounds 形成的自動遮罩")
                ], required: ["workspace_id", "page_id", "region_id"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.mask.add_stroke",
                title: "添加或擦除遮罩筆劃",
                description: "以正規化座標添加 add 或 erase 畫筆軌跡，並重新產生 mask。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "region_id": property("string", "區域 UUID"),
                    "mode": enumProperty(["add", "erase"]),
                    "diameter": property("number", "相對圖片短邊的筆刷直徑 0...1"),
                    "points": .object([
                        "type": "array",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "x": property("number", "0...1"),
                                "y": property("number", "0...1")
                            ]),
                            "required": ["x", "y"],
                            "additionalProperties": false
                        ]),
                        "minItems": 1
                    ])
                ], required: ["workspace_id", "page_id", "region_id", "mode", "diameter", "points"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.region.remove",
                title: "移除對話區域",
                description: "移除指定的對話區域、其文字映射與遮罩筆劃。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "region_id": property("string", "區域 UUID")
                ], required: ["workspace_id", "page_id", "region_id"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.mask.undo_stroke",
                title: "復原遮罩筆劃",
                description: "移除指定區域的最後一筆 add/erase 軌跡。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "region_id": property("string", "區域 UUID")
                ], required: ["workspace_id", "page_id", "region_id"]),
                annotations: mutating,
                outputSchema: genericOutputSchema
            )
        ]
    }

    private static func workflowTool(
        name: String,
        title: String,
        description: String,
        workspaceID: Value,
        pageIDs: Value,
        annotations: Tool.Annotations
    ) -> Tool {
        Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: objectSchema([
                "workspace_id": workspaceID,
                "page_ids": pageIDs
            ], required: ["workspace_id"]),
            annotations: annotations,
            outputSchema: genericOutputSchema
        )
    }

    private static func objectSchema(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false
        ])
    }

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func enumProperty(_ values: [String]) -> Value {
        .object([
            "type": "string",
            "enum": .array(values.map(Value.string))
        ])
    }

    private static var genericOutputSchema: Value {
        .object([
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object"
        ])
    }
}
