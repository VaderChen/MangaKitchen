import AppKit
import Combine
import Foundation
import MangaKitchenCore
import MangaKitchenRuntime
@preconcurrency import WebKit

@MainActor
final class HybridBridgeController: NSObject, ObservableObject {
    let preferences: AppPreferencesController
    let store: AppStore
    let mcpController: MCPServiceController
    let assetSchemeHandler = AssetSchemeHandler()
    let webUISchemeHandler = WebUISchemeHandler()
    @Published private(set) var interfaceLanguageCode = NativeLocalization.automaticLanguageCode

    private weak var webView: WKWebView?
    private var storeCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var mcpCancellable: AnyCancellable?
    private var pendingPush: Task<Void, Never>?
    private var pageReady = false

    init(
        preferences: AppPreferencesController,
        mcpController: MCPServiceController,
        store: AppStore
    ) {
        self.preferences = preferences
        self.mcpController = mcpController
        self.store = store
        super.init()
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStatePush()
            }
        }
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStatePush()
            }
        }
        mcpCancellable = mcpController.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStatePush()
            }
        }
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func pushState() {
        guard pageReady, let webView else { return }
        assetSchemeHandler.updatePages(store.pages)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(WebAppState(
                store: store,
                preferences: preferences.settings,
                mcpController: mcpController
            ))
            guard let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.MangaKitchenNative?.receiveState(\(json));")
        } catch {
            sendError(
                id: nil,
                message: localized("stateSyncFailed") + error.localizedDescription
            )
        }
    }

    private func scheduleStatePush() {
        guard pendingPush == nil else { return }
        pendingPush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.pendingPush = nil
            guard !Task.isCancelled else { return }
            self.pushState()
        }
    }

    private func handle(method: String, params: [String: Any]) throws -> Any? {
        switch method {
        case "bootstrap":
            pushState()
            return nil
        case "updateInterfaceLanguage":
            guard let setting = params["setting"] as? String,
                  AppPreferences.supportedInterfaceLanguages.contains(setting),
                  let languageCode = params["resolvedLanguage"] as? String,
                  let normalized = NativeLocalization.normalizedLanguageCode(languageCode) else {
                throw BridgeError.invalidParameters
            }
            preferences.setInterfaceLanguage(setting)
            interfaceLanguageCode = normalized
            return nil
        case "updateGlobalSettings":
            try updateGlobalSettings(params)
            return nil
        case "chooseDataDirectory":
            return chooseDirectory(
                title: localized("dataDirectoryPanelTitle"),
                prompt: localized("choose")
            )
        case "choosePreferredModelDirectory":
            return try choosePreferredModelDirectory(params)
        case "chooseModelDownloadDirectory":
            return try chooseModelDownloadDirectory(params)
        case "downloadPreferredModel":
            try downloadPreferredModel(params)
            return nil
        case "deleteInstalledModel":
            try deleteInstalledModel(params)
            return nil
        case "importPages", "chooseSourceDirectory":
            chooseSourceDirectory()
            return nil
        case "switchProject":
            guard let projectID = uuid(params["projectID"]) else {
                throw BridgeError.invalidParameters
            }
            store.activateProject(projectID)
            return nil
        case "deleteProject":
            guard let projectID = uuid(params["projectID"]) else {
                throw BridgeError.invalidParameters
            }
            store.deleteProject(projectID)
            return nil
        case "renameProject":
            guard let name = params["name"] as? String else {
                throw BridgeError.invalidParameters
            }
            store.renameActiveProject(name)
            return nil
        case "rescanSourceDirectory":
            store.rescanSourceDirectory()
            return nil
        case "resetPages":
            guard let rawPageIDs = params["pageIDs"] as? [String] else {
                throw BridgeError.invalidParameters
            }
            let pageIDs = rawPageIDs.compactMap(UUID.init(uuidString:))
            guard pageIDs.count == rawPageIDs.count else { throw BridgeError.invalidParameters }
            store.resetPages(pageIDs)
            return nil
        case "chooseOutputDirectory":
            return chooseOutputDirectory()
        case "chooseModel":
            chooseModelDirectory()
            return nil
        case "selectPage":
            guard let id = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.selectPage(id)
            return nil
        case "setPageSelection":
            guard let rawPageIDs = params["pageIDs"] as? [String] else {
                throw BridgeError.invalidParameters
            }
            let pageIDs = rawPageIDs.compactMap(UUID.init(uuidString:))
            guard pageIDs.count == rawPageIDs.count else { throw BridgeError.invalidParameters }
            store.setPageSelection(
                pageIDs: pageIDs,
                activePageID: uuid(params["activePageID"])
            )
            return nil
        case "selectAllPages":
            store.selectAllPages()
            return nil
        case "clearPageSelection":
            store.clearPageSelection()
            return nil
        case "clearPages":
            store.clearPages()
            return nil
        case "updateSettings":
            try updateSettings(params)
            return nil
        case "upsertGlossaryEntry":
            return try upsertGlossaryEntry(params)
        case "removeGlossaryEntry":
            guard let entryID = uuid(params["entryID"]) else {
                throw BridgeError.invalidParameters
            }
            store.removeGlossaryEntry(entryID)
            return nil
        case "detectMasksAll":
            store.detectMasksForAllPages()
            return nil
        case "detectMasksSelected":
            store.detectMasksForSelectedPage()
            return nil
        case "translateAll":
            store.translateAllPages()
            return nil
        case "translateSelected":
            store.translateSelectedPage()
            return nil
        case "composeAll":
            store.composeAllPages()
            return nil
        case "composeSelected":
            store.composeSelectedPage()
            return nil
        case "processAll":
            store.processAllPages()
            return nil
        case "processSelected":
            store.processSelectedPage()
            return nil
        case "runBatch":
            guard let rawOperation = params["operation"] as? String,
                  let operation = BatchOperation(rawValue: rawOperation),
                  let rawPageIDs = params["pageIDs"] as? [String] else {
                throw BridgeError.invalidParameters
            }
            let pageIDs = rawPageIDs.compactMap(UUID.init(uuidString:))
            guard pageIDs.count == rawPageIDs.count else { throw BridgeError.invalidParameters }
            let jobID = store.enqueueBatch(operation: operation, pageIDs: pageIDs)
            return jobID.map { ["jobID": $0.uuidString] } ?? [:]
        case "cancelProcessing":
            store.cancelProcessing()
            return nil
        case "retryFailedBatchJob":
            guard let jobID = uuid(params["jobID"]) else { throw BridgeError.invalidParameters }
            store.retryFailedBatchJob(jobID)
            return nil
        case "clearFinishedBatchJobs":
            store.clearFinishedBatchJobs()
            return nil
        case "cancelModelDownload":
            store.cancelModelDownload()
            return nil
        case "createRegion", "createMaskRegion":
            return try createRegion(params)
        case "duplicateRegion":
            return try duplicateRegion(params)
        case "appendMaskStroke":
            try appendMaskStroke(params)
            return nil
        case "undoMaskStroke":
            try undoMaskStroke(params)
            return nil
        case "redoMaskStroke":
            try redoMaskStroke(params)
            return nil
        case "removeRegion":
            try removeRegion(params)
            return nil
        case "updateRegion":
            try updateRegion(params)
            return nil
        case "revealOutput":
            try revealOutput(params)
            return nil
        case "clearStatus":
            store.statusMessage = nil
            return nil
        default:
            throw BridgeError.unknownMethod(method)
        }
    }

    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.title = localized("sourcePanelTitle")
        panel.prompt = localized("createProject")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.openProject(from: url)
    }

    private func chooseOutputDirectory() -> [String: Any]? {
        let panel = NSOpenPanel()
        panel.title = localized("outputPanelTitle")
        panel.prompt = localized("choose")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let selectedURL = url.standardizedFileURL
        store.setOutputDirectory(selectedURL)
        guard store.outputDirectoryURL == selectedURL else { return nil }
        return ["path": selectedURL.path]
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.title = localized("modelPanelTitle")
        panel.prompt = localized("loadModel")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.loadModel(from: url)
    }

    private func chooseDirectory(title: String, prompt: String) -> [String: Any]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ["path": url.standardizedFileURL.path]
    }

    private func choosePreferredModelDirectory(_ params: [String: Any]) throws -> [String: Any]? {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability) else {
            throw BridgeError.invalidParameters
        }
        guard let selected = chooseDirectory(
            title: localized(capability == .imageToText
                ? "imageToTextModelPanelTitle"
                : "imageToImageModelPanelTitle"),
            prompt: localized("choose")
        ), let path = selected["path"] as? String else { return nil }
        let manifest = try ModelManifest.load(from: URL(fileURLWithPath: path))
        guard manifest.capability == capability else {
            throw BridgeError.modelCapabilityMismatch(capability.rawValue)
        }
        return selected
    }

    private func chooseModelDownloadDirectory(_ params: [String: Any]) throws -> [String: Any]? {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              capability == .imageToText else {
            throw BridgeError.invalidParameters
        }
        guard let selected = chooseDirectory(
            title: localized("imageToTextModelDownloadDirectoryPanelTitle"),
            prompt: localized("choose")
        ), let path = selected["path"] as? String else { return nil }
        let selectedURL = URL(fileURLWithPath: path).standardizedFileURL
        if let model = DownloadableModelCatalog.model(
            matching: selectedURL,
            capability: capability
        ), DownloadableModelCatalog.isCompleteModelDirectory(selectedURL) {
            return [
                "path": selectedURL.deletingLastPathComponent().path,
                "variant": model.id,
            ]
        }
        return selected
    }

    private func downloadPreferredModel(_ params: [String: Any]) throws {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              capability == .imageToText,
              let variantID = params["variantID"] as? String,
              let model = DownloadableModelCatalog.model(id: variantID, capability: capability),
              let directoryPath = preferences.settings.imageToTextModelDownloadDirectoryPath else {
            throw BridgeError.invalidParameters
        }
        let storageDirectoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        store.downloadModel(model, to: storageDirectoryURL) { [weak self] result in
            guard let self, case let .success(modelDirectoryURL) = result else { return }
            let previous = preferences.settings
            var updated = previous
            updated.imageToTextModelDownloadDirectoryPath = storageDirectoryURL.path
            updated.imageToTextModelVariant = model.id
            updated.imageToTextModelPath = modelDirectoryURL.path
            preferences.replace(with: updated)
            let current = preferences.settings
            if previous.imageToTextModelPath != current.imageToTextModelPath {
                store.applyPreferredModels(
                    imageToTextPath: current.imageToTextModelPath,
                    imageToImagePath: current.imageToImageModelPath
                )
            }
        }
    }

    private func deleteInstalledModel(_ params: [String: Any]) throws {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              capability == .imageToText,
              let variantID = params["variantID"] as? String,
              let model = DownloadableModelCatalog.model(id: variantID, capability: capability),
              let directoryPath = preferences.settings.imageToTextModelDownloadDirectoryPath else {
            throw BridgeError.invalidParameters
        }
        let storageDirectoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        try store.deleteInstalledModel(model, from: storageDirectoryURL)

        let previous = preferences.settings
        var updated = previous
        let deletedDirectoryURL = DownloadableModelCatalog.modelDirectory(
            storageDirectoryURL: storageDirectoryURL,
            model: model
        )
        if previous.imageToTextModelPath.map({
            URL(fileURLWithPath: $0).standardizedFileURL == deletedDirectoryURL
        }) == true {
            updated.imageToTextModelPath = nil
        }
        preferences.replace(with: updated)
        let current = preferences.settings
        if previous.imageToTextModelPath != current.imageToTextModelPath {
            store.applyPreferredModels(
                imageToTextPath: current.imageToTextModelPath,
                imageToImagePath: current.imageToImageModelPath
            )
        }
    }

    private func updateGlobalSettings(_ params: [String: Any]) throws {
        guard let interfaceLanguage = params["interfaceLanguage"] as? String,
              AppPreferences.supportedInterfaceLanguages.contains(interfaceLanguage),
              let colorScheme = params["colorScheme"] as? String,
              AppPreferences.supportedColorSchemes.contains(colorScheme),
              let imageCompositingRaw = params["imageCompositingBackend"] as? String,
              let imageCompositingBackend = ImageCompositingBackend(rawValue: imageCompositingRaw),
              let imageToTextModelVariant = params["imageToTextModelVariant"] as? String,
              DownloadableModelCatalog.model(
                id: imageToTextModelVariant,
                capability: .imageToText
              ) != nil,
              let mcpEnabled = params["mcpEnabled"] as? Bool,
              let mcpPort = integer(params["mcpPort"]),
              (1...65_535).contains(mcpPort),
              let allowedClients = params["mcpAllowedClients"] as? [String] else {
            throw BridgeError.invalidParameters
        }
        try MCPClientAllowlist.validate(allowedClients)
        let previous = preferences.settings
        var updated = previous
        updated.interfaceLanguage = interfaceLanguage
        updated.colorScheme = colorScheme
        updated.dataDirectoryPath = params["dataDirectoryPath"] as? String
        updated.imageCompositingBackend = imageCompositingBackend
        updated.imageToTextModelPath = params["imageToTextModelPath"] as? String
        updated.imageToTextModelDownloadDirectoryPath = params[
            "imageToTextModelDownloadDirectoryPath"
        ] as? String
        updated.imageToTextModelVariant = imageToTextModelVariant
        updated.imageToImageModelPath = params["imageToImageModelPath"] as? String
        updated.mcpEnabled = mcpEnabled
        updated.mcpPort = mcpPort
        updated.mcpAllowedClients = allowedClients
        preferences.replace(with: updated)

        let current = preferences.settings
        if previous.resolvedImageCompositingBackend != current.resolvedImageCompositingBackend {
            store.setImageCompositingBackend(current.resolvedImageCompositingBackend)
        }
        if previous.imageToTextModelPath != current.imageToTextModelPath
            || previous.imageToImageModelPath != current.imageToImageModelPath {
            store.applyPreferredModels(
                imageToTextPath: current.imageToTextModelPath,
                imageToImagePath: current.imageToImageModelPath
            )
        }
        if previous.dataDirectoryPath != current.dataDirectoryPath {
            store.statusMessage = localized("dataDirectoryRestartRequired")
        }
    }

    private func updateSettings(_ params: [String: Any]) throws {
        var value = store.options
        if let code = params["targetLanguageCode"] as? String {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BridgeError.invalidParameters }
            value.targetLanguageCode = trimmed
        }
        if let codes = params["sourceLanguageCodes"] as? [String] {
            value.sourceLanguageCodes = codes.filter { !$0.isEmpty }
        }
        if let raw = params["readingDirection"] as? String,
           let direction = ReadingDirection(rawValue: raw) {
            value.readingDirection = direction
        }
        if let raw = params["writingDirection"] as? String,
           let direction = WritingDirection(rawValue: raw) {
            value.defaultStyle.writingDirection = direction
        }
        if let fontName = params["fontName"] as? String, !fontName.isEmpty {
            value.defaultStyle.fontName = fontName
        }
        if let enabled = params["fineScanEnabled"] as? Bool {
            value.fineScanEnabled = enabled
        }
        if let amount = double(params["maskExpansion"]), amount.isFinite {
            value.maskExpansion = min(max(amount, 0), 0.75)
        }
        value.useImageToImageRestoration = false
        if let preserve = params["preserveUntranslatedRegions"] as? Bool {
            value.preserveUntranslatedRegions = preserve
        }
        store.setOptions(value)
    }

    private func upsertGlossaryEntry(_ params: [String: Any]) throws -> [String: Any] {
        guard let sourceTerm = params["sourceTerm"] as? String,
              let rawTranslations = params["translations"] as? [String: Any] else {
            throw BridgeError.invalidParameters
        }
        var translations: [String: String] = [:]
        for (languageCode, value) in rawTranslations {
            guard let term = value as? String else { throw BridgeError.invalidParameters }
            translations[languageCode] = term
        }
        guard let entryID = store.upsertGlossaryEntry(
            entryID: uuid(params["entryID"]),
            sourceTerm: sourceTerm,
            translations: translations,
            note: params["note"] as? String
        ) else {
            throw BridgeError.invalidParameters
        }
        return ["entryID": entryID.uuidString]
    }

    private func updateRegion(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        let bounds: NormalizedRect?
        if let raw = params["bounds"] as? [String: Any],
           let x = double(raw["x"]),
           let y = double(raw["y"]),
           let width = double(raw["width"]),
           let height = double(raw["height"]) {
            bounds = NormalizedRect(x: x, y: y, width: width, height: height)
        } else {
            bounds = nil
        }
        let direction = (params["writingDirection"] as? String)
            .flatMap(WritingDirection.init(rawValue:))
        let fontWeight = (params["fontWeight"] as? String)
            .flatMap(DialogueFontWeight.init(rawValue:))
        store.updateRegion(
            pageID: pageID,
            regionID: regionID,
            sourceText: params["sourceText"] as? String,
            translatedText: params["translatedText"] as? String,
            translationAnchor: normalizedPoint(params["translationAnchor"]),
            translationBounds: normalizedRect(params["translationBounds"]),
            bounds: bounds,
            bubbleBounds: normalizedRect(params["bubbleBounds"]),
            maskPolygons: normalizedPolygons(params["maskPolygons"]),
            fontName: params["fontName"] as? String,
            fontSize: double(params["fontSize"]),
            fontWeight: fontWeight,
            useAutomaticFontSize: params["useAutomaticFontSize"] as? Bool,
            writingDirection: direction,
            automaticMaskEnabled: params["automaticMaskEnabled"] as? Bool
        )
    }

    private func createRegion(_ params: [String: Any]) throws -> [String: Any] {
        guard let pageID = uuid(params["pageID"]),
              let bounds = normalizedRect(params["bounds"]),
              let regionID = store.createRegion(
                pageID: pageID,
                bounds: bounds,
                sourceText: params["sourceText"] as? String ?? "",
                translatedText: params["translatedText"] as? String ?? "",
                automaticMaskEnabled: params["automaticMaskEnabled"] as? Bool ?? true
              ) else {
            throw BridgeError.invalidParameters
        }
        return ["regionID": regionID.uuidString]
    }

    private func duplicateRegion(_ params: [String: Any]) throws -> [String: Any] {
        guard let pageID = uuid(params["pageID"]),
              let sourceRegionID = uuid(params["regionID"]),
              let regionID = store.duplicateRegion(pageID: pageID, regionID: sourceRegionID) else {
            throw BridgeError.invalidParameters
        }
        return ["regionID": regionID.uuidString]
    }

    private func appendMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]),
              let rawMode = params["mode"] as? String,
              let mode = MaskStrokeMode(rawValue: rawMode),
              let diameter = double(params["diameter"]),
              let rawPoints = params["points"] as? [[String: Any]] else {
            throw BridgeError.invalidParameters
        }
        let points = rawPoints.compactMap { value -> NormalizedPoint? in
            guard let x = double(value["x"]), let y = double(value["y"]),
                  x.isFinite, y.isFinite else { return nil }
            return NormalizedPoint(x: x, y: y)
        }
        guard points.count == rawPoints.count, !points.isEmpty, diameter.isFinite else {
            throw BridgeError.invalidParameters
        }
        store.appendMaskStroke(
            pageID: pageID,
            regionID: regionID,
            mode: mode,
            points: points,
            diameter: diameter
        )
    }

    private func undoMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.undoMaskStroke(pageID: pageID, regionID: regionID)
    }

    private func redoMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.redoMaskStroke(pageID: pageID, regionID: regionID)
    }

    private func removeRegion(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.removeRegion(pageID: pageID, regionID: regionID)
    }

    private func revealOutput(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let outputURL = store.pages.first(where: { $0.id == pageID })?.outputURL else {
            throw BridgeError.invalidParameters
        }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    private func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func normalizedRect(_ value: Any?) -> NormalizedRect? {
        guard let raw = value as? [String: Any],
              let x = double(raw["x"]),
              let y = double(raw["y"]),
              let width = double(raw["width"]),
              let height = double(raw["height"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func normalizedPoint(_ value: Any?) -> NormalizedPoint? {
        guard let raw = value as? [String: Any],
              let x = double(raw["x"]),
              let y = double(raw["y"]),
              x.isFinite, y.isFinite else { return nil }
        return NormalizedPoint(x: x, y: y).clamped()
    }

    private func normalizedPolygons(_ value: Any?) -> [[NormalizedPoint]]? {
        guard let rawPolygons = value as? [Any] else { return nil }
        var result: [[NormalizedPoint]] = []
        for rawPolygon in rawPolygons {
            guard let rawPoints = rawPolygon as? [Any], rawPoints.count >= 3 else { return nil }
            var points: [NormalizedPoint] = []
            for rawPoint in rawPoints {
                guard let object = rawPoint as? [String: Any],
                      let x = double(object["x"]),
                      let y = double(object["y"]),
                      x.isFinite, y.isFinite else { return nil }
                points.append(NormalizedPoint(x: x, y: y).clamped())
            }
            result.append(points)
        }
        return result
    }

    private func localized(_ key: String) -> String {
        NativeLocalization.text(key, languageCode: interfaceLanguageCode)
    }

    private func sendResponse(id: String, payload: Any?) {
        var value: [String: Any] = ["kind": "response", "id": id, "ok": true]
        if let payload { value["payload"] = payload }
        sendJavaScriptObject(value)
    }

    private func sendError(id: String?, message: String) {
        var value: [String: Any] = ["kind": "response", "ok": false, "error": message]
        if let id { value["id"] = id }
        sendJavaScriptObject(value)
    }

    private func sendJavaScriptObject(_ object: [String: Any]) {
        guard let webView,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.MangaKitchenNative?.receive(\(json));")
    }
}

extension HybridBridgeController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mangakitchen",
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }
        let id = body["id"] as? String
        let params = body["params"] as? [String: Any] ?? [:]
        do {
            let payload = try handle(method: method, params: params)
            if let id { sendResponse(id: id, payload: payload) }
        } catch {
            sendError(id: id, message: error.localizedDescription)
        }
    }
}

extension HybridBridgeController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        pushState()
    }
}

private enum BridgeError: LocalizedError {
    case invalidParameters
    case unknownMethod(String)
    case modelCapabilityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidParameters: "Bridge 參數不完整或格式錯誤。"
        case let .unknownMethod(method): "未知的 Bridge 方法：\(method)"
        case let .modelCapabilityMismatch(capability):
            "所選模型不符合預期類型：\(capability)。"
        }
    }
}
