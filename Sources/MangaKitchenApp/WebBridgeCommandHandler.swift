import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

/// Web Bridge 的白名單命令路由；WebKit transport 與狀態推送由控制器負責。
@MainActor
final class WebBridgeCommandHandler {
    private unowned let controller: HybridBridgeController

    init(controller: HybridBridgeController) {
        self.controller = controller
    }

    func handle(method rawMethod: String, params: [String: Any]) throws -> Any? {
        guard let method = WebBridgeMethod(rawValue: rawMethod) else {
            throw BridgeError.unknownMethod(rawMethod)
        }
        let store = controller.store
        switch method {
        case .bootstrap:
            controller.pushState()
            controller.startUpdateCheckIfNeeded()
            return nil
        case .getApplicationLogs:
            let formatter = ISO8601DateFormatter()
            return store.applicationLog.entries.map { entry in
                [
                    "id": entry.id.uuidString,
                    "timestamp": formatter.string(from: entry.timestamp),
                    "level": entry.level.rawValue,
                    "category": entry.category,
                    "message": entry.message,
                ]
            }
        case .clearApplicationLogs:
            store.applicationLog.clear()
            return nil
        case .appendApplicationLog:
            guard let message = params["message"] as? String else {
                throw BridgeError.invalidParameters
            }
            let level = (params["level"] as? String).flatMap(RuntimeLogLevel.init(rawValue:))
                ?? .error
            store.applicationLog.append(
                level,
                category: params["category"] as? String ?? "WebUI",
                message: message
            )
            return nil
        case .openExternalURL:
            try controller.openExternalURL(params)
            return nil
        case .checkForUpdates:
            controller.startManualUpdateCheck()
            return nil
        case .updateInterfaceLanguage:
            guard let setting = params["setting"] as? String,
                  AppPreferences.supportedInterfaceLanguages.contains(setting),
                  let languageCode = params["resolvedLanguage"] as? String,
                  let normalized = NativeLocalization.normalizedLanguageCode(languageCode) else {
                throw BridgeError.invalidParameters
            }
            controller.applyInterfaceLanguage(setting: setting, normalized: normalized)
            return nil
        case .updateGlobalSettings:
            try controller.updateGlobalSettings(params)
            return nil
        case .chooseDataDirectory:
            return controller.chooseDirectory(
                title: controller.localized("dataDirectoryPanelTitle"),
                prompt: controller.localized("choose")
            )
        case .chooseDefaultOutputDirectory:
            return controller.chooseDirectory(
                title: controller.localized("outputPanelTitle"),
                prompt: controller.localized("choose")
            )
        case .choosePreferredModelDirectory:
            return try controller.choosePreferredModelDirectory(params)
        case .chooseModelDownloadDirectory:
            return try controller.chooseModelDownloadDirectory(params)
        case .downloadPreferredModel:
            try controller.downloadPreferredModel(params)
            return nil
        case .deleteInstalledModel:
            try controller.deleteInstalledModel(params)
            return nil
        case .importPages, .chooseSourceDirectory:
            controller.chooseSourceDirectory()
            return nil
        case .appendPages:
            controller.chooseAdditionalPages()
            return nil
        case .exportPSD:
            try controller.exportPSD(params)
            return nil
        case .switchProject:
            guard let projectID = uuid(params["projectID"]) else {
                throw BridgeError.invalidParameters
            }
            store.activateProject(projectID)
            return nil
        case .deleteProject:
            guard let projectID = uuid(params["projectID"]) else {
                throw BridgeError.invalidParameters
            }
            store.deleteProject(projectID)
            return nil
        case .renameProject:
            guard let name = params["name"] as? String else {
                throw BridgeError.invalidParameters
            }
            store.renameActiveProject(name)
            return nil
        case .rescanSourceDirectory:
            store.rescanSourceDirectory()
            return nil
        case .resetPages:
            store.resetPages(try pageIDs(params["pageIDs"]))
            return nil
        case .renamePage:
            guard let pageID = uuid(params["pageID"]),
                  let name = params["name"] as? String else {
                throw BridgeError.invalidParameters
            }
            store.renamePage(pageID: pageID, name: name)
            return nil
        case .movePage:
            guard let pageID = uuid(params["pageID"]),
                  let offset = (params["offset"] as? NSNumber)?.intValue else {
                throw BridgeError.invalidParameters
            }
            store.movePage(pageID: pageID, offset: offset)
            return nil
        case .removePages:
            store.removePages(try pageIDs(params["pageIDs"]))
            return nil
        case .chooseOutputDirectory:
            return controller.chooseOutputDirectory()
        case .chooseModel:
            controller.chooseModelDirectory()
            return nil
        case .selectPage:
            guard let id = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.selectPage(id)
            return nil
        case .setPageSelection:
            store.setPageSelection(
                pageIDs: try pageIDs(params["pageIDs"]),
                activePageID: uuid(params["activePageID"])
            )
            return nil
        case .selectAllPages:
            store.selectAllPages()
            return nil
        case .clearPageSelection:
            store.clearPageSelection()
            return nil
        case .clearPages:
            store.clearPages()
            return nil
        case .updateSettings:
            try controller.updateSettings(params)
            return nil
        case .samplePageColor:
            return try controller.samplePageColor(params)
        case .upsertGlossaryEntry:
            return try controller.upsertGlossaryEntry(params)
        case .removeGlossaryEntry:
            guard let entryID = uuid(params["entryID"]) else {
                throw BridgeError.invalidParameters
            }
            store.removeGlossaryEntry(entryID)
            return nil
        case .detectMasksAll:
            store.detectMasksForAllPages()
            return nil
        case .detectMasksSelected:
            store.detectMasksForSelectedPage()
            return nil
        case .translateAll:
            store.translateAllPages()
            return nil
        case .translateSelected:
            store.translateSelectedPage()
            return nil
        case .composeAll:
            store.composeAllPages()
            return nil
        case .composeSelected:
            store.composeSelectedPage()
            return nil
        case .superResolveSelected:
            store.superResolveSelectedPage()
            return nil
        case .processAll:
            store.processAllPages()
            return nil
        case .processSelected:
            store.processSelectedPage()
            return nil
        case .runBatch:
            guard let rawOperation = params["operation"] as? String,
                  let operation = BatchOperation(rawValue: rawOperation) else {
                throw BridgeError.invalidParameters
            }
            let jobID = store.enqueueBatch(
                operation: operation,
                pageIDs: try pageIDs(params["pageIDs"]),
                forceRecalculation: params["forceRecalculation"] as? Bool ?? false
            )
            return jobID.map { ["jobID": $0.uuidString] } ?? [:]
        case .cancelProcessing:
            store.cancelProcessing()
            return nil
        case .retryFailedBatchJob:
            guard let jobID = uuid(params["jobID"]) else { throw BridgeError.invalidParameters }
            store.retryFailedBatchJob(jobID)
            return nil
        case .clearFinishedBatchJobs:
            store.clearFinishedBatchJobs()
            return nil
        case .cancelModelDownload:
            store.cancelModelDownload()
            return nil
        case .createRegion, .createMaskRegion:
            return try controller.createRegion(params)
        case .duplicateRegion:
            return try controller.duplicateRegion(params)
        case .appendMaskStroke:
            try controller.appendMaskStroke(params)
            return nil
        case .undoMaskStroke:
            try controller.undoMaskStroke(params)
            return nil
        case .redoMaskStroke:
            try controller.redoMaskStroke(params)
            return nil
        case .appendColorizationMaskStroke:
            try controller.appendColorizationMaskStroke(params)
            return nil
        case .undoColorizationMaskStroke:
            guard let pageID = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.undoColorizationMaskStroke(pageID: pageID)
            return nil
        case .redoColorizationMaskStroke:
            guard let pageID = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.redoColorizationMaskStroke(pageID: pageID)
            return nil
        case .resetColorizationPages:
            store.resetColorizationPages(try pageIDs(params["pageIDs"]))
            return nil
        case .undoRegionEdit:
            guard let pageID = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.undoRegionEdit(pageID: pageID)
            return nil
        case .redoRegionEdit:
            guard let pageID = uuid(params["pageID"]) else { throw BridgeError.invalidParameters }
            store.redoRegionEdit(pageID: pageID)
            return nil
        case .removeRegion:
            try controller.removeRegion(params)
            return nil
        case .moveRegion:
            guard let pageID = uuid(params["pageID"]),
                  let regionID = uuid(params["regionID"]),
                  let offset = (params["offset"] as? NSNumber)?.intValue else {
                throw BridgeError.invalidParameters
            }
            store.moveRegion(pageID: pageID, regionID: regionID, offset: offset)
            return nil
        case .updateRegion:
            try controller.updateRegion(params)
            return nil
        case .reextractRegion:
            guard let pageID = uuid(params["pageID"]),
                  let regionID = uuid(params["regionID"]) else {
                throw BridgeError.invalidParameters
            }
            return ["started": store.reextractRegion(pageID: pageID, regionID: regionID)]
        case .revealOutput:
            try controller.revealOutput(params)
            return nil
        case .clearStatus:
            store.statusMessage = nil
            return nil
        }
    }

    private func uuid(_ value: Any?) -> UUID? {
        WebBridgeParameterDecoder.uuid(value)
    }

    private func pageIDs(_ value: Any?) throws -> [UUID] {
        guard let rawPageIDs = value as? [String] else {
            throw BridgeError.invalidParameters
        }
        let pageIDs = rawPageIDs.compactMap(UUID.init(uuidString:))
        guard pageIDs.count == rawPageIDs.count else {
            throw BridgeError.invalidParameters
        }
        return pageIDs
    }
}
