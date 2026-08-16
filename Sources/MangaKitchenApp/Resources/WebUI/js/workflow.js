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
  switchProject: (projectID) => invoke("switchProject", { projectID }),
  renameProject: (name) => invoke("renameProject", { name }),
  rescanSourceDirectory: () => invoke("rescanSourceDirectory"),
  chooseOutputDirectory: () => invoke("chooseOutputDirectory"),
  chooseModel: () => invoke("chooseModel"),

  runBatch: (operation, pageIDs) => invoke("runBatch", { operation, pageIDs }),
  detectMasks: (scope = "selected") =>
    invoke(scope === "all" ? "detectMasksAll" : "detectMasksSelected"),
  translate: (scope = "selected") =>
    invoke(scope === "all" ? "translateAll" : "translateSelected"),
  compose: (scope = "selected") =>
    invoke(scope === "all" ? "composeAll" : "composeSelected"),
  runFullPage: (scope = "selected") =>
    invoke(scope === "all" ? "processAll" : "processSelected"),
  cancel: () => invoke("cancelProcessing"),
  retryFailedBatchJob: (jobID) => invoke("retryFailedBatchJob", { jobID }),
  clearFinishedBatchJobs: () => invoke("clearFinishedBatchJobs"),

  selectPage: (pageID) => invoke("selectPage", { pageID }),
  setPageSelection: (pageIDs, activePageID = null) =>
    invoke("setPageSelection", { pageIDs, activePageID }),
  selectAllPages: () => invoke("selectAllPages"),
  clearPageSelection: () => invoke("clearPageSelection"),
  createMaskRegion: (pageID, bounds) =>
    invoke("createMaskRegion", { pageID, bounds }),
  appendMaskStroke: (pageID, regionID, mode, diameter, points) =>
    invoke("appendMaskStroke", { pageID, regionID, mode, diameter, points }),
  undoMaskStroke: (pageID, regionID) =>
    invoke("undoMaskStroke", { pageID, regionID }),
  removeRegion: (pageID, regionID) =>
    invoke("removeRegion", { pageID, regionID }),
  updateRegion: (pageID, regionID, changes) =>
    invoke("updateRegion", { pageID, regionID, ...changes }),
  updateSettings: (changes) => invoke("updateSettings", changes),
  upsertGlossaryEntry: (sourceTerm, translations, entryID = null, note = null) =>
    invoke("upsertGlossaryEntry", { entryID, sourceTerm, translations, note }),
  removeGlossaryEntry: (entryID) => invoke("removeGlossaryEntry", { entryID }),
});

window.MangaKitchenWorkflow = workflow;
