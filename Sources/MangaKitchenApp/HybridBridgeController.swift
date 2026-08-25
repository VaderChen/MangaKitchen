import AppKit
import Combine
import Foundation
import ImageIO
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
    private var reasoningStreamCancellable: AnyCancellable?
    private var systemMetricsCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var mcpCancellable: AnyCancellable?
    private var pendingPush: Task<Void, Never>?
    private var pendingTransientPush: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var hasStartedUpdateCheck = false
    private var availableUpdate: GitHubReleaseUpdate?
    private var manualUpdateCheck: WebUpdateCheckState?
    private var pageReady = false
    private lazy var commandHandler = WebBridgeCommandHandler(controller: self)

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
        reasoningStreamCancellable = store.modelReasoningStream.objectWillChange.sink {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTransientStatePush()
            }
        }
        systemMetricsCancellable = store.systemMetricsDidChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTransientStatePush()
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
                mcpController: mcpController,
                availableUpdate: availableUpdate,
                updateCheck: manualUpdateCheck
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

    private func pushTransientState() {
        guard pageReady, let webView else { return }
        do {
            let data = try JSONEncoder().encode(WebTransientState(store: store))
            guard let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.MangaKitchenNative?.receiveTransientState(\(json));"
            )
        } catch {
            // Transient state 不影響主流程，編碼失敗時等待下一次更新即可。
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

    private func scheduleTransientStatePush() {
        guard pendingTransientPush == nil else { return }
        pendingTransientPush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.pendingTransientPush = nil
            guard !Task.isCancelled else { return }
            self.pushTransientState()
        }
    }


    func chooseSourceDirectory() {
        guard let urls = WebBridgePanelService.chooseEntries(
            title: localized("sourcePanelTitle"),
            prompt: localized("createProject"),
            allowsMultipleSelection: true,
            canChooseFiles: true,
            canChooseDirectories: true
        ) else { return }
        store.importPages(from: urls)
    }

    func chooseAdditionalPages() {
        guard let urls = WebBridgePanelService.chooseEntries(
            title: localized("additionalPagesPanelTitle"),
            prompt: localized("addPages"),
            allowsMultipleSelection: true,
            canChooseFiles: true,
            canChooseDirectories: true
        ) else { return }
        store.appendPages(from: urls)
    }

    func exportPSD(_ params: [String: Any]) throws {
        let pageIDs = (params["pageIDs"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? Array(store.selectedPageIDs)
        guard !pageIDs.isEmpty else { throw BridgeError.invalidParameters }
        guard let url = WebBridgePanelService.chooseDirectory(
            title: "選擇 PSD 輸出資料夾",
            prompt: localized("choose")
        ) else { return }
        store.exportPSD(pageIDs: pageIDs, to: url)
    }

    func chooseOutputDirectory() -> [String: Any]? {
        guard let selectedURL = WebBridgePanelService.chooseDirectory(
            title: localized("outputPanelTitle"),
            prompt: localized("choose")
        ) else { return nil }
        store.setOutputDirectory(selectedURL)
        guard store.outputDirectoryURL == selectedURL else { return nil }
        return ["path": selectedURL.path]
    }

    func chooseModelDirectory() {
        guard let url = WebBridgePanelService.chooseDirectory(
            title: localized("modelPanelTitle"),
            prompt: localized("loadModel"),
            canCreateDirectories: false
        ) else { return }
        store.loadModel(from: url)
    }

    func chooseDirectory(title: String, prompt: String) -> [String: Any]? {
        guard let url = WebBridgePanelService.chooseDirectory(
            title: title,
            prompt: prompt
        ) else { return nil }
        return ["path": url.path]
    }

    func choosePreferredModelDirectory(_ params: [String: Any]) throws -> [String: Any]? {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              capability != .textToText else {
            throw BridgeError.invalidParameters
        }
        let panelTitleKey: String
        switch capability {
        case .textToText: throw BridgeError.invalidParameters
        case .imageToText: panelTitleKey = "imageToTextModelPanelTitle"
        case .imageColorization: panelTitleKey = "imageColorizationModelPanelTitle"
        case .superResolution: panelTitleKey = "superResolutionModelPanelTitle"
        case .imageToImage: panelTitleKey = "imageToImageModelPanelTitle"
        }
        guard let selected = chooseDirectory(
            title: localized(panelTitleKey),
            prompt: localized("choose")
        ), let path = selected["path"] as? String else { return nil }
        let manifest = try ModelManifest.load(from: URL(fileURLWithPath: path))
        guard manifest.capability == capability else {
            throw BridgeError.modelCapabilityMismatch(capability.rawValue)
        }
        return selected
    }

    func chooseModelDownloadDirectory(_ params: [String: Any]) throws -> [String: Any]? {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              [.imageToText, .imageColorization, .superResolution].contains(capability) else {
            throw BridgeError.invalidParameters
        }
        let panelTitleKey: String
        switch capability {
        case .textToText: throw BridgeError.invalidParameters
        case .imageToText: panelTitleKey = "imageToTextModelDownloadDirectoryPanelTitle"
        case .imageColorization: panelTitleKey = "imageColorizationModelDownloadDirectoryPanelTitle"
        case .superResolution: panelTitleKey = "superResolutionModelDownloadDirectoryPanelTitle"
        case .imageToImage: throw BridgeError.invalidParameters
        }
        guard let selected = chooseDirectory(
            title: localized(panelTitleKey),
            prompt: localized("choose")
        ), let path = selected["path"] as? String else { return nil }
        let selectedURL = URL(fileURLWithPath: path).standardizedFileURL
        if let model = DownloadableModelCatalog.model(
            matching: selectedURL,
            capability: capability
        ), DownloadableModelCatalog.isCompleteModelDirectory(selectedURL, model: model) {
            return [
                "path": selectedURL.deletingLastPathComponent().path,
                "variant": model.id,
            ]
        }
        return selected
    }

    func downloadPreferredModel(_ params: [String: Any]) throws {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              [.imageToText, .imageColorization, .superResolution].contains(capability),
              let variantID = params["variantID"] as? String,
              let model = DownloadableModelCatalog.model(id: variantID, capability: capability)
        else {
            throw BridgeError.invalidParameters
        }
        let directoryPath: String?
        switch capability {
        case .textToText:
            throw BridgeError.invalidParameters
        case .imageToText:
            directoryPath = preferences.settings.imageToTextModelDownloadDirectoryPath
        case .imageColorization:
            directoryPath = preferences.settings.imageColorizationModelDownloadDirectoryPath
        case .superResolution:
            directoryPath = preferences.settings.superResolutionModelDownloadDirectoryPath
        case .imageToImage:
            directoryPath = nil
        }
        guard let directoryPath else { throw BridgeError.invalidParameters }
        let storageDirectoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        store.downloadModel(model, to: storageDirectoryURL) { [weak self] result in
            guard let self, case let .success(modelDirectoryURL) = result else { return }
            let previous = preferences.settings
            var updated = previous
            if capability == .imageToText {
                updated.imageToTextModelDownloadDirectoryPath = storageDirectoryURL.path
                updated.imageToTextModelVariant = model.id
                updated.imageToTextModelPath = modelDirectoryURL.path
            } else if capability == .imageColorization {
                updated.imageColorizationModelDownloadDirectoryPath = storageDirectoryURL.path
                updated.imageColorizationModelVariant = model.id
                updated.imageColorizationModelPath = modelDirectoryURL.path
            } else {
                updated.superResolutionModelDownloadDirectoryPath = storageDirectoryURL.path
                updated.superResolutionModelVariant = model.id
                updated.superResolutionModelPath = modelDirectoryURL.path
            }
            preferences.replace(with: updated)
            let current = preferences.settings
            if previous.imageToTextModelPath != current.imageToTextModelPath
                || previous.imageColorizationModelPath != current.imageColorizationModelPath
                || previous.superResolutionModelPath != current.superResolutionModelPath {
                store.applyPreferredModels(
                    imageToTextPath: current.imageToTextModelPath,
                    imageToImagePath: current.imageToImageModelPath,
                    imageColorizationPath: current.imageColorizationModelPath,
                    superResolutionPath: current.superResolutionModelPath
                )
            }
        }
    }

    func deleteInstalledModel(_ params: [String: Any]) throws {
        guard let rawCapability = params["capability"] as? String,
              let capability = ModelCapability(rawValue: rawCapability),
              [.imageToText, .imageColorization, .superResolution].contains(capability),
              let variantID = params["variantID"] as? String,
              let model = DownloadableModelCatalog.model(id: variantID, capability: capability)
        else {
            throw BridgeError.invalidParameters
        }
        let directoryPath: String?
        switch capability {
        case .textToText:
            throw BridgeError.invalidParameters
        case .imageToText:
            directoryPath = preferences.settings.imageToTextModelDownloadDirectoryPath
        case .imageColorization:
            directoryPath = preferences.settings.imageColorizationModelDownloadDirectoryPath
        case .superResolution:
            directoryPath = preferences.settings.superResolutionModelDownloadDirectoryPath
        case .imageToImage:
            directoryPath = nil
        }
        guard let directoryPath else { throw BridgeError.invalidParameters }
        let storageDirectoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        try store.deleteInstalledModel(model, from: storageDirectoryURL)

        let previous = preferences.settings
        var updated = previous
        let deletedDirectoryURL = DownloadableModelCatalog.modelDirectory(
            storageDirectoryURL: storageDirectoryURL,
            model: model
        )
        if capability == .imageToText {
            if previous.imageToTextModelPath.map({
                URL(fileURLWithPath: $0).standardizedFileURL == deletedDirectoryURL
            }) == true {
                updated.imageToTextModelPath = nil
            }
        } else if capability == .imageColorization {
            if previous.imageColorizationModelPath.map({
                URL(fileURLWithPath: $0).standardizedFileURL == deletedDirectoryURL
            }) == true {
                updated.imageColorizationModelPath = nil
            }
        } else if previous.superResolutionModelPath.map({
            URL(fileURLWithPath: $0).standardizedFileURL == deletedDirectoryURL
        }) == true {
            updated.superResolutionModelPath = nil
        }
        preferences.replace(with: updated)
        let current = preferences.settings
        if previous.imageToTextModelPath != current.imageToTextModelPath
            || previous.imageColorizationModelPath != current.imageColorizationModelPath
            || previous.superResolutionModelPath != current.superResolutionModelPath {
            store.applyPreferredModels(
                imageToTextPath: current.imageToTextModelPath,
                imageToImagePath: current.imageToImageModelPath,
                imageColorizationPath: current.imageColorizationModelPath,
                superResolutionPath: current.superResolutionModelPath
            )
        }
    }

    func updateGlobalSettings(_ params: [String: Any]) throws {
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
              let imageColorizationModelVariant = params["imageColorizationModelVariant"] as? String,
              DownloadableModelCatalog.model(
                id: imageColorizationModelVariant,
                capability: .imageColorization
              ) != nil,
              let modelThinkingEnabled = params["modelThinkingEnabled"] as? Bool,
              let superResolutionModelVariant = params["superResolutionModelVariant"] as? String,
              DownloadableModelCatalog.model(
                id: superResolutionModelVariant,
                capability: .superResolution
              ) != nil,
              let automaticSuperResolutionEnabled = params["automaticSuperResolutionEnabled"] as? Bool,
              let mcpEnabled = params["mcpEnabled"] as? Bool,
              let mcpPort = integer(params["mcpPort"]),
              (1...65_535).contains(mcpPort),
              let allowedClients = params["mcpAllowedClients"] as? [String] else {
            throw BridgeError.invalidParameters
        }
        try MCPClientAllowlist.validate(allowedClients)
        let previous = preferences.settings
        if previous.modelThinkingEnabled != modelThinkingEnabled,
           store.isProcessing {
            throw BridgeError.processingInProgress
        }
        var updated = previous
        updated.interfaceLanguage = interfaceLanguage
        updated.colorScheme = colorScheme
        if let selectionColorHex = params["selectionColorHex"] as? String {
            updated.selectionColorHex = DialogueStyle.normalizedHexColor(
                selectionColorHex,
                fallback: previous.selectionColorHex
            )
        }
        updated.dataDirectoryPath = params["dataDirectoryPath"] as? String
        updated.defaultOutputDirectoryPath = params["defaultOutputDirectoryPath"] as? String
        updated.imageCompositingBackend = imageCompositingBackend
        updated.imageToTextModelPath = params["imageToTextModelPath"] as? String
        updated.imageToTextModelDownloadDirectoryPath = params[
            "imageToTextModelDownloadDirectoryPath"
        ] as? String
        updated.imageToTextModelVariant = imageToTextModelVariant
        updated.modelThinkingEnabled = modelThinkingEnabled
        updated.imageToImageModelPath = params["imageToImageModelPath"] as? String
        updated.imageColorizationModelPath = params["imageColorizationModelPath"] as? String
        updated.imageColorizationModelDownloadDirectoryPath = params[
            "imageColorizationModelDownloadDirectoryPath"
        ] as? String
        updated.imageColorizationModelVariant = imageColorizationModelVariant
        updated.automaticSuperResolutionEnabled = automaticSuperResolutionEnabled
        updated.superResolutionModelPath = params["superResolutionModelPath"] as? String
        updated.superResolutionModelDownloadDirectoryPath = params[
            "superResolutionModelDownloadDirectoryPath"
        ] as? String
        updated.superResolutionModelVariant = superResolutionModelVariant
        updated.mcpEnabled = mcpEnabled
        updated.mcpPort = mcpPort
        updated.mcpAllowedClients = allowedClients
        preferences.replace(with: updated)

        let current = preferences.settings
        if previous.resolvedImageCompositingBackend != current.resolvedImageCompositingBackend {
            store.setImageCompositingBackend(current.resolvedImageCompositingBackend)
        }
        if previous.imageToTextModelPath != current.imageToTextModelPath
            || previous.imageToImageModelPath != current.imageToImageModelPath
            || previous.imageColorizationModelPath != current.imageColorizationModelPath
            || previous.superResolutionModelPath != current.superResolutionModelPath {
            store.applyPreferredModels(
                imageToTextPath: current.imageToTextModelPath,
                imageToImagePath: current.imageToImageModelPath,
                imageColorizationPath: current.imageColorizationModelPath,
                superResolutionPath: current.superResolutionModelPath
            )
        }
        if previous.automaticSuperResolutionEnabled != current.automaticSuperResolutionEnabled {
            store.setAutomaticSuperResolutionEnabled(current.automaticSuperResolutionEnabled)
        }
        if previous.modelThinkingEnabled != current.modelThinkingEnabled {
            store.setModelThinkingEnabled(current.modelThinkingEnabled)
        }
        if previous.dataDirectoryPath != current.dataDirectoryPath {
            store.statusMessage = localized("dataDirectoryRestartRequired")
        }
        if previous.defaultOutputDirectoryPath != current.defaultOutputDirectoryPath {
            let outputURL = current.defaultOutputDirectoryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            store.setDefaultOutputDirectory(outputURL)
        }
    }

    func updateSettings(_ params: [String: Any]) throws {
        var value = store.options
        let previousImageToTextModelPath = preferences.settings.imageToTextModelPath
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
        if let raw = params["textLocalizationMethod"] as? String,
           let method = TextLocalizationMethod(rawValue: raw) {
            value.textLocalizationMethod = method
        }
        value.translationModelMethod = .imageToText
        if let variantID = params["imageToTextModelVariant"] as? String,
           DownloadableModelCatalog.model(id: variantID, capability: .imageToText) != nil {
            var globalSettings = preferences.settings
            globalSettings.imageToTextModelVariant = variantID
            preferences.replace(with: globalSettings)
            let currentImageToTextModelPath = preferences.settings.imageToTextModelPath
            if previousImageToTextModelPath != currentImageToTextModelPath {
                store.applyPreferredModels(
                    imageToTextPath: currentImageToTextModelPath,
                    imageToImagePath: preferences.settings.imageToImageModelPath,
                    imageColorizationPath: preferences.settings.imageColorizationModelPath,
                    superResolutionPath: preferences.settings.superResolutionModelPath
                )
            }
        }
        if let raw = params["writingDirection"] as? String,
           let direction = WritingDirection(rawValue: raw) {
            value.defaultStyle.writingDirection = direction
        }
        if let fontName = params["fontName"] as? String, !fontName.isEmpty {
            value.defaultStyle.fontName = fontName
        }
        value.defaultStyle.fontName = FontFamilyCatalog.normalizedFontName(
            value.defaultStyle.fontName,
            for: value.resolvedTargetLanguageCode
        )
        if let enabled = params["fineScanEnabled"] as? Bool {
            value.fineScanEnabled = enabled
        }
        if let amount = double(params["maskExpansion"]), amount.isFinite {
            value.maskExpansion = min(max(amount, 0), 0.75)
        }
        if let eraseColorHex = params["eraseColorHex"] as? String {
            value.eraseColorHex = ProcessingOptions.normalizedEraseColor(
                eraseColorHex,
                fallback: value.eraseColorHex
            )
        }
        value.useImageToImageRestoration = false
        if let preserve = params["preserveUntranslatedRegions"] as? Bool {
            value.preserveUntranslatedRegions = preserve
        }
        if let rawQuality = params["translationQuality"] as? [String: Any] {
            var quality = value.translationQuality
            if let enabled = rawQuality["usePageContext"] as? Bool {
                quality.usePageContext = enabled
            }
            if let enabled = rawQuality["reviewPassEnabled"] as? Bool {
                quality.reviewPassEnabled = enabled
            }
            if let enabled = rawQuality["qualityCheckEnabled"] as? Bool {
                quality.qualityCheckEnabled = enabled
            }
            if let enabled = rawQuality["preserveLiteralTranslation"] as? Bool {
                quality.preserveLiteralTranslation = enabled
            }
            if let rawMode = rawQuality["lengthMode"] as? String,
               let mode = TranslationLengthMode(rawValue: rawMode) {
                quality.lengthMode = mode
            }
            if let styleGuide = rawQuality["styleGuide"] as? String {
                quality.styleGuide = String(
                    styleGuide.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)
                )
            }
            value.translationQuality = quality
        }
        if let raw = params["colorizationColorRange"] as? String,
           let colorRange = ColorizationColorRange(rawValue: raw) {
            value.colorizationColorRange = colorRange
        }
        if let raw = params["colorizationMode"] as? String,
           let mode = ColorizationMode(rawValue: raw) {
            value.colorizationMode = mode
        }
        store.setOptions(value)
    }

    func samplePageColor(_ params: [String: Any]) throws -> [String: String] {
        guard let pageID = uuid(params["pageID"]),
              let page = store.pages.first(where: { $0.id == pageID }),
              let normalizedX = double(params["x"]), normalizedX.isFinite,
              let normalizedY = double(params["y"]), normalizedY.isFinite,
              let source = CGImageSourceCreateWithURL(page.sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw BridgeError.invalidParameters
        }
        let pixelX = min(image.width - 1, max(0, Int(normalizedX * Double(image.width))))
        let pixelY = min(image.height - 1, max(0, Int(normalizedY * Double(image.height))))
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big).rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(
                    x: CGFloat(-pixelX),
                    y: CGFloat(-pixelY),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        guard rendered else { throw BridgeError.invalidParameters }
        return ["hex": String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])]
    }

    func upsertGlossaryEntry(_ params: [String: Any]) throws -> [String: Any] {
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

    func updateRegion(_ params: [String: Any]) throws {
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
        let textAlignment = (params["textAlignment"] as? String)
            .flatMap(DialogueTextAlignment.init(rawValue:))
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
            textAlignment: textAlignment,
            textColorHex: params["textColorHex"] as? String,
            strokeColorHex: params["strokeColorHex"] as? String,
            strokeWidth: double(params["strokeWidth"]),
            opacity: double(params["opacity"]),
            rotationDegrees: double(params["rotationDegrees"]),
            isVisible: params["isVisible"] as? Bool,
            useAutomaticFontSize: params["useAutomaticFontSize"] as? Bool,
            writingDirection: direction,
            automaticMaskEnabled: params["automaticMaskEnabled"] as? Bool
        )
    }

    func createRegion(_ params: [String: Any]) throws -> [String: Any] {
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

    func duplicateRegion(_ params: [String: Any]) throws -> [String: Any] {
        guard let pageID = uuid(params["pageID"]),
              let sourceRegionID = uuid(params["regionID"]),
              let regionID = store.duplicateRegion(pageID: pageID, regionID: sourceRegionID) else {
            throw BridgeError.invalidParameters
        }
        return ["regionID": regionID.uuidString]
    }

    func appendMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]),
              let stroke = try? maskStroke(from: params) else {
            throw BridgeError.invalidParameters
        }
        store.appendMaskStroke(
            pageID: pageID,
            regionID: regionID,
            mode: stroke.mode,
            points: stroke.points,
            diameter: stroke.diameter
        )
    }

    func appendColorizationMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let stroke = try? maskStroke(from: params) else {
            throw BridgeError.invalidParameters
        }
        store.appendColorizationMaskStroke(
            pageID: pageID,
            mode: stroke.mode,
            points: stroke.points,
            diameter: stroke.diameter
        )
    }

    private func maskStroke(
        from params: [String: Any]
    ) throws -> (mode: MaskStrokeMode, points: [NormalizedPoint], diameter: Double) {
        guard let rawMode = params["mode"] as? String,
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
        return (mode, points, diameter)
    }

    func undoMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.undoMaskStroke(pageID: pageID, regionID: regionID)
    }

    func redoMaskStroke(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.redoMaskStroke(pageID: pageID, regionID: regionID)
    }

    func removeRegion(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let regionID = uuid(params["regionID"]) else {
            throw BridgeError.invalidParameters
        }
        store.removeRegion(pageID: pageID, regionID: regionID)
    }

    func revealOutput(_ params: [String: Any]) throws {
        guard let pageID = uuid(params["pageID"]),
              let page = store.pages.first(where: { $0.id == pageID }) else {
            throw BridgeError.invalidParameters
        }
        let outputURL = (params["preferColorization"] as? Bool == true
            ? page.colorizationOutputURL
            : nil) ?? page.outputURL
        guard let outputURL else { throw BridgeError.invalidParameters }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    private func uuid(_ value: Any?) -> UUID? {
        WebBridgeParameterDecoder.uuid(value)
    }

    private func double(_ value: Any?) -> Double? {
        WebBridgeParameterDecoder.double(value)
    }

    private func integer(_ value: Any?) -> Int? {
        WebBridgeParameterDecoder.integer(value)
    }

    private func normalizedRect(_ value: Any?) -> NormalizedRect? {
        WebBridgeParameterDecoder.normalizedRect(value)
    }

    private func normalizedPoint(_ value: Any?) -> NormalizedPoint? {
        WebBridgeParameterDecoder.normalizedPoint(value)
    }

    private func normalizedPolygons(_ value: Any?) -> [[NormalizedPoint]]? {
        WebBridgeParameterDecoder.normalizedPolygons(value)
    }

    func startUpdateCheckIfNeeded() {
        guard !hasStartedUpdateCheck else { return }
        hasStartedUpdateCheck = true
        let checker = GitHubReleaseChecker()
        updateCheckTask = Task { @MainActor [weak self] in
            let update = try? await checker.availableUpdate()
            guard !Task.isCancelled, let self else { return }
            self.updateCheckTask = nil
            guard let update else { return }
            self.availableUpdate = update
            self.scheduleStatePush()
        }
    }

    func startManualUpdateCheck() {
        hasStartedUpdateCheck = true
        updateCheckTask?.cancel()
        let checkID = UUID()
        manualUpdateCheck = WebUpdateCheckState(id: checkID, phase: .checking)
        scheduleStatePush()

        let checker = GitHubReleaseChecker()
        updateCheckTask = Task { @MainActor [weak self] in
            do {
                let update = try await checker.availableUpdate()
                guard !Task.isCancelled, let self,
                      self.manualUpdateCheck?.id == checkID else { return }
                self.updateCheckTask = nil
                self.availableUpdate = update
                self.manualUpdateCheck = WebUpdateCheckState(
                    id: checkID,
                    phase: update == nil ? .upToDate : .updateAvailable
                )
                self.scheduleStatePush()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self,
                      self.manualUpdateCheck?.id == checkID else { return }
                self.updateCheckTask = nil
                self.manualUpdateCheck = WebUpdateCheckState(id: checkID, phase: .failed)
                self.scheduleStatePush()
            }
        }
    }

    func openExternalURL(_ params: [String: Any]) throws {
        guard let value = params["url"] as? String,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            throw BridgeError.externalURLNotAllowed
        }
        let normalizedPath = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedPath == "vaderchen/mangakitchen"
                || normalizedPath == "vaderchen/mangakitchen/releases"
                || normalizedPath.hasPrefix("vaderchen/mangakitchen/releases/") else {
            throw BridgeError.externalURLNotAllowed
        }
        guard NSWorkspace.shared.open(url) else {
            throw BridgeError.cannotOpenExternalURL
        }
    }

    func localized(_ key: String) -> String {
        NativeLocalization.text(key, languageCode: interfaceLanguageCode)
    }

    func applyInterfaceLanguage(setting: String, normalized: String) {
        preferences.setInterfaceLanguage(setting)
        interfaceLanguageCode = normalized
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
            let payload = try commandHandler.handle(method: method, params: params)
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

enum BridgeError: LocalizedError {
    case invalidParameters
    case unknownMethod(String)
    case modelCapabilityMismatch(String)
    case processingInProgress
    case externalURLNotAllowed
    case cannotOpenExternalURL

    var errorDescription: String? {
        switch self {
        case .invalidParameters: "Bridge 參數不完整或格式錯誤。"
        case let .unknownMethod(method): "未知的 Bridge 方法：\(method)"
        case let .modelCapabilityMismatch(capability):
            "所選模型不符合預期類型：\(capability)。"
        case .processingInProgress:
            "工作處理進行中，請先停止工作再變更模型設定。"
        case .externalURLNotAllowed:
            "只允許開啟 MangaKitchen 官方 GitHub 與 Release 連結。"
        case .cannotOpenExternalURL:
            "無法使用預設瀏覽器開啟 MangaKitchen GitHub 連結。"
        }
    }
}
