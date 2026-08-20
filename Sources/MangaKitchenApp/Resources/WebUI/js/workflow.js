import { invoke } from "./bridge.js";
import {
  interfaceLanguageSetting,
  resolvedInterfaceLanguage,
  setInterfaceLanguage,
} from "./i18n.js";

// 先提供穩定的功能 API；Canvas 與版面設計後續只需呼叫這一層。
export const workflow = Object.freeze({
  getInterfaceLanguage: () => ({
    setting: interfaceLanguageSetting(),
    resolvedLanguage: resolvedInterfaceLanguage(),
  }),
  setInterfaceLanguage,
  updateGlobalSettings: (settings) => invoke("updateGlobalSettings", settings),
  chooseDataDirectory: () => invoke("chooseDataDirectory"),
  choosePreferredModelDirectory: (capability) =>
    invoke("choosePreferredModelDirectory", { capability }),
  createProject: () => invoke("chooseSourceDirectory"),
  chooseSourceDirectory: () => invoke("chooseSourceDirectory"),
  appendPages: () => invoke("appendPages"),
  switchProject: (projectID) => invoke("switchProject", { projectID }),
  deleteProject: (projectID) => invoke("deleteProject", { projectID }),
  renameProject: (name) => invoke("renameProject", { name }),
  rescanSourceDirectory: () => invoke("rescanSourceDirectory"),
  resetPages: (pageIDs) => invoke("resetPages", { pageIDs }),
  renamePage: (pageID, name) => invoke("renamePage", { pageID, name }),
  movePage: (pageID, offset) => invoke("movePage", { pageID, offset }),
  removePages: (pageIDs) => invoke("removePages", { pageIDs }),
  chooseOutputDirectory: () => invoke("chooseOutputDirectory"),
  exportPSD: (pageIDs) => invoke("exportPSD", { pageIDs }),
  chooseModel: () => invoke("chooseModel"),

  runBatch: (operation, pageIDs, forceRecalculation = false) =>
    invoke("runBatch", { operation, pageIDs, forceRecalculation }),
  detectMasks: (scope = "selected") =>
    invoke(scope === "all" ? "detectMasksAll" : "detectMasksSelected"),
  translate: (scope = "selected") =>
    invoke(scope === "all" ? "translateAll" : "translateSelected"),
  superResolve: () => invoke("superResolveSelected"),
  compose: (scope = "selected") =>
    invoke(scope === "all" ? "composeAll" : "composeSelected"),
  runFullPage: (scope = "selected") =>
    invoke(scope === "all" ? "processAll" : "processSelected"),
  cancel: () => invoke("cancelProcessing"),
  cancelModelDownload: () => invoke("cancelModelDownload"),
  retryFailedBatchJob: (jobID) => invoke("retryFailedBatchJob", { jobID }),
  clearFinishedBatchJobs: () => invoke("clearFinishedBatchJobs"),

  selectPage: (pageID) => invoke("selectPage", { pageID }),
  setPageSelection: (pageIDs, activePageID = null) =>
    invoke("setPageSelection", { pageIDs, activePageID }),
  selectAllPages: () => invoke("selectAllPages"),
  clearPageSelection: () => invoke("clearPageSelection"),
  createMaskRegion: (pageID, bounds) =>
    invoke("createMaskRegion", { pageID, bounds }),
  createRegion: (pageID, bounds, changes = {}) =>
    invoke("createRegion", { pageID, bounds, ...changes }),
  appendMaskStroke: (pageID, regionID, mode, diameter, points) =>
    invoke("appendMaskStroke", { pageID, regionID, mode, diameter, points }),
  undoMaskStroke: (pageID, regionID) =>
    invoke("undoMaskStroke", { pageID, regionID }),
  redoMaskStroke: (pageID, regionID) =>
    invoke("redoMaskStroke", { pageID, regionID }),
  undoRegionEdit: (pageID) => invoke("undoRegionEdit", { pageID }),
  redoRegionEdit: (pageID) => invoke("redoRegionEdit", { pageID }),
  removeRegion: (pageID, regionID) =>
    invoke("removeRegion", { pageID, regionID }),
  moveRegion: (pageID, regionID, offset) =>
    invoke("moveRegion", { pageID, regionID, offset }),
  updateRegion: (pageID, regionID, changes) =>
    invoke("updateRegion", { pageID, regionID, ...changes }),
  updateSettings: (changes) => invoke("updateSettings", changes),
  upsertGlossaryEntry: (sourceTerm, translations, entryID = null, note = null) =>
    invoke("upsertGlossaryEntry", { entryID, sourceTerm, translations, note }),
  removeGlossaryEntry: (entryID) => invoke("removeGlossaryEntry", { entryID }),
});

window.MangaKitchenWorkflow = workflow;
