import Foundation

/// WebUI 可呼叫的完整 Native Bridge 契約。
///
/// Native 端先解析成此 enum 再分派，避免未知字串進入業務處理；新增命令時，
/// Swift switch 也會要求同步補齊 handler。
enum WebBridgeMethod: String, CaseIterable, Sendable {
    case bootstrap
    case getApplicationLogs
    case clearApplicationLogs
    case appendApplicationLog
    case openExternalURL
    case checkForUpdates
    case updateInterfaceLanguage
    case updateGlobalSettings
    case chooseDataDirectory
    case chooseDefaultOutputDirectory
    case choosePreferredModelDirectory
    case chooseModelDownloadDirectory
    case downloadPreferredModel
    case deleteInstalledModel
    case importPages
    case chooseSourceDirectory
    case appendPages
    case exportPSD
    case switchProject
    case deleteProject
    case renameProject
    case rescanSourceDirectory
    case resetPages
    case renamePage
    case movePage
    case removePages
    case chooseOutputDirectory
    case chooseModel
    case selectPage
    case setPageSelection
    case selectAllPages
    case clearPageSelection
    case clearPages
    case updateSettings
    case samplePageColor
    case upsertGlossaryEntry
    case removeGlossaryEntry
    case detectMasksAll
    case detectMasksSelected
    case translateAll
    case translateSelected
    case composeAll
    case composeSelected
    case superResolveSelected
    case processAll
    case processSelected
    case runBatch
    case cancelProcessing
    case retryFailedBatchJob
    case clearFinishedBatchJobs
    case cancelModelDownload
    case createRegion
    case createMaskRegion
    case duplicateRegion
    case appendMaskStroke
    case undoMaskStroke
    case redoMaskStroke
    case appendColorizationMaskStroke
    case undoColorizationMaskStroke
    case redoColorizationMaskStroke
    case resetColorizationPages
    case undoRegionEdit
    case redoRegionEdit
    case removeRegion
    case moveRegion
    case updateRegion
    case reextractRegion
    case revealOutput
    case clearStatus
}
