import Foundation
import MCP
import MangaKitchenCore

struct MangaKitchenMCPServer {
    static func makeHTTPHost(
        port: Int,
        allowedClients: [String],
        dataDirectoryPath: String?
    ) throws -> MangaKitchenMCPHTTPHost {
        let service = try MCPWorkflowService(dataDirectoryPath: dataDirectoryPath)
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
            instructions: "先用 mangakitchen.workspace.open 建立目錄專案；可保留多個 workspace_id 並用 workspace.list／activate 切換。載入 imageToText 模型後，可分別執行遮罩、翻譯、合成，或用 page.run_full 批次完成。",
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
                    let options = try await service.configure(
                        workspaceID: id,
                        targetLanguageCode: arguments["target_language_code"]?.stringValue,
                        readingDirection: reading,
                        writingDirection: writing,
                        fontName: arguments["font_name"]?.stringValue,
                        useImageToImageRestoration: arguments["use_image_to_image_restoration"]?.boolValue
                    )
                    return try success("工作流設定已更新。", options)

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
                        bounds: try optionalRect(arguments, "bounds"),
                        fontName: arguments["font_name"]?.stringValue,
                        fontSize: number(arguments["font_size"]),
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

    private static func optionalRect(_ arguments: [String: Value], _ key: String) throws -> NormalizedRect? {
        guard let raw = arguments[key] else { return nil }
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
            "description": "左上原點的正規化矩形",
            "properties": .object([
                "x": property("number", "0...1"),
                "y": property("number", "0...1"),
                "width": property("number", "0...1"),
                "height": property("number", "0...1")
            ]),
            "required": ["x", "y", "width", "height"],
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
                description: "遞迴掃描來源目錄、建立頁面列表，並載入輸出目錄內既有的 .str。",
                inputSchema: objectSchema([
                    "source_directory": property("string", "來源目錄的絕對路徑"),
                    "output_directory": property("string", "可選的輸出目錄絕對路徑"),
                    "target_language_code": property("string", "可選 BCP-47 目標語言，例如 zh-Hant")
                ], required: ["source_directory"]),
                annotations: idempotent,
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
                description: "調整目標語言、閱讀順序、預設排字方向、字型與圖生圖修補。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "target_language_code": property("string", "BCP-47 目標語言"),
                    "reading_direction": enumProperty(["rightToLeft", "leftToRight", "topToBottom"]),
                    "writing_direction": enumProperty(["automatic", "horizontal", "vertical"]),
                    "font_name": property("string", "macOS 字型名稱"),
                    "use_image_to_image_restoration": property("boolean", "是否優先使用圖生圖修補")
                ], required: ["workspace_id"]),
                annotations: idempotent,
                outputSchema: genericOutputSchema
            ),
            Tool(
                name: "mangakitchen.model.load",
                title: "載入本機模型",
                description: "從含 mangakitchen-model.json 的本機目錄載入 imageToText 或 imageToImage 模型。",
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
                title: "偵測文字與遮罩",
                description: "步驟二：辨識指定頁面的對話文字並產生初始遮罩。",
                workspaceID: workspaceID,
                pageIDs: pageIDs,
                annotations: idempotent
            ),
            workflowTool(
                name: "mangakitchen.page.translate",
                title: "翻譯對話文字",
                description: "步驟三：翻譯既有遮罩區域並寫入每頁 .str。",
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
                description: "逐區調整原文、譯文、位置、字型、字級、排字方向與自動遮罩。",
                inputSchema: objectSchema([
                    "workspace_id": workspaceID,
                    "page_id": property("string", "頁面 UUID"),
                    "region_id": property("string", "區域 UUID"),
                    "source_text": property("string", "OCR 原文"),
                    "translated_text": property("string", "翻譯文字"),
                    "bounds": bounds,
                    "font_name": property("string", "macOS 字型名稱"),
                    "font_size": property("number", "固定字級 4...512"),
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
