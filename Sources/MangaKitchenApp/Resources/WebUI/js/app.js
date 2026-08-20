import { invoke, onState } from "./bridge.js";
import {
  applyTranslations,
  interfaceLanguageSetting,
  resolvedInterfaceLanguage,
  setInterfaceLanguage,
  t,
} from "./i18n.js";
import "./workflow.js";

let state = null;
let selectionAnchorID = null;
let activeWorkflowStep = "pages";
let workflowStepPageID = null;
let workflowStepPinned = false;
let selectedMaskRegionID = null;
let selectedTranslationRegionID = null;
let pendingRegionSelectionID = null;
let regionContextTarget = null;
let pageContextTarget = null;
let calculationDialogState = null;
let calculationElapsedTimer = null;
let dismissedModelLoadingFailureID = null;
let maskTool = "add";
let activeMaskStroke = null;
// 譯文編輯的防抖更新在筆劃期間不能送出：它一送出，後端推回的狀態會蓋掉
// 樂觀繪製的 pendingStrokes，畫到一半的筆劃就「縮回去」。畫的時候暫停，
// 放開筆再一次補送 —— 暫停而不是取消，使用者剛打的字不會遺失。
let maskStrokeSuspendsRegionUpdates = false;
const maskPreviewStates = new Map();
const collapsedPageFolders = new Set();
const regionUpdateTimers = new Map();
let regionUpdatesSuspended = false;
let translationDrag = null;
let translationResize = null;
const canvasViewport = { pageID: null, scale: 1, x: 0, y: 0, drag: null };
const canvasBaseSizes = new WeakMap();
const colorSchemeStorageKey = "mangakitchen.color-scheme";
const inspectorTabStorageKey = "mangakitchen.inspector-tab";

const elements = {
  projectSelector: document.querySelector("#project-selector"),
  deleteProject: document.querySelector("#delete-project"),
  appendPages: document.querySelector("#append-pages"),
  pageList: document.querySelector("#page-list"),
  pageCount: document.querySelector("#page-count"),
  pageSearch: document.querySelector("#page-search"),
  pageFilter: document.querySelector("#page-filter"),
  modelList: document.querySelector("#model-list"),
  emptyState: document.querySelector("#empty-state"),
  workspace: document.querySelector("#page-workspace"),
  sourceImageStage: document.querySelector("#source-image-stage"),
  sourceImageStack: document.querySelector("#source-image-stack"),
  sourcePreview: document.querySelector("#source-preview"),
  sourcePreviewCaption: document.querySelector("#source-preview-caption"),
  maskPrimaryTools: document.querySelector("#mask-primary-tools"),
  maskLayer: document.querySelector("#mask-layer"),
  maskDrawingLayer: document.querySelector("#mask-drawing-layer"),
  maskBrush: document.querySelector("#mask-brush"),
  maskEraser: document.querySelector("#mask-eraser"),
  maskBrushCursor: document.querySelector("#mask-brush-cursor"),
  maskBrushSize: document.querySelector("#mask-brush-size"),
  maskBrushSizeValue: document.querySelector("#mask-brush-size-value"),
  maskUndo: document.querySelector("#mask-undo"),
  maskRedo: document.querySelector("#mask-redo"),
  translationPrimaryTools: document.querySelector("#translation-primary-tools"),
  translationUndo: document.querySelector("#translation-undo"),
  translationRedo: document.querySelector("#translation-redo"),
  translationFontDecrease: document.querySelector("#translation-font-decrease"),
  translationFontIncrease: document.querySelector("#translation-font-increase"),
  translationFontRegular: document.querySelector("#translation-font-regular"),
  translationFontBold: document.querySelector("#translation-font-bold"),
  translationFontSizeValue: document.querySelector("#translation-font-size-value"),
  outputImageStage: document.querySelector("#output-image-stage"),
  outputPreviewStack: document.querySelector("#output-preview-stack"),
  outputPreview: document.querySelector("#output-preview"),
  translationLayer: document.querySelector("#translation-layer"),
  resultPreviewCaption: document.querySelector("#result-preview-caption"),
  outputPlaceholder: document.querySelector("#output-placeholder"),
  exportPSD: document.querySelector("#export-psd"),
  regionList: document.querySelector("#region-list"),
  regionCount: document.querySelector("#region-count"),
  regionAdd: document.querySelector("#add-text-region"),
  regionContextMenu: document.querySelector("#region-context-menu"),
  regionContextDuplicate: document.querySelector("#region-context-duplicate"),
  regionContextDelete: document.querySelector("#region-context-delete"),
  pageContextMenu: document.querySelector("#page-context-menu"),
  pageContextRename: document.querySelector("#page-context-rename"),
  pageContextUp: document.querySelector("#page-context-up"),
  pageContextDown: document.querySelector("#page-context-down"),
  pageContextDelete: document.querySelector("#page-context-delete"),
  pageRenameDialog: document.querySelector("#page-rename-dialog"),
  pageRenameInput: document.querySelector("#page-rename-input"),
  batchList: document.querySelector("#batch-list"),
  progress: document.querySelector("#page-progress"),
  status: document.querySelector("#status"),
  canvasInfo: document.querySelector("#canvas-info"),
  canvasResolution: document.querySelector("#canvas-resolution"),
  canvasZoom: document.querySelector("#canvas-zoom"),
  projectPath: document.querySelector("#project-path"),
  selectionSummary: document.querySelector("#selection-summary"),
  settingsDialog: document.querySelector("#settings-dialog"),
  confirmationDialog: document.querySelector("#confirmation-dialog"),
  confirmationTitle: document.querySelector("#confirmation-title"),
  confirmationMessage: document.querySelector("#confirmation-message"),
  confirmationSubmit: document.querySelector("#confirmation-submit"),
  noticeDialog: document.querySelector("#notice-dialog"),
  noticeTitle: document.querySelector("#notice-title"),
  noticeMessage: document.querySelector("#notice-message"),
  noticeDismiss: document.querySelector("#notice-dismiss"),
  calculationDialog: document.querySelector("#calculation-dialog"),
  calculationTitle: document.querySelector("#calculation-title"),
  calculationMessage: document.querySelector("#calculation-message"),
  calculationProgress: document.querySelector("#calculation-progress"),
  calculationElapsed: document.querySelector("#calculation-elapsed"),
  calculationCancel: document.querySelector("#calculation-cancel"),
  modelLoadingDialog: document.querySelector("#model-loading-dialog"),
  modelLoadingTitle: document.querySelector("#model-loading-title"),
  modelLoadingName: document.querySelector("#model-loading-name"),
  modelLoadingMessage: document.querySelector("#model-loading-message"),
  modelLoadingProgress: document.querySelector("#model-loading-progress"),
  modelLoadingCount: document.querySelector("#model-loading-count"),
  modelLoadingSpinner: document.querySelector("#model-loading-spinner"),
  modelLoadingErrorIcon: document.querySelector("#model-loading-error-icon"),
  modelLoadingClose: document.querySelector("#model-loading-close"),
  settingsLanguage: document.querySelector("#settings-language"),
  settingsColorScheme: document.querySelector("#settings-color-scheme"),
  settingsImageCompositingBackend: document.querySelector("#settings-image-compositing-backend"),
  settingsDataDirectory: document.querySelector("#settings-data-directory"),
  dataDirectoryRestartNote: document.querySelector("#data-directory-restart-note"),
  settingsImageToTextModel: document.querySelector("#settings-image-to-text-model"),
  settingsImageToTextModelVariant: document.querySelector("#settings-image-to-text-model-variant"),
  settingsImageToTextModelDownload: document.querySelector("#download-image-to-text-model"),
  settingsImageToTextModelClear: document.querySelector("#clear-image-to-text-model"),
  settingsImageToTextModelDelete: document.querySelector("#delete-image-to-text-model"),
  settingsImageToTextModelDownloadProgress: document.querySelector("#image-to-text-model-download-progress"),
  settingsImageToTextModelDownloadProgressBar: document.querySelector("#image-to-text-model-download-progress-bar"),
  settingsImageToTextModelDownloadStatus: document.querySelector("#image-to-text-model-download-status"),
  settingsImageToImageModel: document.querySelector("#settings-image-to-image-model"),
  settingsAutomaticSuperResolution: document.querySelector("#settings-automatic-super-resolution"),
  settingsSuperResolutionModel: document.querySelector("#settings-super-resolution-model"),
  settingsSuperResolutionModelVariant: document.querySelector("#settings-super-resolution-model-variant"),
  settingsSuperResolutionModelDownload: document.querySelector("#download-super-resolution-model"),
  settingsSuperResolutionModelClear: document.querySelector("#clear-super-resolution-model"),
  settingsSuperResolutionModelDelete: document.querySelector("#delete-super-resolution-model"),
  settingsSuperResolutionModelDownloadProgress: document.querySelector("#super-resolution-model-download-progress"),
  settingsSuperResolutionModelDownloadProgressBar: document.querySelector("#super-resolution-model-download-progress-bar"),
  settingsSuperResolutionModelDownloadStatus: document.querySelector("#super-resolution-model-download-status"),
  settingsMCPEnabled: document.querySelector("#settings-mcp-enabled"),
  settingsMCPEndpointRow: document.querySelector("#settings-mcp-endpoint-row"),
  settingsMCPEndpoint: document.querySelector("#settings-mcp-endpoint"),
  settingsMCPPort: document.querySelector("#settings-mcp-port"),
  settingsMCPClient: document.querySelector("#settings-mcp-client"),
  mcpWhitelist: document.querySelector("#mcp-whitelist"),
  settingsAppVersion: document.querySelector("#settings-app-version"),
  targetLanguage: document.querySelector("#target-language"),
  readingDirection: document.querySelector("#reading-direction"),
  writingDirection: document.querySelector("#writing-direction"),
  fontName: document.querySelector("#font-name"),
  fontNameTrigger: document.querySelector("#font-name-trigger"),
  fontNameValue: document.querySelector("#font-name-value"),
  fontNameList: document.querySelector("#font-name-list"),
  translationPageContext: document.querySelector("#translation-page-context"),
  translationReviewPass: document.querySelector("#translation-review-pass"),
  translationQualityCheck: document.querySelector("#translation-quality-check"),
  translationPreserveLiteral: document.querySelector("#translation-preserve-literal"),
  translationLengthMode: document.querySelector("#translation-length-mode"),
  translationStyleGuide: document.querySelector("#translation-style-guide"),
  useImageModel: document.querySelector("#use-image-model"),
  glossaryCount: document.querySelector("#glossary-count"),
  glossaryTargetLabel: document.querySelector("#glossary-target-label"),
  glossarySource: document.querySelector("#glossary-source"),
  glossaryTargetTerm: document.querySelector("#glossary-target-term"),
  glossaryAdd: document.querySelector("#glossary-add"),
  glossaryList: document.querySelector("#glossary-list"),
  cancel: document.querySelector("#cancel-processing"),
  reveal: document.querySelector("#reveal-output"),
  superResolution: document.querySelector("#super-resolution"),
  canvasPixelPreview: document.querySelector("#canvas-pixel-preview"),
  workflowNext: document.querySelector("#workflow-next"),
};

function colorSchemeSetting() {
  const value = localStorage.getItem(colorSchemeStorageKey) ?? "auto";
  return ["auto", "light", "dark"].includes(value) ? value : "auto";
}

function applyColorScheme(value) {
  const nextValue = ["auto", "light", "dark"].includes(value) ? value : "auto";
  localStorage.setItem(colorSchemeStorageKey, nextValue);
  if (nextValue === "auto") delete document.documentElement.dataset.colorScheme;
  else document.documentElement.dataset.colorScheme = nextValue;
}

function formatByteCount(value) {
  const bytes = Math.max(Number(value) || 0, 0);
  const units = ["B", "KB", "MB", "GB", "TB"];
  const unitIndex = bytes > 0
    ? Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
    : 0;
  const amount = bytes / (1024 ** unitIndex);
  const formatted = new Intl.NumberFormat(resolvedInterfaceLanguage(), {
    maximumFractionDigits: unitIndex === 0 ? 0 : 1,
  }).format(amount);
  return `${formatted} ${units[unitIndex]}`;
}

function showInspectorTab(name) {
  const allowed = new Set(["project", "glossary", "regions", "batch"]);
  const activeName = allowed.has(name) ? name : "project";
  localStorage.setItem(inspectorTabStorageKey, activeName);
  for (const tab of document.querySelectorAll("[data-inspector-tab]")) {
    const active = tab.dataset.inspectorTab === activeName;
    tab.classList.toggle("active", active);
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
  }
  for (const panel of document.querySelectorAll("[data-inspector-panel]")) {
    panel.hidden = panel.dataset.inspectorPanel !== activeName;
  }
}

const stageLabelKeys = {
  pending: "stagePending",
  scanned: "stageScanned",
  detectingText: "stageDetectingText",
  maskReady: "stageMaskReady",
  translating: "stageTranslating",
  translationReady: "stageTranslationReady",
  superResolving: "stageSuperResolving",
  composing: "stageComposing",
  completed: "stageCompleted",
  failed: "stageFailed",
};

const operationLabelKeys = {
  rescan: "operationRescan",
  detectMasks: "operationDetectMasks",
  translate: "operationTranslate",
  superResolve: "operationSuperResolve",
  compose: "operationCompose",
  fullPage: "operationFullPage",
};

const jobStatusLabelKeys = {
  queued: "jobQueued",
  running: "jobRunning",
  completed: "jobCompleted",
  completedWithErrors: "jobCompletedWithErrors",
  cancelled: "jobCancelled",
};

const processingActivityLabelKeys = {
  preparingPage: "activityPreparingPage",
  detectingEnclosures: "activityDetectingEnclosures",
  preparingTextModel: "activityPreparingTextModel",
  detectingRegions: "activityDetectingRegions",
  mergingRegions: "activityMergingRegions",
  refiningPixelMask: "activityRefiningPixelMask",
  generatingMask: "activityGeneratingMask",
  renderingMaskPreview: "activityRenderingMaskPreview",
  applyingGlossary: "activityApplyingGlossary",
  translatingRegions: "activityTranslatingRegions",
  preparingTranslationPreview: "activityPreparingTranslationPreview",
  restoringBackground: "activityRestoringBackground",
  typesettingTranslation: "activityTypesettingTranslation",
  superResolving: "activitySuperResolving",
  savingOutput: "activitySavingOutput",
};

function activePage() {
  return state?.pages.find((page) => page.id === state.selectedPageID) ?? null;
}

function workflowStepForPage(page) {
  if (!page) return "pages";
  if (["detectingText", "recognizing", "masking", "maskReady"].includes(page.stage)) return "mask";
  if (["translating", "translationReady", "superResolving"].includes(page.stage)) return "translate";
  if (["composing", "restoringBackground", "typesetting", "completed"].includes(page.stage)) return "compose";
  return "pages";
}

function syncWorkflowStep(page) {
  if (workflowStepPageID !== page?.id) {
    workflowStepPageID = page?.id ?? null;
    workflowStepPinned = false;
    activeWorkflowStep = workflowStepForPage(page);
    selectedMaskRegionID = null;
  } else if (!workflowStepPinned) {
    activeWorkflowStep = workflowStepForPage(page);
  }
  for (const tab of document.querySelectorAll(".workflow-step[data-step]")) {
    const active = tab.dataset.step === activeWorkflowStep;
    tab.classList.toggle("active", active);
    if (active) tab.setAttribute("aria-current", "step");
    else tab.removeAttribute("aria-current");
  }
}

function selectWorkflowStep(step) {
  activeWorkflowStep = step;
  workflowStepPinned = true;
  syncWorkflowStep(activePage());
  renderPage();
}

function selectedWorkflowPages() {
  const selected = new Set(state?.selectedPageIDs ?? []);
  if (selected.size) return state.pages.filter((page) => selected.has(page.id));
  const page = activePage();
  return page ? [page] : [];
}

function hasWorkflowStepData(page, step) {
  if (step === "mask") {
    return Boolean(page.maskPreviewURL);
  }
  if (step === "translate") {
    return Boolean(page.translationPreviewURL || page.outputPreviewURL);
  }
  if (step === "compose") return Boolean(page.outputPreviewURL);
  return true;
}

function calculationStepLabel(operation) {
  const key = operationLabelKeys[operation];
  return key ? t(key) : operation;
}

function formatElapsedDuration(milliseconds) {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const minuteText = String(minutes).padStart(2, "0");
  const secondText = String(seconds).padStart(2, "0");
  if (hours === 0) return `${minuteText}:${secondText}`;
  return `${String(hours).padStart(2, "0")}:${minuteText}:${secondText}`;
}

function updateCalculationElapsed() {
  const startedAt = calculationDialogState?.startedAt ?? Date.now();
  elements.calculationElapsed.textContent = t("elapsedTime", {
    time: formatElapsedDuration(Date.now() - startedAt),
  });
}

function startCalculationElapsedTimer() {
  if (calculationElapsedTimer !== null) clearInterval(calculationElapsedTimer);
  updateCalculationElapsed();
  calculationElapsedTimer = setInterval(updateCalculationElapsed, 1000);
}

function stopCalculationElapsedTimer() {
  if (calculationElapsedTimer !== null) clearInterval(calculationElapsedTimer);
  calculationElapsedTimer = null;
  elements.calculationElapsed.textContent = t("elapsedTime", { time: "00:00" });
}

function openCalculationDialog(operation, pageIDs) {
  const step = calculationStepLabel(operation);
  calculationDialogState = {
    operation,
    pageIDs,
    jobID: null,
    started: false,
    startedAt: Date.now(),
  };
  elements.calculationTitle.textContent = t("calculatingStep", { step });
  elements.calculationMessage.textContent = t("preparingCalculation");
  elements.calculationProgress.value = 0;
  elements.calculationCancel.disabled = false;
  startCalculationElapsedTimer();
  if (!elements.calculationDialog.open) elements.calculationDialog.showModal();
}

function closeCalculationDialog() {
  stopCalculationElapsedTimer();
  calculationDialogState = null;
  if (elements.calculationDialog.open) elements.calculationDialog.close();
}

function closeModelLoadingDialog() {
  if (elements.modelLoadingDialog.open) elements.modelLoadingDialog.close();
}

function renderModelLoadingDialog() {
  const loading = state?.modelLoadingState;
  if (!loading || loading.phase === "completed") {
    closeModelLoadingDialog();
    return;
  }

  const loadingID = loading.id?.toLowerCase() ?? "unknown";
  const failed = loading.phase === "failed";
  if (failed && dismissedModelLoadingFailureID === loadingID) {
    closeModelLoadingDialog();
    return;
  }

  elements.modelLoadingTitle.textContent = t(failed
    ? "loadingModelFailedTitle"
    : "loadingModelTitle");
  elements.modelLoadingName.textContent = loading.displayName || t("unknownModel");
  elements.modelLoadingMessage.textContent = failed
    ? loading.errorMessage || t("loadingModelFailedFallback")
    : t("loadingModelPreparing");
  elements.modelLoadingCount.textContent = t("loadingModelCount", {
    current: loading.currentIndex,
    total: loading.totalCount,
  });
  elements.modelLoadingSpinner.hidden = failed;
  elements.modelLoadingErrorIcon.hidden = !failed;
  elements.modelLoadingClose.hidden = !failed;

  if (Number.isFinite(loading.progress)) {
    elements.modelLoadingProgress.value = Math.min(Math.max(loading.progress, 0), 1);
  } else {
    elements.modelLoadingProgress.removeAttribute("value");
  }
  if (!elements.modelLoadingDialog.open) elements.modelLoadingDialog.showModal();
}

async function flushPendingRegionUpdates() {
  const pendingUpdates = [...regionUpdateTimers.values()];
  regionUpdateTimers.clear();
  for (const update of pendingUpdates) clearTimeout(update.timer);
  await Promise.all(pendingUpdates.map((update) => update.commit()));
}

function stopRegionUpdateTimers() {
  for (const update of regionUpdateTimers.values()) clearTimeout(update.timer);
  regionUpdateTimers.clear();
  regionUpdatesSuspended = true;
  for (const control of elements.regionList.querySelectorAll("textarea, select, input, button")) {
    control.disabled = true;
  }
}

function renderCalculationDialog() {
  if (!calculationDialogState) return;
  updateCalculationElapsed();
  const step = calculationStepLabel(calculationDialogState.operation);
  elements.calculationTitle.textContent = t("calculatingStep", { step });
  if (calculationDialogState.operation === "rescan") {
    if (state.isProcessing) {
      calculationDialogState.started = true;
      elements.calculationProgress.removeAttribute("value");
      elements.calculationMessage.textContent = t("scanningSource");
    } else if (calculationDialogState.started) {
      closeCalculationDialog();
    }
    return;
  }
  if (!elements.calculationProgress.hasAttribute("value")) {
    elements.calculationProgress.value = 0;
  }
  const jobID = calculationDialogState.jobID?.toLowerCase();
  const job = jobID
    ? state.batchJobs.find((item) => item.id.toLowerCase() === jobID)
    : null;
  if (!job) {
    elements.calculationMessage.textContent = t("preparingCalculation");
    return;
  }
  const currentPage = state.pages.find((page) => page.id === job.currentPageID);
  const pageFraction = currentPage
    ? calculationPageFraction(job.operation, currentPage)
    : null;
  elements.calculationProgress.value = pageFraction === null
    ? job.progress
    : (job.completedCount + pageFraction) / Math.max(1, job.pageCount);
  if (["completed", "completedWithErrors", "cancelled"].includes(job.status)) {
    closeCalculationDialog();
    return;
  }
  const activityLabelKey = currentPage?.processingActivity
    ? processingActivityLabelKeys[currentPage.processingActivity]
    : null;
  if (activityLabelKey) {
    const parameters = { title: currentPage.title };
    const regionProgressKeys = {
      detectingRegions: "activityDetectingRegionProgress",
      translatingRegions: "activityTranslatingRegionProgress",
    };
    const regionProgressKey = regionProgressKeys[currentPage.processingActivity];
    const activityKey = regionProgressKey && currentPage.processingRegionCount > 0
      ? regionProgressKey
      : activityLabelKey;
    if (activityKey === "activityDetectingRegionProgress"
        || activityKey === "activityTranslatingRegionProgress") {
      parameters.current = currentPage.processingRegionIndex ?? 0;
      parameters.total = currentPage.processingRegionCount;
    }
    elements.calculationMessage.textContent = t(activityKey, parameters);
    return;
  }
  elements.calculationMessage.textContent = job.status === "queued"
    ? t("calculationQueued", { step })
    : job.currentPageTitle
      ? t("processingPage", { title: job.currentPageTitle })
      : t("calculationProgress", {
          step,
          completed: job.completedCount,
          total: job.pageCount,
      });
}

function calculationPageFraction(operation, page) {
  if (operation === "translate") {
    return Math.min(Math.max((page.progress - 0.25) / 0.4, 0), 1);
  }
  if (operation === "superResolve") {
    return Math.min(Math.max((page.progress - 0.65) / 0.35, 0), 1);
  }
  return null;
}

async function selectOrCalculateWorkflowStep(step, operation, force = false) {
  await flushPendingRegionUpdates();
  selectWorkflowStep(step);
  const pages = selectedWorkflowPages();
  if (!pages.length) {
    showError(new Error(t("selectAtLeastOnePage")));
    return;
  }
  const pendingPages = force ? pages : pages.filter((page) => !hasWorkflowStepData(page, step));
  if (!pendingPages.length) return;
  const pageIDs = pendingPages.map((page) => page.id);
  const hasImageToTextModel = state.loadedModels.some(
    (model) => model.capability === "imageToText"
  );
  if (operation === "detectMasks" && !hasImageToTextModel) {
    await showNotice(
      t("manualMaskModeTitle"),
      t("manualMaskModeMessage"),
      t("enterManualMaskMode")
    );
  }
  if (operation === "compose") {
    await runBatch(operation, pageIDs);
    return;
  }
  await runBatchWithCalculationDialog(operation, pageIDs, force);
}

function advanceWorkflowStep() {
  const destination = {
    pages: { step: "mask", operation: "detectMasks" },
    mask: { step: "translate", operation: "translate" },
    translate: { step: "compose", operation: "compose" },
  }[activeWorkflowStep];
  if (!destination) return Promise.resolve();
  return selectOrCalculateWorkflowStep(destination.step, destination.operation);
}

async function runBatchWithCalculationDialog(
  operation,
  pageIDs,
  forceRecalculation = false,
) {
  if (!pageIDs.length) {
    showError(new Error(t("selectAtLeastOnePage")));
    return null;
  }
  const hasImageToTextModel = state.loadedModels.some(
    (model) => model.capability === "imageToText"
  );
  if (operation === "fullPage" && !hasImageToTextModel) {
    showError(new Error(t("vlmRequiredForDetection")));
    return null;
  }
  openCalculationDialog(operation, pageIDs);
  const result = await runBatch(operation, pageIDs, forceRecalculation);
  if (!result?.jobID) {
    closeCalculationDialog();
    return null;
  }
  if (!calculationDialogState) return result;
  calculationDialogState.jobID = result.jobID;
  renderCalculationDialog();
  return result;
}

function selectedIDSet() {
  return new Set(state?.selectedPageIDs ?? []);
}

function filteredPages() {
  if (!state) return [];
  const query = elements.pageSearch.value.trim().toLocaleLowerCase();
  const filter = elements.pageFilter.value;
  return state.pages.filter((page) => {
    const matchesText = !query || `${page.title} ${page.relativeSourcePath ?? ""}`.toLocaleLowerCase().includes(query);
    let matchesStage = filter === "all" || page.stage === filter;
    if (filter === "pending") matchesStage = ["pending", "scanned"].includes(page.stage);
    return matchesText && matchesStage;
  });
}

function makeButton(label, className, click) {
  const item = document.createElement("button");
  item.type = "button";
  item.textContent = label;
  if (className) item.className = className;
  item.addEventListener("click", click);
  return item;
}

function makeIconButton(icon, label, className, click) {
  const item = makeButton("", className, click);
  const glyph = document.createElement("i");
  glyph.className = `fa-solid ${icon}`;
  glyph.setAttribute("aria-hidden", "true");
  item.append(glyph);
  item.title = label;
  item.setAttribute("aria-label", label);
  return item;
}

function requestConfirmation(title, message, confirmLabel) {
  elements.confirmationTitle.textContent = title;
  elements.confirmationMessage.textContent = message;
  elements.confirmationSubmit.textContent = confirmLabel;
  elements.confirmationDialog.returnValue = "cancel";
  return new Promise((resolve) => {
    elements.confirmationDialog.addEventListener("close", () => {
      resolve(elements.confirmationDialog.returnValue === "confirm");
    }, { once: true });
    elements.confirmationDialog.showModal();
  });
}

function showNotice(title, message, dismissLabel) {
  elements.noticeTitle.textContent = title;
  elements.noticeMessage.textContent = message;
  elements.noticeDismiss.textContent = dismissLabel;
  return new Promise((resolve) => {
    elements.noticeDialog.addEventListener("close", resolve, { once: true });
    elements.noticeDialog.showModal();
  });
}

function requestPageName(page) {
  elements.pageRenameInput.value = page.title;
  elements.pageRenameDialog.returnValue = "cancel";
  return new Promise((resolve) => {
    elements.pageRenameDialog.addEventListener("close", () => {
      const value = elements.pageRenameInput.value.trim();
      resolve(elements.pageRenameDialog.returnValue === "confirm" && value ? value : null);
    }, { once: true });
    elements.pageRenameDialog.showModal();
    elements.pageRenameInput.select();
  });
}

async function deleteActiveProject() {
  const project = state.projects.find((item) => item.id === state.activeProjectID);
  if (!project || state.isProcessing || state.isSwitchingProject) return;
  const confirmed = await requestConfirmation(
    t("deleteProjectTitle", { name: project.name }),
    t("deleteProjectConfirmation"),
    t("delete")
  );
  if (!confirmed) return;
  await invoke("deleteProject", { projectID: project.id });
}

async function resetSelectedWorkflowPages() {
  const pages = selectedWorkflowPages();
  if (!pages.length) {
    showError(new Error(t("selectAtLeastOnePage")));
    return;
  }
  const confirmed = await requestConfirmation(
    t("resetPagesTitle"),
    t("resetPagesConfirmation", { count: pages.length }),
    t("resetPagesConfirm")
  );
  if (!confirmed) return;
  await invoke("resetPages", { pageIDs: pages.map((page) => page.id) });
}

function defaultTextRegionBounds(page) {
  const vertical = state.options.defaultStyle.writingDirection === "vertical";
  const width = vertical ? 0.14 : 0.26;
  const height = vertical ? 0.26 : 0.14;
  const offset = (page.regions.length % 5) * 0.025;
  return {
    x: clamp((1 - width) / 2 + offset, 0, 1 - width),
    y: clamp((1 - height) / 2 + offset, 0, 1 - height),
    width,
    height,
  };
}

async function addTextRegion() {
  const page = activePage();
  if (!page || state.isProcessing) return;
  selectWorkflowStep("translate");
  showInspectorTab("regions");
  const result = await invoke("createRegion", {
    pageID: page.id,
    bounds: defaultTextRegionBounds(page),
    sourceText: "ABCDE",
    translatedText: "ABCDE",
    automaticMaskEnabled: false,
  });
  if (!result?.regionID) return;
  pendingRegionSelectionID = result.regionID;
  selectedMaskRegionID = result.regionID;
  selectedTranslationRegionID = result.regionID;
  if (activePage()?.regions.some((region) => region.id === result.regionID)) renderPage();
}

async function removeTextRegion(page, region, index) {
  const confirmed = await requestConfirmation(
    t("deleteRegionTitle", { number: index + 1 }),
    t("deleteRegionConfirmation", { number: index + 1 }),
    t("delete")
  );
  if (!confirmed) return;
  const timerKey = `${page.id}:${region.id}`;
  clearTimeout(regionUpdateTimers.get(timerKey)?.timer);
  regionUpdateTimers.delete(timerKey);
  await invoke("removeRegion", { pageID: page.id, regionID: region.id });
}

function hideRegionContextMenu() {
  elements.regionContextMenu.hidden = true;
  regionContextTarget = null;
}

function hidePageContextMenu() {
  elements.pageContextMenu.hidden = true;
  pageContextTarget = null;
}

function currentPageContextTarget() {
  return state?.pages.find((page) => page.id === pageContextTarget) ?? null;
}

function showPageContextMenu(event, page) {
  event.preventDefault();
  event.stopPropagation();
  hideRegionContextMenu();
  pageContextTarget = page.id;
  const pageIndex = state.pages.findIndex((item) => item.id === page.id);
  elements.pageContextUp.disabled = state.isProcessing || pageIndex <= 0;
  elements.pageContextDown.disabled = state.isProcessing || pageIndex >= state.pages.length - 1;
  elements.pageContextRename.disabled = state.isProcessing;
  elements.pageContextDelete.disabled = state.isProcessing;
  elements.pageContextMenu.hidden = false;
  const width = elements.pageContextMenu.offsetWidth;
  const height = elements.pageContextMenu.offsetHeight;
  elements.pageContextMenu.style.left = `${Math.max(8, Math.min(event.clientX, window.innerWidth - width - 8))}px`;
  elements.pageContextMenu.style.top = `${Math.max(8, Math.min(event.clientY, window.innerHeight - height - 8))}px`;
  elements.pageContextRename.focus();
}

async function renameContextPage() {
  const page = currentPageContextTarget();
  hidePageContextMenu();
  if (!page) return;
  const name = await requestPageName(page);
  if (name && name !== page.title) await invoke("renamePage", { pageID: page.id, name });
}

async function moveContextPage(offset) {
  const page = currentPageContextTarget();
  hidePageContextMenu();
  if (page) await invoke("movePage", { pageID: page.id, offset });
}

async function removeContextPage() {
  const page = currentPageContextTarget();
  hidePageContextMenu();
  if (!page) return;
  const confirmed = await requestConfirmation(
    t("removePageTitle", { title: page.title }),
    t("removePageConfirmation"),
    t("removePage")
  );
  if (confirmed) await invoke("removePages", { pageIDs: [page.id] });
}

function currentRegionContextTarget() {
  if (!regionContextTarget) return null;
  const page = state.pages.find((item) => item.id === regionContextTarget.pageID);
  const region = page?.regions.find((item) => item.id === regionContextTarget.regionID);
  if (!page || !region) return null;
  return { page, region, index: page.regions.findIndex((item) => item.id === region.id) };
}

function showRegionContextMenu(event, page, region) {
  event.preventDefault();
  event.stopPropagation();
  if (activeWorkflowStep === "mask") selectMaskRegion(page, region.id);
  else selectTranslationRegion(page, region.id);
  regionContextTarget = { pageID: page.id, regionID: region.id };
  elements.regionContextMenu.hidden = false;
  const width = elements.regionContextMenu.offsetWidth;
  const height = elements.regionContextMenu.offsetHeight;
  elements.regionContextMenu.style.left = `${Math.max(8, Math.min(event.clientX, window.innerWidth - width - 8))}px`;
  elements.regionContextMenu.style.top = `${Math.max(8, Math.min(event.clientY, window.innerHeight - height - 8))}px`;
  elements.regionContextDuplicate.focus();
}

async function duplicateContextRegion() {
  const target = currentRegionContextTarget();
  hideRegionContextMenu();
  if (!target || state.isProcessing) return;
  const result = await invoke("duplicateRegion", {
    pageID: target.page.id,
    regionID: target.region.id,
  });
  if (!result?.regionID) return;
  selectWorkflowStep("translate");
  showInspectorTab("regions");
  pendingRegionSelectionID = result.regionID;
  selectedTranslationRegionID = result.regionID;
  if (activePage()?.regions.some((region) => region.id === result.regionID)) renderPage();
}

async function deleteContextRegion() {
  const target = currentRegionContextTarget();
  hideRegionContextMenu();
  if (!target || state.isProcessing) return;
  await removeTextRegion(target.page, target.region, target.index);
}

function setSelection(pageIDs, activePageID) {
  return invoke("setPageSelection", { pageIDs, activePageID }).catch(showError);
}

function renderProjects() {
  const previousValue = elements.projectSelector.value;
  elements.projectSelector.replaceChildren();
  if (!state.projects.length) {
    const option = document.createElement("option");
    option.textContent = t("noProjects");
    option.value = "";
    elements.projectSelector.append(option);
    elements.projectSelector.disabled = true;
    elements.deleteProject.disabled = true;
    return;
  }

  elements.projectSelector.disabled = state.isProcessing || state.isSwitchingProject;
  elements.deleteProject.disabled = !state.activeProjectID
    || state.isProcessing
    || state.isSwitchingProject;
  for (const project of state.projects) {
    const option = document.createElement("option");
    option.value = project.id;
    option.textContent = `${project.name} · ${project.completedPageCount}/${project.pageCount}`;
    option.selected = project.id === state.activeProjectID;
    elements.projectSelector.append(option);
  }
  if (!state.activeProjectID && previousValue) elements.projectSelector.value = previousValue;
}

function handlePageActivation(event, page, visiblePages) {
  const selected = selectedIDSet();
  if (event.shiftKey && selectionAnchorID) {
    const first = visiblePages.findIndex((item) => item.id === selectionAnchorID);
    const last = visiblePages.findIndex((item) => item.id === page.id);
    if (first >= 0 && last >= 0) {
      const [start, end] = first < last ? [first, last] : [last, first];
      for (const item of visiblePages.slice(start, end + 1)) selected.add(item.id);
    }
  } else if (event.metaKey || event.ctrlKey) {
    if (selected.has(page.id)) selected.delete(page.id);
    else selected.add(page.id);
    selectionAnchorID = page.id;
  } else {
    selected.clear();
    selected.add(page.id);
    selectionAnchorID = page.id;
  }
  setSelection([...selected], page.id);
}

function makePageTreeNode(name = "", path = "") {
  return {
    name,
    path,
    folders: new Map(),
    files: [],
    pages: [],
    visibleCount: 0,
  };
}

function buildPageTree(pages, visiblePageIDs) {
  const root = makePageTreeNode();
  for (const page of pages) {
    const relativePath = (page.relativeSourcePath ?? page.title).replaceAll("\\", "/");
    const components = relativePath.split("/").filter(Boolean);
    const fileName = components.pop() ?? page.title;
    const visible = visiblePageIDs.has(page.id);
    let node = root;
    node.pages.push(page);
    if (visible) node.visibleCount += 1;
    let folderPath = "";
    for (const folderName of components) {
      folderPath = folderPath ? `${folderPath}/${folderName}` : folderName;
      if (!node.folders.has(folderName)) {
        node.folders.set(folderName, makePageTreeNode(folderName, folderPath));
      }
      node = node.folders.get(folderName);
      node.pages.push(page);
      if (visible) node.visibleCount += 1;
    }
    node.files.push({ page, fileName, visible });
  }
  return root;
}

function renderPageTreeFile(container, record, visiblePages, selected) {
  const { page } = record;
  const item = document.createElement("li");
  item.className = "page-item";
  if (page.id === state.selectedPageID) item.classList.add("active");
  if (selected.has(page.id)) item.classList.add("selected");
  item.addEventListener("contextmenu", (event) => showPageContextMenu(event, page));

  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  checkbox.checked = selected.has(page.id);
  checkbox.setAttribute("aria-label", t("selectPage", { title: page.title }));
  checkbox.addEventListener("change", () => {
    const next = selectedIDSet();
    if (checkbox.checked) next.add(page.id);
    else next.delete(page.id);
    selectionAnchorID = page.id;
    setSelection([...next], page.id);
  });

  const preview = document.createElement("img");
  preview.src = page.sourcePreviewURL;
  preview.alt = "";
  preview.loading = "lazy";

  const content = document.createElement("button");
  content.className = "page-content";
  content.addEventListener("click", (event) => handlePageActivation(event, page, visiblePages));
  const title = document.createElement("strong");
  title.textContent = `${page.index}. ${page.title}`;
  const path = document.createElement("small");
  path.textContent = record.fileName;
  const stage = document.createElement("span");
  stage.className = `stage-badge stage-${page.stage}`;
  const stageKey = stageLabelKeys[page.stage];
  stage.textContent = page.errorMessage || `${stageKey ? t(stageKey) : page.stage} · ${Math.round(page.progress * 100)}%`;
  content.append(title, path, stage);
  item.append(checkbox, preview, content);
  container.append(item);
}

function renderPageTreeFolder(container, folder, visiblePages, selected, collator) {
  if (!folder.visibleCount) return;
  const item = document.createElement("li");
  item.className = "page-folder";
  const row = document.createElement("div");
  row.className = "page-folder-row";
  const folderKey = `${state.activeProjectID ?? "project"}:${folder.path}`;
  let collapsed = collapsedPageFolders.has(folderKey);

  const disclosure = makeIconButton(
    collapsed ? "fa-chevron-right" : "fa-chevron-down",
    t(collapsed ? "expandFolder" : "collapseFolder", { name: folder.name }),
    "quiet page-folder-disclosure",
    () => {
      collapsed = !collapsed;
      if (collapsed) collapsedPageFolders.add(folderKey);
      else collapsedPageFolders.delete(folderKey);
      disclosure.firstElementChild.className = `fa-solid ${collapsed ? "fa-chevron-right" : "fa-chevron-down"}`;
      disclosure.setAttribute("aria-expanded", String(!collapsed));
      disclosure.title = t(collapsed ? "expandFolder" : "collapseFolder", { name: folder.name });
      disclosure.setAttribute("aria-label", disclosure.title);
      label.firstElementChild.className = `fa-solid ${collapsed ? "fa-folder" : "fa-folder-open"}`;
      children.hidden = collapsed;
    }
  );
  disclosure.setAttribute("aria-expanded", String(!collapsed));
  disclosure.title = t(collapsed ? "expandFolder" : "collapseFolder", { name: folder.name });

  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  const selectedCount = folder.pages.filter((page) => selected.has(page.id)).length;
  checkbox.checked = selectedCount === folder.pages.length;
  checkbox.indeterminate = selectedCount > 0 && selectedCount < folder.pages.length;
  checkbox.setAttribute("aria-label", t("selectFolderImages", {
    name: folder.name,
    count: folder.pages.length,
  }));
  checkbox.addEventListener("change", () => {
    const next = selectedIDSet();
    for (const page of folder.pages) {
      if (checkbox.checked) next.add(page.id);
      else next.delete(page.id);
    }
    selectionAnchorID = folder.pages[0]?.id ?? null;
    setSelection([...next], state.selectedPageID);
  });

  const label = makeButton("", "page-folder-label", () => disclosure.click());
  const folderIcon = document.createElement("i");
  folderIcon.className = `fa-solid ${collapsed ? "fa-folder" : "fa-folder-open"}`;
  folderIcon.setAttribute("aria-hidden", "true");
  const folderName = document.createElement("span");
  folderName.textContent = folder.name;
  label.append(folderIcon, folderName);
  label.title = folder.path;
  const count = document.createElement("small");
  count.textContent = String(folder.pages.length);
  row.append(disclosure, checkbox, label, count);

  const children = document.createElement("ol");
  children.className = "page-folder-children";
  children.hidden = collapsed;
  const folders = [...folder.folders.values()]
    .filter((child) => child.visibleCount)
    .sort((left, right) => collator.compare(left.name, right.name));
  for (const child of folders) {
    renderPageTreeFolder(children, child, visiblePages, selected, collator);
  }
  for (const record of folder.files.filter((file) => file.visible).sort((left, right) => left.page.index - right.page.index)) {
    renderPageTreeFile(children, record, visiblePages, selected);
  }
  item.append(row, children);
  container.append(item);
}

function renderPages() {
  elements.pageList.replaceChildren();
  const visiblePages = filteredPages();
  const visiblePageIDs = new Set(visiblePages.map((page) => page.id));
  const selected = selectedIDSet();
  const tree = buildPageTree(state.pages, visiblePageIDs);
  const collator = new Intl.Collator(resolvedInterfaceLanguage(), { numeric: true, sensitivity: "base" });
  elements.pageCount.textContent = t("pageCount", {
    visible: visiblePages.length,
    total: state.pages.length,
  });

  const folders = [...tree.folders.values()]
    .filter((folder) => folder.visibleCount)
    .sort((left, right) => collator.compare(left.name, right.name));
  for (const folder of folders) {
    renderPageTreeFolder(elements.pageList, folder, visiblePages, selected, collator);
  }
  for (const record of tree.files.filter((file) => file.visible).sort((left, right) => left.page.index - right.page.index)) {
    renderPageTreeFile(elements.pageList, record, visiblePages, selected);
  }

  if (!visiblePages.length && state.pages.length) {
    const empty = document.createElement("li");
    empty.className = "list-empty";
    empty.textContent = t("noMatchingPages");
    elements.pageList.append(empty);
  }
}

function renderModels() {
  elements.modelList.replaceChildren();
  if (!state.loadedModels.length) {
    const item = document.createElement("li");
    item.className = "muted";
    item.textContent = t("notLoaded");
    elements.modelList.append(item);
    return;
  }
  for (const model of state.loadedModels) {
    const item = document.createElement("li");
    const capability = model.capability === "imageToText"
      ? t("imageToText")
      : model.capability === "superResolution"
        ? t("superResolutionLoaded")
        : t("imageToImage");
    item.textContent = `${capability} · ${model.displayName}`;
    elements.modelList.append(item);
  }
}

function renderRegions(page) {
  elements.regionList.replaceChildren();
  elements.regionCount.textContent = String(page?.regions.length ?? 0);
  elements.regionAdd.disabled = !page || state.isProcessing;
  if (!page?.regions.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = t("noRecognitionResult");
    elements.regionList.append(empty);
    return;
  }

  for (const [index, region] of page.regions.entries()) {
    const row = document.createElement("article");
    row.className = "region-row";
    row.dataset.regionID = region.id;
    row.classList.toggle("mask-selected", region.id === selectedMaskRegionID && activeWorkflowStep === "mask");
    row.classList.toggle(
      "translation-selected",
      region.id === selectedTranslationRegionID && activeWorkflowStep === "translate"
    );
    row.addEventListener("contextmenu", (event) => showRegionContextMenu(event, page, region));

    const heading = document.createElement("div");
    heading.className = "region-heading";
    const label = document.createElement("strong");
    label.textContent = t("regionNumber", { number: index + 1 });
    const confidence = document.createElement("small");
    confidence.textContent = t("recognitionConfidence", {
      percent: Math.round(region.confidence * 100),
    });
    const remove = makeIconButton("fa-trash-can", t("deleteRegion", { number: index + 1 }), "quiet danger-text region-delete-button", (event) => {
      event.stopPropagation();
      removeTextRegion(page, region, index).catch(showError);
    });
    remove.disabled = state.isProcessing;
    const visibility = makeIconButton(
      region.style.isVisible === false ? "fa-eye-slash" : "fa-eye",
      t(region.style.isVisible === false ? "showLayer" : "hideLayer"),
      "quiet region-layer-button",
      (event) => {
        event.stopPropagation();
        if (state.isProcessing) return;
        const previous = region.style.isVisible !== false;
        region.style.isVisible = !previous;
        renderTranslationLayer(page);
        renderRegions(page);
        invoke("updateRegion", {
          pageID: page.id,
          regionID: region.id,
          isVisible: !previous,
        }).catch((error) => {
          region.style.isVisible = previous;
          renderPage();
          showError(error);
        });
      }
    );
    const backward = makeIconButton("fa-arrow-down", t("sendLayerBackward"), "quiet region-layer-button", (event) => {
      event.stopPropagation();
      invoke("moveRegion", { pageID: page.id, regionID: region.id, offset: -1 }).catch(showError);
    });
    backward.disabled = state.isProcessing || index === 0;
    const forward = makeIconButton("fa-arrow-up", t("bringLayerForward"), "quiet region-layer-button", (event) => {
      event.stopPropagation();
      invoke("moveRegion", { pageID: page.id, regionID: region.id, offset: 1 }).catch(showError);
    });
    forward.disabled = state.isProcessing || index === page.regions.length - 1;
    const metadata = document.createElement("div");
    metadata.className = "region-heading-meta";
    metadata.append(confidence, backward, forward, visibility, remove);
    heading.append(label, metadata);
    heading.addEventListener("click", () => {
      if (activeWorkflowStep === "mask") {
        selectMaskRegion(page, region.id);
      } else if (activeWorkflowStep === "translate") {
        selectTranslationRegion(page, region.id);
      }
    });

    const source = document.createElement("p");
    source.className = "source-text";
    source.textContent = region.sourceText || t("noSourceText");

    const editor = document.createElement("textarea");
    editor.value = region.translatedText;
    editor.rows = 3;
    editor.disabled = state.isProcessing || regionUpdatesSuspended;
    editor.setAttribute("aria-label", t("regionTranslationAria", { number: index + 1 }));

    const translationMetadata = document.createElement("div");
    translationMetadata.className = "translation-quality-metadata";
    const metadataItems = [];
    if (region.speakerID) metadataItems.push(`${t("translationSpeaker")}: ${region.speakerID}`);
    if (region.tone) metadataItems.push(`${t("translationTone")}: ${region.tone}`);
    if (Number.isFinite(region.translationConfidence)) {
      metadataItems.push(`${t("translationConfidence")}: ${Math.round(region.translationConfidence * 100)}%`);
    }
    if (region.translationQAFlags?.length) {
      metadataItems.push(`${t("translationQA")}: ${region.translationQAFlags.map((flag) => t(`translationQA_${flag}`)).join("、")}`);
      translationMetadata.classList.toggle(
        "has-warning",
        region.translationQAFlags.some((flag) => flag !== "reviewAdjusted"),
      );
    }
    if (region.literalTranslatedText) {
      const literal = document.createElement("details");
      const summary = document.createElement("summary");
      summary.textContent = t("literalTranslation");
      const text = document.createElement("p");
      text.textContent = region.literalTranslatedText;
      literal.append(summary, text);
      translationMetadata.append(literal);
    }
    if (metadataItems.length) {
      const summary = document.createElement("small");
      summary.textContent = metadataItems.join(" · ");
      translationMetadata.prepend(summary);
    }
    translationMetadata.hidden = !metadataItems.length && !region.literalTranslatedText;

    const direction = document.createElement("select");
    direction.disabled = state.isProcessing || regionUpdatesSuspended;
    for (const [value, labelKey] of [["automatic", "automaticTypesetting"], ["horizontal", "horizontal"], ["vertical", "vertical"]]) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = t(labelKey);
      option.selected = region.style.writingDirection === value;
      direction.append(option);
    }

    const alignment = document.createElement("select");
    for (const [value, labelKey] of [["start", "alignStart"], ["center", "alignCenter"], ["end", "alignEnd"]]) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = t(labelKey);
      option.selected = (region.style.textAlignment ?? "center") === value;
      alignment.append(option);
    }
    const textColor = document.createElement("input");
    textColor.type = "color";
    textColor.value = region.style.textColorHex ?? "#111111";
    const strokeColor = document.createElement("input");
    strokeColor.type = "color";
    strokeColor.value = region.style.strokeColorHex ?? "#FFFFFF";
    const strokeWidth = document.createElement("input");
    strokeWidth.type = "range";
    strokeWidth.min = "0";
    strokeWidth.max = "8";
    strokeWidth.step = "0.25";
    strokeWidth.value = String(region.style.strokeWidth ?? 0);
    const opacity = document.createElement("input");
    opacity.type = "range";
    opacity.min = "0";
    opacity.max = "100";
    opacity.step = "1";
    opacity.value = String(Math.round((region.style.opacity ?? 1) * 100));
    const rotation = document.createElement("input");
    rotation.type = "range";
    rotation.min = "-180";
    rotation.max = "180";
    rotation.step = "1";
    rotation.value = String(region.style.rotationDegrees ?? 0);

    const styleControls = document.createElement("div");
    styleControls.className = "region-style-controls";
    styleControls.hidden = activeWorkflowStep !== "translate";
    const makeStyleField = (labelKey, control, output = null) => {
      const label = document.createElement("label");
      const caption = document.createElement("span");
      caption.textContent = t(labelKey);
      label.append(caption, control);
      if (output) label.append(output);
      return label;
    };
    const strokeOutput = document.createElement("output");
    strokeOutput.value = `${Number(strokeWidth.value).toFixed(2)} px`;
    const opacityOutput = document.createElement("output");
    opacityOutput.value = `${opacity.value}%`;
    const rotationOutput = document.createElement("output");
    rotationOutput.value = `${rotation.value}°`;
    styleControls.append(
      makeStyleField("textAlignment", alignment),
      makeStyleField("textColor", textColor),
      makeStyleField("strokeColor", strokeColor),
      makeStyleField("strokeWidth", strokeWidth, strokeOutput),
      makeStyleField("layerOpacity", opacity, opacityOutput),
      makeStyleField("layerRotation", rotation, rotationOutput),
    );

    const scheduleUpdate = () => {
      if (state.isProcessing || regionUpdatesSuspended) return;
      region.translatedText = editor.value;
      region.style.writingDirection = direction.value;
      region.style.textAlignment = alignment.value;
      region.style.textColorHex = textColor.value;
      region.style.strokeColorHex = strokeColor.value;
      region.style.strokeWidth = Number(strokeWidth.value);
      region.style.opacity = Number(opacity.value) / 100;
      region.style.rotationDegrees = Number(rotation.value);
      strokeOutput.value = `${Number(strokeWidth.value).toFixed(2)} px`;
      opacityOutput.value = `${opacity.value}%`;
      rotationOutput.value = `${rotation.value}°`;
      renderTranslationLayer(page);
      const timerKey = `${page.id}:${region.id}`;
      clearTimeout(regionUpdateTimers.get(timerKey)?.timer);
      const commit = () => invoke("updateRegion", {
        pageID: page.id,
        regionID: region.id,
        translatedText: editor.value,
        writingDirection: direction.value,
        textAlignment: alignment.value,
        textColorHex: textColor.value,
        strokeColorHex: strokeColor.value,
        strokeWidth: Number(strokeWidth.value),
        opacity: Number(opacity.value) / 100,
        rotationDegrees: Number(rotation.value),
      });
      const timer = setTimeout(() => {
        if (regionUpdateTimers.get(timerKey)?.timer !== timer) return;
        // 正在畫筆劃就先不送，重新排程，等放開筆再說。
        if (maskStrokeSuspendsRegionUpdates) {
          scheduleUpdate();
          return;
        }
        regionUpdateTimers.delete(timerKey);
        commit().catch(showError);
      }, 1000);
      regionUpdateTimers.set(timerKey, { timer, commit });
    };
    editor.addEventListener("input", scheduleUpdate);
    direction.addEventListener("change", scheduleUpdate);
    alignment.addEventListener("change", scheduleUpdate);
    textColor.addEventListener("input", scheduleUpdate);
    strokeColor.addEventListener("input", scheduleUpdate);
    strokeWidth.addEventListener("input", scheduleUpdate);
    opacity.addEventListener("input", scheduleUpdate);
    rotation.addEventListener("input", scheduleUpdate);
    const controls = document.createElement("div");
    controls.className = "region-controls";
    controls.append(direction);
    row.append(heading, source, editor, translationMetadata, controls, styleControls);
    elements.regionList.append(row);
  }

  if (pendingRegionSelectionID
      && page.regions.some((region) => region.id === pendingRegionSelectionID)) {
    const regionID = pendingRegionSelectionID;
    pendingRegionSelectionID = null;
    if (activeWorkflowStep === "mask") selectMaskRegion(page, regionID);
    else selectTranslationRegion(page, regionID);
  }
}

function selectedMaskRegion(page) {
  return page?.regions.find((region) => region.id === selectedMaskRegionID) ?? null;
}

function scrollRegionIntoView(regionID) {
  requestAnimationFrame(() => {
    const selectedRow = [...elements.regionList.querySelectorAll(".region-row")]
      .find((row) => row.dataset.regionID === regionID);
    selectedRow?.scrollIntoView({ behavior: "smooth", block: "center" });
  });
}

function selectMaskRegion(page, regionID) {
  selectedMaskRegionID = regionID;
  showInspectorTab("regions");
  for (const row of elements.regionList.querySelectorAll(".region-row")) {
    row.classList.toggle("mask-selected", row.dataset.regionID === regionID);
  }
  renderMaskEditor(page);
  scrollRegionIntoView(regionID);
}

function maskRevision(page) {
  return `${page.id}:${page.maskRevision ?? "unknown"}`;
}

function maskPreviewState(page) {
  let preview = maskPreviewStates.get(page.id);
  if (!preview) {
    preview = {
      revision: null,
      requestedRevision: null,
      image: null,
      pendingBaseRevision: null,
      pendingStrokes: [],
    };
    maskPreviewStates.set(page.id, preview);
  }
  return preview;
}

function drawMaskStroke(context, canvas, stroke) {
  const points = stroke.points;
  if (!points.length) return;
  const diameter = stroke.diameter * Math.min(canvas.width, canvas.height);
  context.save();
  context.globalCompositeOperation = stroke.mode === "erase" ? "destination-out" : "source-over";
  context.lineWidth = Math.max(1, diameter);
  context.lineCap = "round";
  context.lineJoin = "round";
  context.strokeStyle = "rgb(239, 68, 68)";
  context.fillStyle = context.strokeStyle;
  const first = points[0];
  if (points.length === 1) {
    context.beginPath();
    context.arc(first.x * canvas.width, first.y * canvas.height, diameter / 2, 0, Math.PI * 2);
    context.fill();
  } else {
    context.beginPath();
    context.moveTo(first.x * canvas.width, first.y * canvas.height);
    for (const point of points.slice(1)) {
      context.lineTo(point.x * canvas.width, point.y * canvas.height);
    }
    context.stroke();
  }
  context.restore();
}

function renderMaskCanvas(page) {
  const canvas = elements.maskLayer;
  const context = canvas.getContext("2d");
  if (!context) return;
  context.clearRect(0, 0, canvas.width, canvas.height);
  if (!page?.maskPreviewURL) return;
  const preview = maskPreviewState(page);
  if (preview.image) {
    context.drawImage(preview.image, 0, 0, canvas.width, canvas.height);
  }
  for (const stroke of preview.pendingStrokes) drawMaskStroke(context, canvas, stroke);
  if (activeMaskStroke?.pageID === page.id) drawMaskStroke(context, canvas, activeMaskStroke);
}

function requestMaskPreview(page) {
  const preview = maskPreviewState(page);
  const revision = maskRevision(page);
  if (preview.requestedRevision === revision) {
    renderMaskCanvas(page);
    return;
  }
  preview.requestedRevision = revision;
  const image = new Image();
  image.addEventListener("load", () => {
    if (preview.requestedRevision !== revision) return;
    preview.image = image;
    preview.revision = revision;
    if (preview.pendingBaseRevision && preview.pendingBaseRevision !== revision) {
      preview.pendingBaseRevision = null;
      preview.pendingStrokes = [];
    }
    if (activePage()?.id === page.id) renderMaskCanvas(activePage());
  });
  image.addEventListener("error", () => {
    if (preview.requestedRevision === revision) showError(new Error(t("maskPreviewLoadFailed")));
  });
  image.src = `${page.maskPreviewURL}?revision=${encodeURIComponent(revision)}`;
}

function renderMaskEditor(page) {
  const maskMode = activeWorkflowStep === "mask";
  const hasMask = Boolean(page?.maskPreviewURL);
  elements.workspace.classList.toggle("mask-mode", maskMode);
  elements.workspace.classList.toggle("mask-brush-tool", maskMode && maskTool === "add");
  elements.workspace.classList.toggle("mask-eraser-tool", maskMode && maskTool === "erase");
  elements.maskPrimaryTools.hidden = !maskMode;
  elements.sourcePreviewCaption.textContent = t(maskMode ? "maskLayer" : "sourceImage");
  elements.maskLayer.hidden = !maskMode || !hasMask;
  elements.maskDrawingLayer.hidden = !maskMode || !hasMask;
  if (!maskMode || !hasMask) hideMaskBrushCursor();

  if (page) {
    const width = Math.max(1, page.pixelWidth);
    const height = Math.max(1, page.pixelHeight);
    if (elements.maskLayer.width !== width) elements.maskLayer.width = width;
    if (elements.maskLayer.height !== height) elements.maskLayer.height = height;
    if (elements.maskDrawingLayer.width !== width) elements.maskDrawingLayer.width = width;
    if (elements.maskDrawingLayer.height !== height) elements.maskDrawingLayer.height = height;
  }
  if (hasMask) {
    requestMaskPreview(page);
  } else {
    elements.maskLayer.getContext("2d")?.clearRect(0, 0, elements.maskLayer.width, elements.maskLayer.height);
  }

  if (page?.regions.length && !page.regions.some((region) => region.id === selectedMaskRegionID)) {
    selectedMaskRegionID = page.regions[0].id;
  } else if (!page?.regions.length) {
    selectedMaskRegionID = null;
  }
  const region = selectedMaskRegion(page);
  const disabled = !maskMode || !hasMask || !region || state.isProcessing;
  for (const control of [
    elements.maskBrush,
    elements.maskEraser,
    elements.maskBrushSize,
  ]) control.disabled = disabled;
  const hasPendingStroke = page && region
    ? maskPreviewState(page).pendingStrokes.some((stroke) => stroke.regionID === region.id)
    : false;
  elements.maskUndo.disabled = disabled || !(region.maskStrokes?.length || hasPendingStroke);
  elements.maskRedo.disabled = disabled || !page.maskRedoRegionIDs?.includes(region.id);
  elements.maskBrush.classList.toggle("active", maskTool === "add");
  elements.maskEraser.classList.toggle("active", maskTool === "erase");
  elements.maskBrushSizeValue.value = `${elements.maskBrushSize.value} px`;
}

/// 筆刷游標的螢幕直徑。normalizedDiameter 以頁面短邊為基準（與遮罩產生器
/// 的 diameter * min(width, height) 一致），所以螢幕上也要用短邊換算。
let lastMaskPointerPosition = null;

function updateMaskBrushCursor(event) {
  const cursor = elements.maskBrushCursor;
  if (!cursor) return;
  if (event) lastMaskPointerPosition = { clientX: event.clientX, clientY: event.clientY };
  const position = event ?? lastMaskPointerPosition;
  if (!position) { cursor.hidden = true; return; }
  const page = activePage();
  const rect = elements.maskDrawingLayer.getBoundingClientRect();
  if (activeWorkflowStep !== "mask" || !page?.maskPreviewURL
      || !rect.width || !rect.height) {
    cursor.hidden = true;
    return;
  }
  cursor.classList.toggle("brush", maskTool === "add");
  cursor.classList.toggle("eraser", maskTool === "erase");
  const brushPixels = Number(elements.maskBrushSize.value);
  const shortSide = Math.max(1, Math.min(page.pixelWidth, page.pixelHeight));
  const size = Math.max(4, (brushPixels / shortSide) * Math.min(rect.width, rect.height));
  cursor.style.width = `${size}px`;
  cursor.style.height = `${size}px`;
  cursor.style.left = `${position.clientX}px`;
  cursor.style.top = `${position.clientY}px`;
  cursor.hidden = false;
}

function hideMaskBrushCursor() {
  lastMaskPointerPosition = null;
  if (elements.maskBrushCursor) elements.maskBrushCursor.hidden = true;
}

function normalizedMaskPoint(event) {
  const rect = elements.maskDrawingLayer.getBoundingClientRect();
  if (!rect.width || !rect.height) return null;
  return {
    x: Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)),
    y: Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height)),
  };
}

function regionForMaskPoint(page, point, diameter) {
  const candidates = page.regions.filter((region) => {
    const bounds = region.bubbleBounds ?? region.bounds;
    const padding = diameter * 1.5;
    return point.x >= bounds.x - padding
      && point.x <= bounds.x + bounds.width + padding
      && point.y >= bounds.y - padding
      && point.y <= bounds.y + bounds.height + padding;
  });
  candidates.sort((left, right) => {
    const a = left.bubbleBounds ?? left.bounds;
    const b = right.bubbleBounds ?? right.bounds;
    return a.width * a.height - b.width * b.height;
  });
  return candidates[0] ?? selectedMaskRegion(page) ?? page.regions[0] ?? null;
}

function beginMaskStroke(event) {
  if (event.shiftKey && canvasViewport.scale > 1) return;
  if (event.button !== 0 || activeWorkflowStep !== "mask") return;
  const page = activePage();
  const point = normalizedMaskPoint(event);
  if (!page?.maskPreviewURL || !point || state.isProcessing) {
    showError(new Error(t("maskNotReady")));
    return;
  }
  const diameter = Number(elements.maskBrushSize.value) / Math.max(1, Math.min(page.pixelWidth, page.pixelHeight));
  const region = regionForMaskPoint(page, point, diameter);
  if (!region) {
    showError(new Error(t("noMaskRegions")));
    return;
  }
  selectMaskRegion(page, region.id);
  // 確定要開始畫了才暫停防抖更新；設在前面的話，上面任何一個 early return
  // 都會讓旗標卡在 true，譯文從此再也存不進去。
  maskStrokeSuspendsRegionUpdates = true;
  activeMaskStroke = {
    pointerID: event.pointerId,
    pageID: page.id,
    regionID: region.id,
    mode: maskTool,
    diameter,
    points: [point],
  };
  elements.maskDrawingLayer.setPointerCapture(event.pointerId);
  renderMaskCanvas(page);
  event.preventDefault();
}

function continueMaskStroke(event) {
  if (!activeMaskStroke || activeMaskStroke.pointerID !== event.pointerId) return;
  const events = event.getCoalescedEvents?.() ?? [event];
  for (const sample of events) {
    const point = normalizedMaskPoint(sample);
    const previous = activeMaskStroke.points.at(-1);
    if (!point || Math.hypot(point.x - previous.x, point.y - previous.y) < 0.001) continue;
    activeMaskStroke.points.push(point);
  }
  renderMaskCanvas(activePage());
  event.preventDefault();
}

function finishMaskStroke(event, cancelled = false) {
  if (!activeMaskStroke || activeMaskStroke.pointerID !== event.pointerId) return;
  const stroke = activeMaskStroke;
  activeMaskStroke = null;
  maskStrokeSuspendsRegionUpdates = false;
  if (elements.maskDrawingLayer.hasPointerCapture(event.pointerId)) {
    elements.maskDrawingLayer.releasePointerCapture(event.pointerId);
  }
  if (cancelled) {
    renderMaskCanvas(activePage());
    return;
  }
  const page = state?.pages.find((item) => item.id === stroke.pageID);
  if (!page) return;
  const preview = maskPreviewState(page);
  stroke.localID = `${Date.now()}-${Math.random()}`;
  preview.pendingBaseRevision ??= preview.revision ?? maskRevision(page);
  preview.pendingStrokes.push(stroke);
  renderMaskCanvas(page);
  renderMaskEditor(page);
  invoke("appendMaskStroke", {
    pageID: stroke.pageID,
    regionID: stroke.regionID,
    mode: stroke.mode,
    diameter: stroke.diameter,
    points: stroke.points,
  }).catch((error) => {
    preview.pendingStrokes = preview.pendingStrokes.filter((item) => item.localID !== stroke.localID);
    if (!preview.pendingStrokes.length) preview.pendingBaseRevision = null;
    renderMaskCanvas(activePage());
    showError(error);
  });
  event.preventDefault();
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function canvasScaleForPage(page) {
  const scale = Number(page?.superResolutionScale);
  return page?.superResolutionApplied && Number.isFinite(scale) ? Math.max(1, scale) : 1;
}

function resetCanvasStackLayout(stack, image) {
  canvasBaseSizes.delete(stack);
  stack.style.removeProperty("width");
  stack.style.removeProperty("height");
  stack.style.removeProperty("max-width");
  stack.dataset.canvasScale = "1";
  image.style.removeProperty("width");
  image.style.removeProperty("height");
  image.style.removeProperty("max-width");
  image.style.removeProperty("max-height");
}

function applyCanvasStackLayout(stack, image) {
  if (!stack || !image?.naturalWidth || !image?.naturalHeight || stack.hidden) return;
  let baseSize = canvasBaseSizes.get(stack);
  if (!baseSize) {
    const appliedScale = Math.max(0.0001, Number(stack.dataset.canvasScale) || 1);
    baseSize = {
      width: Math.max(1, stack.offsetWidth / appliedScale),
      height: Math.max(1, stack.offsetHeight / appliedScale),
    };
    canvasBaseSizes.set(stack, baseSize);
  }
  const width = baseSize.width * canvasViewport.scale;
  const height = baseSize.height * canvasViewport.scale;
  stack.style.maxWidth = "none";
  stack.style.width = `${width}px`;
  stack.style.height = `${height}px`;
  stack.dataset.canvasScale = String(canvasViewport.scale);
  image.style.width = `${width}px`;
  image.style.height = `${height}px`;
  image.style.maxWidth = "none";
  image.style.maxHeight = "none";
}

function clampCanvasPan() {
  const canvases = [
    { stage: elements.sourceImageStage, stack: elements.sourceImageStack },
    { stage: elements.outputImageStage, stack: elements.outputPreviewStack },
  ].filter(({ stage, stack }) => !stack.hidden
    && stack.offsetWidth
    && stack.offsetHeight
    && stage.clientWidth
    && stage.clientHeight);
  if (!canvases.length || canvasViewport.scale <= 1) {
    canvasViewport.x = 0;
    canvasViewport.y = 0;
    return;
  }
  const ranges = canvases.map(({ stage, stack }) => {
    const stageRect = stage.getBoundingClientRect();
    const stackRect = stack.getBoundingClientRect();
    const viewportLeft = stageRect.left + stage.clientLeft;
    const viewportTop = stageRect.top + stage.clientTop;
    const viewportRight = viewportLeft + stage.clientWidth;
    const viewportBottom = viewportTop + stage.clientHeight;
    const unshiftedLeft = stackRect.left - canvasViewport.x;
    const unshiftedTop = stackRect.top - canvasViewport.y;
    const unshiftedRight = unshiftedLeft + stackRect.width;
    const unshiftedBottom = unshiftedTop + stackRect.height;
    return {
      minimumX: stackRect.width > stage.clientWidth
        ? viewportRight - unshiftedRight
        : 0,
      maximumX: stackRect.width > stage.clientWidth
        ? viewportLeft - unshiftedLeft
        : 0,
      minimumY: stackRect.height > stage.clientHeight
        ? viewportBottom - unshiftedBottom
        : 0,
      maximumY: stackRect.height > stage.clientHeight
        ? viewportTop - unshiftedTop
        : 0,
    };
  });
  const minimumX = Math.max(...ranges.map((range) => range.minimumX));
  const maximumX = Math.min(...ranges.map((range) => range.maximumX));
  const minimumY = Math.max(...ranges.map((range) => range.minimumY));
  const maximumY = Math.min(...ranges.map((range) => range.maximumY));
  canvasViewport.x = minimumX <= maximumX
    ? clamp(canvasViewport.x, minimumX, maximumX)
    : (minimumX + maximumX) / 2;
  canvasViewport.y = minimumY <= maximumY
    ? clamp(canvasViewport.y, minimumY, maximumY)
    : (minimumY + maximumY) / 2;
}

function applyCanvasTransform() {
  const transform = `translate3d(${canvasViewport.x}px, ${canvasViewport.y}px, 0)`;
  elements.sourceImageStack.style.transform = transform;
  elements.outputPreviewStack.style.transform = transform;
}

function applyCanvasViewport() {
  applyCanvasStackLayout(elements.sourceImageStack, elements.sourcePreview);
  applyCanvasStackLayout(elements.outputPreviewStack, elements.outputPreview);
  applyCanvasTransform();
  clampCanvasPan();
  applyCanvasTransform();
  for (const stage of [elements.sourceImageStage, elements.outputImageStage]) {
    stage.classList.toggle("canvas-pannable", canvasViewport.scale > 1);
    stage.classList.toggle("canvas-panning", canvasViewport.drag?.stage === stage);
  }
  renderCanvasInfo(activePage());
}

function renderCanvasInfo(page) {
  if (!page) {
    elements.canvasInfo.hidden = true;
    return;
  }
  elements.canvasInfo.hidden = false;
  const resolutionScale = canvasScaleForPage(page);
  const outputWidth = page.superResolutionPixelWidth
    ?? Math.round(page.pixelWidth * resolutionScale);
  const outputHeight = page.superResolutionPixelHeight
    ?? Math.round(page.pixelHeight * resolutionScale);
  const resolutionMarker = page.superResolutionApplied ? " *" : "";
  elements.canvasResolution.textContent = `${t("imageResolution")}: ${outputWidth} × ${outputHeight}${resolutionMarker}`;
  elements.canvasZoom.textContent = `${t("canvasZoom")}: ${canvasViewport.scale.toFixed(2)}×`;
}

function resetCanvasViewport(pageID) {
  canvasViewport.pageID = pageID;
  canvasViewport.scale = 1;
  canvasViewport.x = 0;
  canvasViewport.y = 0;
  canvasViewport.drag = null;
  applyCanvasViewport();
}

function zoomCanvas(event) {
  if (!activePage()) return;
  event.preventDefault();
  const canvases = [
    { stage: elements.sourceImageStage, stack: elements.sourceImageStack },
    { stage: elements.outputImageStage, stack: elements.outputPreviewStack },
  ];
  const canvas = canvases.find(({ stage, stack }) => stage === event.currentTarget
    && !stack.hidden
    && stack.offsetWidth
    && stack.offsetHeight)
    ?? canvases.find(({ stack }) => !stack.hidden && stack.offsetWidth && stack.offsetHeight);
  if (!canvas) return;
  const { stage, stack } = canvas;
  const stageRect = stage.getBoundingClientRect();
  const stackRect = stack.getBoundingClientRect();
  const viewportCenterX = stageRect.left + stage.clientLeft + stage.clientWidth / 2;
  const viewportCenterY = stageRect.top + stage.clientTop + stage.clientHeight / 2;
  const anchorX = stackRect.width > 0
    ? clamp((viewportCenterX - stackRect.left) / stackRect.width, 0, 1)
    : 0.5;
  const anchorY = stackRect.height > 0
    ? clamp((viewportCenterY - stackRect.top) / stackRect.height, 0, 1)
    : 0.5;
  const previous = canvasViewport.scale;
  const previousX = canvasViewport.x;
  const previousY = canvasViewport.y;
  let next = clamp(previous * Math.exp(-event.deltaY * 0.0015), 0.5, 12);
  if (Math.abs(next - 1) < 0.025) next = 1;
  canvasViewport.scale = next;
  if (next <= 1) {
    canvasViewport.x = 0;
    canvasViewport.y = 0;
  } else {
    applyCanvasStackLayout(elements.sourceImageStack, elements.sourcePreview);
    applyCanvasStackLayout(elements.outputPreviewStack, elements.outputPreview);
    const resizedRect = stack.getBoundingClientRect();
    const unshiftedLeft = resizedRect.left - previousX;
    const unshiftedTop = resizedRect.top - previousY;
    canvasViewport.x = viewportCenterX - unshiftedLeft - anchorX * resizedRect.width;
    canvasViewport.y = viewportCenterY - unshiftedTop - anchorY * resizedRect.height;
  }
  applyCanvasViewport();
  renderTranslationLayer(activePage());
}

function showNativePixelPreview() {
  const page = activePage();
  if (!page) return;
  const image = page.superResolutionApplied && !elements.outputPreview.hidden
    ? elements.outputPreview
    : elements.sourcePreview;
  const renderedWidth = image.getBoundingClientRect().width / Math.max(canvasViewport.scale, 0.0001);
  const renderedHeight = image.getBoundingClientRect().height / Math.max(canvasViewport.scale, 0.0001);
  if (!image.naturalWidth || !image.naturalHeight || renderedWidth <= 0 || renderedHeight <= 0) return;
  canvasViewport.scale = clamp(Math.min(
    image.naturalWidth / renderedWidth,
    image.naturalHeight / renderedHeight,
  ), 0.5, 12);
  canvasViewport.x = 0;
  canvasViewport.y = 0;
  applyCanvasViewport();
  renderTranslationLayer(page);
}

function beginCanvasPan(event) {
  if (event.button !== 0 || canvasViewport.scale <= 1) return;
  if (event.target.closest?.(".translation-text")) return;
  if (activeWorkflowStep === "mask" && event.target === elements.maskDrawingLayer && !event.shiftKey) return;
  const stage = event.currentTarget;
  canvasViewport.drag = {
    pointerID: event.pointerId,
    stage,
    startX: event.clientX,
    startY: event.clientY,
    originX: canvasViewport.x,
    originY: canvasViewport.y,
  };
  stage.setPointerCapture(event.pointerId);
  applyCanvasViewport();
  event.preventDefault();
}

function continueCanvasPan(event) {
  const drag = canvasViewport.drag;
  if (!drag || drag.pointerID !== event.pointerId || drag.stage !== event.currentTarget) return;
  canvasViewport.x = drag.originX + event.clientX - drag.startX;
  canvasViewport.y = drag.originY + event.clientY - drag.startY;
  applyCanvasViewport();
  event.preventDefault();
}

function finishCanvasPan(event) {
  const drag = canvasViewport.drag;
  if (!drag || drag.pointerID !== event.pointerId || drag.stage !== event.currentTarget) return;
  if (drag.stage.hasPointerCapture(event.pointerId)) drag.stage.releasePointerCapture(event.pointerId);
  canvasViewport.drag = null;
  applyCanvasViewport();
  event.preventDefault();
}

function resolvedTranslationDirection(region) {
  const translatedText = region.translatedText;
  const hasKoreanTranslation = /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]/u.test(translatedText);
  const hasCJKTranslation = /[\u3000-\u30ff\u3400-\u9fff\uf900-\ufaff]/u.test(translatedText);
  const hasLatinTranslation = /[A-Za-z\u00c0-\u024f]/u.test(translatedText);
  let direction;
  if (region.style.writingDirection !== "automatic") {
    direction = region.style.writingDirection;
  } else if (hasKoreanTranslation) {
    direction = "horizontal";
  } else if (hasLatinTranslation && !hasCJKTranslation) {
    direction = "horizontal";
  } else if (region.detectedWritingDirection !== "automatic") {
    direction = region.detectedWritingDirection;
  } else {
    const bounds = region.bounds;
    const hasCJK = /[\u1100-\u11ff\u3000-\u30ff\u3130-\u318f\u3400-\u9fff\uac00-\ud7af\uf900-\ufaff]/u.test(
      `${region.sourceText}${region.translatedText}`
    );
    direction = hasCJK && (region.sourceText.includes("　") || bounds.height > bounds.width * 0.8)
      ? "vertical"
      : "horizontal";
  }
  return hasKoreanTranslation && direction === "vertical"
    ? "vertical korean-vertical"
    : direction;
}

function translationAnchor(region) {
  if (region.translationAnchor) return region.translationAnchor;
  const bounds = translationLayoutBounds(region);
  return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
}

function translationLayoutBounds(region) {
  return region.translationBounds
    ?? region.bubbleLayoutBounds
    ?? region.bubbleBounds
    ?? region.bounds;
}

function translationSourceFontSize(page, region) {
  const sourceCount = Math.max(1, [...region.sourceText].filter((character) => !/\s/u.test(character)).length);
  const sourceArea = Math.max(
    1,
    translationLayoutBounds(region).width * page.pixelWidth
      * translationLayoutBounds(region).height * page.pixelHeight
  );
  const minimum = Math.max(4, region.style.minimumFontSize ?? 9);
  const maximum = Math.min(512, Math.max(minimum, region.style.maximumFontSize ?? 40));
  return region.style.fontSize ?? clamp(Math.sqrt(sourceArea / sourceCount) * 1.08, minimum, maximum);
}

function selectedTranslationRegion(page) {
  return page?.regions.find((region) => region.id === selectedTranslationRegionID) ?? null;
}

function renderTranslationFontTools(page) {
  const translationMode = activeWorkflowStep === "translate";
  elements.translationPrimaryTools.hidden = !translationMode;
  const region = selectedTranslationRegion(page);
  const disabled = !translationMode || !region || !region.translatedText.trim() || state.isProcessing;
  elements.translationFontDecrease.disabled = disabled;
  elements.translationFontIncrease.disabled = disabled;
  elements.translationFontRegular.disabled = disabled;
  elements.translationFontBold.disabled = disabled;
  elements.translationFontRegular.classList.toggle("active", Boolean(region) && region.style.fontWeight !== "bold");
  elements.translationFontBold.classList.toggle("active", region?.style.fontWeight === "bold");
  elements.translationFontSizeValue.textContent = region
    ? `${Math.round(translationSourceFontSize(page, region))} pt`
    : "—";
}

function selectTranslationRegion(page, regionID) {
  selectedTranslationRegionID = regionID;
  showInspectorTab("regions");
  for (const text of elements.translationLayer.querySelectorAll(".translation-text")) {
    text.classList.toggle("selected", text.dataset.regionID === regionID);
  }
  for (const row of elements.regionList.querySelectorAll(".region-row")) {
    row.classList.toggle("translation-selected", row.dataset.regionID === regionID);
  }
  renderTranslationFontTools(page);
  scrollRegionIntoView(regionID);
}

function adjustSelectedTranslationFontSize(delta) {
  const page = activePage();
  const region = selectedTranslationRegion(page);
  if (!page || !region || activeWorkflowStep !== "translate" || state.isProcessing) return;
  const previous = region.style.fontSize;
  const next = clamp(Math.round(translationSourceFontSize(page, region) + delta), 4, 512);
  if (next === previous) return;
  region.style.fontSize = next;
  renderTranslationLayer(page);
  invoke("updateRegion", {
    pageID: page.id,
    regionID: region.id,
    fontSize: next,
    useAutomaticFontSize: false,
  }).catch((error) => {
    region.style.fontSize = previous;
    renderTranslationLayer(activePage());
    showError(error);
  });
}

function setSelectedTranslationFontWeight(fontWeight) {
  const page = activePage();
  const region = selectedTranslationRegion(page);
  if (!page || !region || activeWorkflowStep !== "translate" || state.isProcessing) return;
  const previous = region.style.fontWeight ?? "regular";
  if (previous === fontWeight) return;
  region.style.fontWeight = fontWeight;
  renderTranslationLayer(page);
  invoke("updateRegion", {
    pageID: page.id,
    regionID: region.id,
    fontWeight,
  }).catch((error) => {
    region.style.fontWeight = previous;
    renderTranslationLayer(activePage());
    showError(error);
  });
}

function updateTranslationElementPosition(element, anchor) {
  element.style.left = `${anchor.x * 100}%`;
  element.style.top = `${anchor.y * 100}%`;
}

function updateTranslationElementBounds(element, bounds) {
  element.style.width = `${Math.max(0.01, bounds.width) * 100}%`;
  element.style.height = `${Math.max(0.01, bounds.height) * 100}%`;
}

function fitAutomaticTranslationText(element, page, region, resolutionScale = canvasScaleForPage(page)) {
  if (region.style.fontSize != null || !element.clientWidth || !element.clientHeight) return;
  let lower = Math.max(3, region.style.minimumFontSize ?? 4) * resolutionScale;
  let upper = Math.max(lower, region.style.maximumFontSize ?? 40) * resolutionScale;
  for (let index = 0; index < 10; index += 1) {
    const candidate = (lower + upper) / 2;
    element.style.fontSize = `${candidate}px`;
    if (element.scrollWidth <= element.clientWidth + 1
        && element.scrollHeight <= element.clientHeight + 1) {
      lower = candidate;
    } else {
      upper = candidate;
    }
  }
  element.style.fontSize = `${lower}px`;
}

function beginTranslationDrag(event, page, region, element) {
  if (event.button !== 0) return;
  selectTranslationRegion(page, region.id);
  const layerRect = elements.translationLayer.getBoundingClientRect();
  if (!layerRect.width || !layerRect.height) return;
  translationDrag = {
    pointerID: event.pointerId,
    pageID: page.id,
    regionID: region.id,
    element,
    layerRect,
    startX: event.clientX,
    startY: event.clientY,
    anchor: translationAnchor(region),
    minimumX: 0,
    maximumX: 1,
    minimumY: 0,
    maximumY: 1,
  };
  element.classList.add("dragging");
  element.setPointerCapture(event.pointerId);
  event.stopPropagation();
  event.preventDefault();
}

function beginTranslationResize(event, page, region, element) {
  if (event.button !== 0) return;
  selectTranslationRegion(page, region.id);
  const layerRect = elements.translationLayer.getBoundingClientRect();
  if (!layerRect.width || !layerRect.height) return;
  const layoutBounds = translationLayoutBounds(region);
  const anchor = translationAnchor(region);
  const startBounds = {
    x: clamp(anchor.x - layoutBounds.width / 2, 0, 1),
    y: clamp(anchor.y - layoutBounds.height / 2, 0, 1),
    width: layoutBounds.width,
    height: layoutBounds.height,
  };
  translationResize = {
    pointerID: event.pointerId,
    page,
    region,
    element,
    handle: event.currentTarget,
    layerRect,
    startX: event.clientX,
    startY: event.clientY,
    startBounds,
  };
  event.currentTarget.setPointerCapture(event.pointerId);
  element.classList.add("resizing");
  event.stopPropagation();
  event.preventDefault();
}

function continueTranslationResize(event) {
  if (!translationResize || translationResize.pointerID !== event.pointerId) return;
  const resize = translationResize;
  const width = clamp(
    resize.startBounds.width + (event.clientX - resize.startX) / resize.layerRect.width,
    0.02,
    1 - resize.startBounds.x
  );
  const height = clamp(
    resize.startBounds.height + (event.clientY - resize.startY) / resize.layerRect.height,
    0.02,
    1 - resize.startBounds.y
  );
  resize.currentBounds = { ...resize.startBounds, width, height };
  resize.currentAnchor = {
    x: resize.startBounds.x + width / 2,
    y: resize.startBounds.y + height / 2,
  };
  updateTranslationElementBounds(resize.element, resize.currentBounds);
  updateTranslationElementPosition(resize.element, resize.currentAnchor);
  fitAutomaticTranslationText(resize.element, resize.page, resize.region);
  event.stopPropagation();
  event.preventDefault();
}

function finishTranslationResize(event, cancelled = false) {
  if (!translationResize || translationResize.pointerID !== event.pointerId) return;
  const resize = translationResize;
  translationResize = null;
  resize.element.classList.remove("resizing");
  if (resize.handle.hasPointerCapture(event.pointerId)) {
    resize.handle.releasePointerCapture(event.pointerId);
  }
  if (cancelled || !resize.currentBounds) {
    renderTranslationLayer(activePage());
  } else {
    const previousBounds = resize.region.translationBounds;
    const previousAnchor = resize.region.translationAnchor;
    resize.region.translationBounds = resize.currentBounds;
    resize.region.translationAnchor = resize.currentAnchor;
    renderTranslationLayer(resize.page);
    invoke("updateRegion", {
      pageID: resize.page.id,
      regionID: resize.region.id,
      translationBounds: resize.currentBounds,
      translationAnchor: resize.currentAnchor,
    }).catch((error) => {
      resize.region.translationBounds = previousBounds;
      resize.region.translationAnchor = previousAnchor;
      renderTranslationLayer(activePage());
      showError(error);
    });
  }
  event.stopPropagation();
  event.preventDefault();
}

function continueTranslationDrag(event) {
  if (!translationDrag || translationDrag.pointerID !== event.pointerId) return;
  const anchor = {
    x: clamp(
      translationDrag.anchor.x + (event.clientX - translationDrag.startX) / translationDrag.layerRect.width,
      translationDrag.minimumX,
      translationDrag.maximumX
    ),
    y: clamp(
      translationDrag.anchor.y + (event.clientY - translationDrag.startY) / translationDrag.layerRect.height,
      translationDrag.minimumY,
      translationDrag.maximumY
    ),
  };
  translationDrag.currentAnchor = anchor;
  updateTranslationElementPosition(translationDrag.element, anchor);
  event.stopPropagation();
  event.preventDefault();
}

function finishTranslationDrag(event, cancelled = false) {
  if (!translationDrag || translationDrag.pointerID !== event.pointerId) return;
  const drag = translationDrag;
  translationDrag = null;
  drag.element.classList.remove("dragging");
  if (drag.element.hasPointerCapture(event.pointerId)) drag.element.releasePointerCapture(event.pointerId);
  if (cancelled || !drag.currentAnchor) {
    updateTranslationElementPosition(drag.element, drag.anchor);
  } else {
    invoke("updateRegion", {
      pageID: drag.pageID,
      regionID: drag.regionID,
      translationAnchor: drag.currentAnchor,
    }).catch((error) => {
      updateTranslationElementPosition(drag.element, drag.anchor);
      showError(error);
    });
  }
  event.stopPropagation();
  event.preventDefault();
}

function renderTranslationLayer(page) {
  elements.translationLayer.replaceChildren();
  if (!page) {
    selectedTranslationRegionID = null;
    elements.translationLayer.hidden = true;
    renderTranslationFontTools(null);
    return;
  }
  if (selectedTranslationRegionID && !page.regions.some((region) => region.id === selectedTranslationRegionID)) {
    selectedTranslationRegionID = null;
  }
  renderTranslationFontTools(page);
  const visible = activeWorkflowStep === "translate"
    && !elements.outputPreviewStack.hidden
    && page.regions.some((region) => region.style.isVisible !== false && region.translatedText.trim());
  elements.translationLayer.hidden = !visible;
  if (!visible) return;

  const displayWidth = elements.outputPreview.clientWidth;
  const displayHeight = elements.outputPreview.clientHeight;
  const resolutionScale = canvasScaleForPage(page);
  const logicalWidth = Math.max(1, page.pixelWidth * resolutionScale);
  const logicalHeight = Math.max(1, page.pixelHeight * resolutionScale);
  const scaleX = displayWidth > 0 ? displayWidth / logicalWidth : 1;
  const scaleY = displayHeight > 0 ? displayHeight / logicalHeight : scaleX;
  elements.translationLayer.style.width = `${logicalWidth}px`;
  elements.translationLayer.style.height = `${logicalHeight}px`;
  elements.translationLayer.style.transformOrigin = "top left";
  elements.translationLayer.style.transform = `scale(${scaleX}, ${scaleY})`;

  for (const [index, region] of page.regions.entries()) {
    if (region.style.isVisible === false || !region.translatedText.trim()) continue;
    const direction = resolvedTranslationDirection(region);
    const bounds = translationLayoutBounds(region);
    const text = document.createElement("div");
    text.className = `translation-text ${direction}`;
    text.classList.toggle("selected", region.id === selectedTranslationRegionID);
    text.dataset.regionID = region.id;
    text.textContent = region.translatedText;
    text.title = t("dragTranslationText", { number: index + 1 });
    text.style.fontFamily = region.style.fontName;
    text.style.fontSize = `${translationSourceFontSize(page, region) * resolutionScale}px`;
    text.style.fontWeight = region.style.fontWeight === "bold" ? "700" : "400";
    text.style.color = region.style.textColorHex;
    text.style.textAlign = region.style.textAlignment ?? "center";
    text.style.justifyContent = {
      start: "flex-start",
      end: "flex-end",
      center: "center",
    }[region.style.textAlignment ?? "center"];
    text.style.webkitTextStroke = `${Math.max(0, region.style.strokeWidth ?? 0) * resolutionScale}px ${region.style.strokeColorHex ?? "#FFFFFF"}`;
    text.style.paintOrder = "stroke fill";
    text.style.opacity = String(clamp(region.style.opacity ?? 1, 0, 1));
    text.style.transform = `translate(-50%, -50%) rotate(${region.style.rotationDegrees ?? 0}deg)`;
    updateTranslationElementBounds(text, bounds);
    updateTranslationElementPosition(text, translationAnchor(region));
    text.addEventListener("pointerdown", (event) => beginTranslationDrag(event, page, region, text));
    text.addEventListener("pointermove", continueTranslationDrag);
    text.addEventListener("pointerup", (event) => finishTranslationDrag(event));
    text.addEventListener("pointercancel", (event) => finishTranslationDrag(event, true));
    text.addEventListener("contextmenu", (event) => showRegionContextMenu(event, page, region));
    const resizeHandle = document.createElement("span");
    resizeHandle.className = "translation-resize-handle";
    resizeHandle.setAttribute("aria-hidden", "true");
    resizeHandle.addEventListener("pointerdown", (event) => beginTranslationResize(event, page, region, text));
    resizeHandle.addEventListener("pointermove", continueTranslationResize);
    resizeHandle.addEventListener("pointerup", (event) => finishTranslationResize(event));
    resizeHandle.addEventListener("pointercancel", (event) => finishTranslationResize(event, true));
    const interactionScale = Math.max(0.0001, Math.min(Math.abs(scaleX), Math.abs(scaleY)));
    const handleSize = 14 / interactionScale;
    resizeHandle.style.width = `${handleSize}px`;
    resizeHandle.style.height = `${handleSize}px`;
    resizeHandle.style.borderWidth = `${1 / interactionScale}px`;
    resizeHandle.style.borderRadius = `${2 / interactionScale}px`;
    text.append(resizeHandle);
    elements.translationLayer.append(text);
    fitAutomaticTranslationText(text, page, region);
  }
}

function showOutputPreview(source, alt) {
  if (elements.outputPreview.dataset.source !== source) {
    resetCanvasStackLayout(elements.outputPreviewStack, elements.outputPreview);
    elements.outputPreview.dataset.source = source;
    elements.outputPreview.src = source;
  }
  elements.outputPreview.alt = alt;
  elements.outputPreview.hidden = false;
  elements.outputPreviewStack.hidden = false;
  elements.outputPlaceholder.hidden = true;
}

function hideOutputPreview() {
  elements.outputPreview.hidden = true;
  elements.outputPreviewStack.hidden = true;
  elements.translationLayer.hidden = true;
  elements.outputPlaceholder.hidden = false;
}

function renderPage() {
  const page = activePage();
  syncWorkflowStep(page);
  const hasProject = Boolean(state.activeProjectID);
  elements.appendPages.disabled = !hasProject || state.isProcessing || state.isSwitchingProject;
  elements.emptyState.hidden = hasProject && Boolean(page);
  elements.workspace.hidden = !page;
  const outputStepActive = activeWorkflowStep === "compose";
  const hasImageToTextModel = state.loadedModels.some(
    (model) => model.capability === "imageToText"
  );
  const hasCalculatedOutput = Boolean(
    page?.maskPreviewURL
      || page?.maskAppliedPreviewURL
      || page?.translationPreviewURL
      || page?.outputPreviewURL
  );
  elements.reveal.textContent = t(outputStepActive ? "revealOutput" : "recalculate");
  elements.reveal.hidden = !page
    || (activeWorkflowStep === "pages" && !hasCalculatedOutput);
  elements.reveal.disabled = outputStepActive
    ? !page?.outputPreviewURL
    : !page || state.isProcessing || !hasImageToTextModel;
  elements.exportPSD.hidden = !outputStepActive;
  elements.exportPSD.disabled = !outputStepActive || !page || state.isProcessing
    || !Boolean(page.outputPreviewURL || page.translationPreviewURL || page.maskAppliedPreviewURL);
  const hasSuperResolutionModel = state.loadedModels.some(
    (model) => model.capability === "superResolution"
  );
  elements.superResolution.hidden = !page || activeWorkflowStep !== "translate";
  elements.superResolution.disabled = !page?.maskAppliedPreviewURL
    || state.isProcessing
    || Boolean(page?.superResolutionApplied);
  elements.superResolution.title = page?.superResolutionApplied
    ? t("superResolutionApplied")
    : hasSuperResolutionModel
      ? t("superResolution")
      : t("superResolutionModelRequired");
  elements.superResolution.setAttribute("aria-label", elements.superResolution.title);
  elements.canvasPixelPreview.disabled = !page || state.isProcessing;
  elements.workflowNext.hidden = !page || outputStepActive;
  elements.workflowNext.disabled = !page || state.isProcessing;
  elements.progress.value = page?.progress ?? 0;
  elements.projectPath.textContent = state.sourceDirectoryPath ?? "";
  renderCanvasInfo(page);
  if (!page) {
    hideOutputPreview();
    renderMaskEditor(null);
    renderTranslationLayer(null);
    renderRegions(null);
    return;
  }

  if (canvasViewport.pageID !== page.id) {
    selectedTranslationRegionID = null;
    resetCanvasViewport(page.id);
  }

  if (elements.sourcePreview.dataset.source !== page.sourcePreviewURL) {
    resetCanvasStackLayout(elements.sourceImageStack, elements.sourcePreview);
    elements.sourcePreview.dataset.source = page.sourcePreviewURL;
    elements.sourcePreview.src = page.sourcePreviewURL;
  }
  renderMaskEditor(page);
  const outputJob = state.batchJobs.find((job) =>
    ["compose", "fullPage"].includes(job.operation)
      && ["queued", "running"].includes(job.status)
      && job.pageIDs.includes(page.id)
  );
  const outputPending = page.stage === "composing" || Boolean(outputJob);
  if (activeWorkflowStep === "mask" && page.maskAppliedPreviewURL) {
    elements.resultPreviewCaption.textContent = t("maskAppliedPreview");
    showOutputPreview(
      `${page.maskAppliedPreviewURL}?updated=${page.maskRevision ?? "current"}`,
      t("maskedComicPage")
    );
  } else if (activeWorkflowStep === "translate" && page.superResolvedBackgroundPreviewURL) {
    elements.resultPreviewCaption.textContent = t("translationResult");
    showOutputPreview(
      page.superResolvedBackgroundPreviewURL,
      t("translationPreview")
    );
  } else if (activeWorkflowStep === "translate" && page.maskAppliedPreviewURL) {
    elements.resultPreviewCaption.textContent = t("translationResult");
    showOutputPreview(
      `${page.maskAppliedPreviewURL}?updated=${page.maskRevision ?? "current"}`,
      t("translationPreview")
    );
  } else if (activeWorkflowStep === "translate"
      && page.regions.some((region) => region.translatedText.trim())) {
    elements.resultPreviewCaption.textContent = t("translationResult");
    showOutputPreview(page.sourcePreviewURL, t("translationPreview"));
  } else if (page.outputPreviewURL) {
    elements.resultPreviewCaption.textContent = t("translationResult");
    showOutputPreview(page.outputPreviewURL, t("translatedComicPage"));
  } else if (page.translationPreviewURL) {
    elements.resultPreviewCaption.textContent = t("translationResult");
    showOutputPreview(page.translationPreviewURL, t("translationPreview"));
  } else if (page.maskAppliedPreviewURL) {
    elements.resultPreviewCaption.textContent = t("maskAppliedPreview");
    showOutputPreview(
      `${page.maskAppliedPreviewURL}?updated=${page.maskRevision ?? "current"}`,
      t("maskedComicPage")
    );
  } else {
    elements.resultPreviewCaption.textContent = t("translationResult");
    hideOutputPreview();
    elements.outputPlaceholder.textContent = outputPending
      ? t(outputJob?.status === "queued" ? "outputQueued" : "stageComposing")
      : t("noOutputYet");
  }
  elements.outputPlaceholder.classList.toggle("processing", outputPending);
  applyCanvasViewport();
  renderTranslationLayer(page);
  renderRegions(page);
}

function renderSettings() {
  const options = state.options;
  if (document.activeElement !== elements.targetLanguage) elements.targetLanguage.value = options.targetLanguageCode;
  elements.readingDirection.value = options.readingDirection;
  elements.writingDirection.value = options.defaultStyle.writingDirection;
  const selectedFont = options.defaultStyle.fontName;
  const availableFonts = [...new Set([
    selectedFont,
    ...(state.availableFontFamilies ?? []),
  ].filter(Boolean))];
  const fontOptionsSignature = availableFonts.join("\n");
  if (elements.fontName.dataset.optionsSignature !== fontOptionsSignature) {
    elements.fontName.replaceChildren(...availableFonts.map((fontName) => {
      const option = document.createElement("option");
      option.value = fontName;
      option.textContent = fontName;
      option.style.fontFamily = fontName;
      return option;
    }));
    elements.fontNameList.replaceChildren(...availableFonts.map((fontName) => {
      const option = document.createElement("button");
      option.type = "button";
      option.className = "font-preview-option";
      option.dataset.fontName = fontName;
      option.setAttribute("role", "option");
      const name = document.createElement("span");
      name.className = "font-preview-name";
      name.textContent = fontName;
      name.style.fontFamily = fontName;
      const sample = document.createElement("span");
      sample.className = "font-preview-sample";
      sample.textContent = "Aa 字 あ";
      sample.style.fontFamily = fontName;
      option.append(name, sample);
      option.addEventListener("click", () => {
        elements.fontName.value = fontName;
        closeFontPreviewList();
        elements.fontName.dispatchEvent(new Event("change", { bubbles: true }));
      });
      return option;
    }));
    elements.fontName.dataset.optionsSignature = fontOptionsSignature;
  }
  elements.fontName.value = selectedFont;
  elements.fontName.style.fontFamily = selectedFont;
  elements.fontNameValue.textContent = selectedFont;
  elements.fontNameValue.style.fontFamily = selectedFont;
  for (const option of elements.fontNameList.querySelectorAll(".font-preview-option")) {
    option.setAttribute("aria-selected", String(option.dataset.fontName === selectedFont));
  }
  const quality = options.translationQuality ?? {};
  elements.translationPageContext.checked = quality.usePageContext ?? true;
  elements.translationReviewPass.checked = quality.reviewPassEnabled ?? true;
  elements.translationQualityCheck.checked = quality.qualityCheckEnabled ?? true;
  elements.translationPreserveLiteral.checked = quality.preserveLiteralTranslation ?? true;
  elements.translationLengthMode.value = quality.lengthMode ?? "balanced";
  if (document.activeElement !== elements.translationStyleGuide) {
    elements.translationStyleGuide.value = quality.styleGuide ?? "";
  }
  elements.useImageModel.checked = false;
  elements.useImageModel.disabled = true;
  for (const control of [
    elements.targetLanguage,
    elements.readingDirection,
    elements.writingDirection,
    elements.fontName,
    elements.translationPageContext,
    elements.translationReviewPass,
    elements.translationQualityCheck,
    elements.translationPreserveLiteral,
    elements.translationLengthMode,
    elements.translationStyleGuide,
  ]) {
    control.disabled = !state.activeProjectID;
  }
}

function globalSettingsPayload(overrides = {}) {
  const current = state.globalSettings;
  return {
    interfaceLanguage: current.interfaceLanguage,
    colorScheme: current.colorScheme,
    imageCompositingBackend: current.imageCompositingBackend,
    dataDirectoryPath: current.dataDirectoryPath,
    imageToTextModelPath: current.imageToTextModelPath,
    imageToTextModelDownloadDirectoryPath: current.imageToTextModelDownloadDirectoryPath,
    imageToTextModelVariant: current.imageToTextModelVariant,
    imageToImageModelPath: current.imageToImageModelPath,
    automaticSuperResolutionEnabled: current.automaticSuperResolutionEnabled,
    superResolutionModelPath: current.superResolutionModelPath,
    superResolutionModelDownloadDirectoryPath: current.superResolutionModelDownloadDirectoryPath,
    superResolutionModelVariant: current.superResolutionModelVariant,
    mcpEnabled: current.mcpEnabled,
    mcpPort: current.mcpPort,
    mcpAllowedClients: current.mcpAllowedClients,
    ...overrides,
  };
}

function updateGlobalSettings(overrides) {
  if (!state?.globalSettings) return Promise.resolve();
  return invoke("updateGlobalSettings", globalSettingsPayload(overrides))
    .then(() => true)
    .catch((error) => {
      showError(error);
      return false;
    });
}

function renderMCPWhitelist(settings) {
  elements.mcpWhitelist.replaceChildren();
  if (!settings.mcpAllowedClients.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = t("noAllowedClients");
    elements.mcpWhitelist.append(empty);
    return;
  }
  for (const client of settings.mcpAllowedClients) {
    const row = document.createElement("div");
    row.className = "mcp-whitelist-row";
    const value = document.createElement("code");
    value.textContent = client;
    value.title = client;
    const remove = makeIconButton("fa-xmark", t("removeAllowedClient"), "quiet danger-text", () => {
      updateGlobalSettings({
        mcpAllowedClients: settings.mcpAllowedClients.filter((item) => item !== client),
      });
    });
    row.append(value, remove);
    elements.mcpWhitelist.append(row);
  }
}

function renderGlobalSettings() {
  const settings = state.globalSettings;
  if (!settings) return;
  if (interfaceLanguageSetting() !== settings.interfaceLanguage) {
    setInterfaceLanguage(settings.interfaceLanguage);
  }
  if (colorSchemeSetting() !== settings.colorScheme) {
    applyColorScheme(settings.colorScheme);
  }
  elements.settingsLanguage.value = settings.interfaceLanguage;
  elements.settingsColorScheme.value = settings.colorScheme;
  elements.settingsImageCompositingBackend.value = settings.imageCompositingBackend;
  elements.settingsDataDirectory.value = settings.configuredDataDirectoryPath ?? "";
  elements.dataDirectoryRestartNote.hidden = !settings.dataDirectoryRestartRequired;
  elements.settingsImageToTextModel.value = settings.imageToTextModelDownloadDirectoryPath ?? "";
  const modelOptions = settings.imageToTextModelOptions ?? [];
  const modelOptionsSignature = modelOptions
    .map((model) => [
      model.id,
      model.displayName,
      model.recommended,
      model.installed,
      t("recommended"),
      t("modelDownloaded"),
    ].join(":"))
    .join("\n");
  if (elements.settingsImageToTextModelVariant.dataset.optionsSignature !== modelOptionsSignature) {
    elements.settingsImageToTextModelVariant.replaceChildren(...modelOptions.map((model) => {
      const option = document.createElement("option");
      option.value = model.id;
      const annotations = [];
      if (model.recommended) annotations.push(t("recommended"));
      if (model.installed) annotations.push(t("modelDownloaded"));
      option.textContent = annotations.length > 0
        ? `${model.displayName}（${annotations.join(" · ")}）`
        : model.displayName;
      return option;
    }));
    elements.settingsImageToTextModelVariant.dataset.optionsSignature = modelOptionsSignature;
  }
  elements.settingsImageToTextModelVariant.value = settings.imageToTextModelVariant;
  const textModelDownload = settings.modelDownloadState?.capability === "imageToText"
    ? settings.modelDownloadState
    : null;
  const textModelDownloading = Boolean(textModelDownload);
  const textModelDirectorySelected = Boolean(settings.imageToTextModelDownloadDirectoryPath);
  elements.settingsImageToTextModelDownload.disabled = !textModelDirectorySelected
    || settings.imageToTextModelInstalled
    || textModelDownloading;
  elements.settingsImageToTextModelDownload.textContent = settings.imageToTextModelInstalled
    ? t("modelInstalled")
    : textModelDownloading
      ? t("downloadingModel")
      : t("downloadModel");
  elements.settingsImageToTextModelVariant.disabled = textModelDownloading;
  elements.settingsImageToTextModelClear.disabled = !textModelDownloading
    && !settings.imageToTextModelDownloadDirectoryPath
    && !settings.imageToTextModelPath;
  elements.settingsImageToTextModelClear.textContent = textModelDownloading
    ? t("stopDownload")
    : t("clear");
  elements.settingsImageToTextModelClear.classList.toggle("danger-text", textModelDownloading);
  elements.settingsImageToTextModelDelete.hidden = !settings.imageToTextModelInstalled;
  elements.settingsImageToTextModelDelete.disabled = textModelDownloading || state.isProcessing;
  elements.settingsImageToTextModelDownloadProgress.hidden = !textModelDownloading;
  if (textModelDownload) {
    const progress = Math.round(textModelDownload.progress * 100);
    elements.settingsImageToTextModelDownloadProgressBar.value = textModelDownload.progress;
    elements.settingsImageToTextModelDownloadStatus.textContent = textModelDownload.totalByteCount > 0
      ? t("modelDownloadProgressDetail", {
          progress,
          downloaded: formatByteCount(textModelDownload.downloadedByteCount),
          total: formatByteCount(textModelDownload.totalByteCount),
          speed: textModelDownload.bytesPerSecond > 0
            ? formatByteCount(textModelDownload.bytesPerSecond)
            : "—",
        })
      : t("modelDownloadProgress", { progress });
  }
  elements.settingsImageToImageModel.value = settings.imageToImageModelPath ?? "";
  elements.settingsAutomaticSuperResolution.checked = settings.automaticSuperResolutionEnabled;
  elements.settingsSuperResolutionModel.value = settings.superResolutionModelDownloadDirectoryPath ?? "";
  const superResolutionOptions = settings.superResolutionModelOptions ?? [];
  const superResolutionSignature = superResolutionOptions.map((model) => [
    model.id,
    model.displayName,
    model.recommended,
    model.installed,
    t("recommended"),
    t("modelDownloaded"),
  ].join(":")).join("\n");
  if (elements.settingsSuperResolutionModelVariant.dataset.optionsSignature !== superResolutionSignature) {
    elements.settingsSuperResolutionModelVariant.replaceChildren(...superResolutionOptions.map((model) => {
      const option = document.createElement("option");
      option.value = model.id;
      const annotations = [];
      if (model.recommended) annotations.push(t("recommended"));
      if (model.installed) annotations.push(t("modelDownloaded"));
      option.textContent = annotations.length > 0
        ? `${model.displayName}（${annotations.join(" · ")}）`
        : model.displayName;
      return option;
    }));
    elements.settingsSuperResolutionModelVariant.dataset.optionsSignature = superResolutionSignature;
  }
  elements.settingsSuperResolutionModelVariant.value = settings.superResolutionModelVariant;
  const superResolutionDownload = settings.modelDownloadState?.capability === "superResolution"
    ? settings.modelDownloadState
    : null;
  const superResolutionDownloading = Boolean(superResolutionDownload);
  const superResolutionDirectorySelected = Boolean(settings.superResolutionModelDownloadDirectoryPath);
  elements.settingsAutomaticSuperResolution.disabled = !settings.superResolutionModelInstalled;
  elements.settingsSuperResolutionModelDownload.disabled = !superResolutionDirectorySelected
    || settings.superResolutionModelInstalled
    || superResolutionDownloading;
  elements.settingsSuperResolutionModelDownload.textContent = settings.superResolutionModelInstalled
    ? t("modelInstalled")
    : superResolutionDownloading ? t("downloadingModel") : t("downloadModel");
  elements.settingsSuperResolutionModelVariant.disabled = superResolutionDownloading;
  elements.settingsSuperResolutionModelClear.disabled = !superResolutionDownloading
    && !settings.superResolutionModelDownloadDirectoryPath
    && !settings.superResolutionModelPath;
  elements.settingsSuperResolutionModelClear.textContent = superResolutionDownloading
    ? t("stopDownload") : t("clear");
  elements.settingsSuperResolutionModelClear.classList.toggle("danger-text", superResolutionDownloading);
  elements.settingsSuperResolutionModelDelete.hidden = !settings.superResolutionModelInstalled;
  elements.settingsSuperResolutionModelDelete.disabled = superResolutionDownloading || state.isProcessing;
  elements.settingsSuperResolutionModelDownloadProgress.hidden = !superResolutionDownloading;
  if (superResolutionDownload) {
    const progress = Math.round(superResolutionDownload.progress * 100);
    elements.settingsSuperResolutionModelDownloadProgressBar.value = superResolutionDownload.progress;
    elements.settingsSuperResolutionModelDownloadStatus.textContent = superResolutionDownload.totalByteCount > 0
      ? t("modelDownloadProgressDetail", {
          progress,
          downloaded: formatByteCount(superResolutionDownload.downloadedByteCount),
          total: formatByteCount(superResolutionDownload.totalByteCount),
          speed: superResolutionDownload.bytesPerSecond > 0
            ? formatByteCount(superResolutionDownload.bytesPerSecond) : "—",
        })
      : t("modelDownloadProgress", { progress });
  }
  elements.settingsMCPEnabled.checked = settings.mcpEnabled;
  elements.settingsMCPEndpointRow.hidden = !settings.mcpEnabled;
  elements.settingsMCPEndpoint.value = settings.mcpEndpointURL ?? "";
  if (document.activeElement !== elements.settingsMCPPort) {
    elements.settingsMCPPort.value = String(settings.mcpPort);
  }
  elements.settingsAppVersion.textContent = settings.appVersion;
  renderMCPWhitelist(settings);
}

function appendGlossaryTranslationRow(container, languageCode = "", term = "", targetLanguageCode = "") {
  const row = document.createElement("div");
  row.className = "glossary-translation-row";
  if (languageCode.toLocaleLowerCase() === targetLanguageCode.toLocaleLowerCase()) {
    row.classList.add("current-target");
  }
  const language = document.createElement("input");
  language.className = "glossary-language-code";
  language.placeholder = t("languageCodePlaceholder");
  language.value = languageCode;
  const value = document.createElement("input");
  value.className = "glossary-translation-value";
  value.placeholder = t("translatedTerm");
  value.value = term;
  const remove = makeIconButton("fa-xmark", t("removeLanguageTerm"), "quiet", () => row.remove());
  row.append(language, value, remove);
  container.append(row);
}

function collectGlossaryTranslations(container) {
  const translations = {};
  for (const row of container.querySelectorAll(".glossary-translation-row")) {
    const languageCode = row.querySelector(".glossary-language-code").value.trim();
    const term = row.querySelector(".glossary-translation-value").value.trim();
    if (!languageCode && !term) continue;
    if (!languageCode || !term) throw new Error(t("incompleteGlossaryTranslation"));
    translations[languageCode] = term;
  }
  return translations;
}

function targetLanguageDisplayName(languageCode) {
  const option = [...elements.targetLanguage.options]
    .find((item) => item.value === languageCode);
  return option?.textContent.trim() || languageCode;
}

function resolvedTargetLanguageCode(languageCode) {
  if (languageCode !== "auto") return languageCode;
  const locale = (navigator.language || "en-US").replace(/_/g, "-");
  const [language, ...parts] = locale.split("-");
  const region = parts.find((part) => part.length === 2)?.toUpperCase();
  const script = parts.find((part) => part.length === 4)?.toLowerCase();
  if (language === "zh") {
    return script === "hans" || ["CN", "SG"].includes(region) ? "zh-Hans" : "zh-Hant";
  }
  const codes = {
    ja: "ja-JP", en: "en-US", ko: "ko-KR", fr: "fr-FR", de: "de-DE", es: "es-ES",
    it: "it-IT", pt: "pt-BR", ru: "ru-RU", th: "th-TH", vi: "vi-VN", id: "id-ID",
  };
  return codes[language] ?? "en-US";
}

function renderGlossary() {
  const targetLanguageCode = resolvedTargetLanguageCode(state.options.targetLanguageCode);
  elements.glossaryCount.textContent = String(state.glossary.length);
  elements.glossaryTargetLabel.textContent = t("glossaryTarget", {
    language: targetLanguageDisplayName(targetLanguageCode),
  });
  elements.glossaryList.replaceChildren();
  elements.glossaryAdd.disabled = !state.activeProjectID;
  elements.glossarySource.disabled = !state.activeProjectID;
  elements.glossaryTargetTerm.disabled = !state.activeProjectID;

  if (!state.glossary.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = t("noGlossary");
    elements.glossaryList.append(empty);
    return;
  }

  for (const entry of state.glossary) {
    const row = document.createElement("article");
    row.className = "glossary-entry";
    const source = document.createElement("input");
    source.className = "glossary-source-term";
    source.value = entry.sourceTerm;
    source.setAttribute("aria-label", t("glossarySourceAria"));

    const translations = document.createElement("div");
    translations.className = "glossary-translations";
    const sortedTranslations = Object.entries(entry.translations).sort(([left], [right]) => {
      const target = targetLanguageCode.toLocaleLowerCase();
      if (left.toLocaleLowerCase() === target) return -1;
      if (right.toLocaleLowerCase() === target) return 1;
      return left.localeCompare(right);
    });
    for (const [languageCode, term] of sortedTranslations) {
      appendGlossaryTranslationRow(translations, languageCode, term, targetLanguageCode);
    }

    const note = document.createElement("input");
    note.className = "glossary-note";
    note.placeholder = t("noteOptional");
    note.value = entry.note ?? "";

    const controls = document.createElement("div");
    controls.className = "glossary-controls";
    controls.append(
      makeButton(t("addLanguage"), "quiet", () => appendGlossaryTranslationRow(
        translations,
        targetLanguageCode,
        "",
        targetLanguageCode
      )),
      makeButton(t("save"), "secondary", () => {
        try {
          invoke("upsertGlossaryEntry", {
            entryID: entry.id,
            sourceTerm: source.value,
            translations: collectGlossaryTranslations(translations),
            note: note.value,
          }).catch(showError);
        } catch (error) {
          showError(error);
        }
      }),
      makeButton(t("delete"), "quiet danger-text", () => {
        invoke("removeGlossaryEntry", { entryID: entry.id }).catch(showError);
      })
    );
    row.append(source, translations, note, controls);
    elements.glossaryList.append(row);
  }
}

function renderBatchJobs() {
  elements.batchList.replaceChildren();
  const jobs = [...state.batchJobs].reverse();
  if (!jobs.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = t("noBatchJobs");
    elements.batchList.append(empty);
    return;
  }

  for (const job of jobs) {
    const row = document.createElement("article");
    row.className = `batch-job batch-${job.status}`;
    const heading = document.createElement("div");
    heading.className = "batch-heading";
    const title = document.createElement("strong");
    const operationKey = operationLabelKeys[job.operation];
    title.textContent = t("batchTitle", {
      operation: operationKey ? t(operationKey) : job.operation,
      count: job.pageCount,
    });
    const status = document.createElement("span");
    const statusKey = jobStatusLabelKeys[job.status];
    status.textContent = statusKey ? t(statusKey) : job.status;
    heading.append(title, status);

    const progress = document.createElement("progress");
    progress.max = 1;
    progress.value = job.progress;
    const detail = document.createElement("small");
    detail.textContent = job.currentPageTitle
      ? t("processingPage", { title: job.currentPageTitle })
      : t(job.failureCount ? "batchSummaryWithFailures" : "batchSummary", {
          completed: job.completedCount,
          failed: job.failureCount,
        });
    row.append(heading, progress, detail);

    if (job.failureCount && job.projectID === state.activeProjectID) {
      const failures = document.createElement("ul");
      failures.className = "batch-failures";
      for (const failure of job.failures) {
        const item = document.createElement("li");
        item.textContent = `${failure.pageTitle}: ${failure.message}`;
        failures.append(item);
      }
      row.append(failures);
      row.append(makeButton(t("retryFailedPages"), "quiet", () => {
        invoke("retryFailedBatchJob", { jobID: job.id }).catch(showError);
      }));
    }
    elements.batchList.append(row);
  }
}

function renderSelectionSummary() {
  const count = state.selectedPageIDs.length;
  elements.selectionSummary.textContent = count
    ? t("selectionCount", { count, total: state.pages.length })
    : t("noBatchSelection");
}

function render(nextState) {
  if (nextState.isProcessing && !state?.isProcessing) stopRegionUpdateTimers();
  if (!nextState.isProcessing) regionUpdatesSuspended = false;
  state = nextState;
  renderProjects();
  renderPages();
  renderModels();
  renderPage();
  renderSettings();
  renderGlobalSettings();
  renderGlossary();
  renderBatchJobs();
  renderModelLoadingDialog();
  renderCalculationDialog();
  renderSelectionSummary();
  elements.cancel.disabled = !state.isProcessing;
  elements.status.textContent = state.statusMessage || t("ready");
}

function showError(error) {
  elements.status.textContent = error.message;
}

function syncNativeInterfaceLanguage() {
  return invoke("updateInterfaceLanguage", {
    setting: interfaceLanguageSetting(),
    resolvedLanguage: resolvedInterfaceLanguage(),
  });
}

function showSettingsPage(name) {
  for (const tab of document.querySelectorAll("[data-settings-tab]")) {
    tab.classList.toggle("active", tab.dataset.settingsTab === name);
  }
  for (const page of document.querySelectorAll("[data-settings-page]")) {
    const active = page.dataset.settingsPage === name;
    page.classList.toggle("active", active);
    page.hidden = !active;
  }
}

async function choosePreferenceDirectory(method, overrides) {
  const result = await invoke(method, overrides?.request ?? {}).catch(showError);
  if (!result?.path) return;
  await updateGlobalSettings(overrides.value(result.path));
}

function updateSettings() {
  const previousDefaultFont = state?.options.defaultStyle.fontName;
  const nextDefaultFont = elements.fontName.value;
  const previousRegionFonts = [];
  elements.fontName.style.fontFamily = elements.fontName.value;
  elements.fontNameValue.textContent = elements.fontName.value;
  elements.fontNameValue.style.fontFamily = elements.fontName.value;
  if (state && previousDefaultFont !== nextDefaultFont) {
    state.options.defaultStyle.fontName = nextDefaultFont;
    for (const page of state.pages) {
      for (const region of page.regions) {
        if (region.style.fontName !== previousDefaultFont) continue;
        previousRegionFonts.push([region, region.style.fontName]);
        region.style.fontName = nextDefaultFont;
      }
    }
    renderTranslationLayer(activePage());
  }
  invoke("updateSettings", {
    targetLanguageCode: elements.targetLanguage.value,
    readingDirection: elements.readingDirection.value,
    writingDirection: elements.writingDirection.value,
    fontName: elements.fontName.value,
    translationQuality: {
      usePageContext: elements.translationPageContext.checked,
      reviewPassEnabled: elements.translationReviewPass.checked,
      qualityCheckEnabled: elements.translationQualityCheck.checked,
      preserveLiteralTranslation: elements.translationPreserveLiteral.checked,
      lengthMode: elements.translationLengthMode.value,
      styleGuide: elements.translationStyleGuide.value,
    },
    useImageToImageRestoration: false,
  }).catch((error) => {
    if (state && previousDefaultFont !== nextDefaultFont) {
      state.options.defaultStyle.fontName = previousDefaultFont;
      for (const [region, fontName] of previousRegionFonts) region.style.fontName = fontName;
      renderTranslationLayer(activePage());
      renderSettings();
    }
    showError(error);
  });
}

function closeFontPreviewList() {
  elements.fontNameList.hidden = true;
  elements.fontNameTrigger.setAttribute("aria-expanded", "false");
}

function openFontPreviewList() {
  const bounds = elements.fontNameTrigger.getBoundingClientRect();
  const spaceBelow = window.innerHeight - bounds.bottom - 10;
  const spaceAbove = bounds.top - 10;
  const opensAbove = spaceBelow < 220 && spaceAbove > spaceBelow;
  const maximumHeight = Math.max(140, Math.min(360, opensAbove ? spaceAbove : spaceBelow));
  elements.fontNameList.style.left = `${Math.max(8, Math.min(bounds.left, window.innerWidth - Math.max(260, bounds.width) - 8))}px`;
  elements.fontNameList.style.width = `${Math.max(260, bounds.width)}px`;
  elements.fontNameList.style.maxHeight = `${maximumHeight}px`;
  elements.fontNameList.style.top = opensAbove
    ? `${Math.max(8, bounds.top - maximumHeight - 4)}px`
    : `${bounds.bottom + 4}px`;
  elements.fontNameList.hidden = false;
  elements.fontNameTrigger.setAttribute("aria-expanded", "true");
  const selected = elements.fontNameList.querySelector('[aria-selected="true"]');
  selected?.scrollIntoView({ block: "nearest" });
}

async function runBatch(operation, pageIDs, forceRecalculation = false) {
  if (!pageIDs.length) {
    showError(new Error(t("selectAtLeastOnePage")));
    return null;
  }
  if (["compose", "fullPage"].includes(operation) && !state.outputDirectoryPath) {
    const selection = await invoke("chooseOutputDirectory").catch((error) => {
      showError(error);
      return null;
    });
    if (!selection?.path) return null;
  }
  if (operation === "compose") {
    elements.status.textContent = t("outputQueuedCount", { count: pageIDs.length });
    if (pageIDs.includes(state?.selectedPageID) && !activePage()?.outputPreviewURL) {
      elements.outputPlaceholder.hidden = false;
      elements.outputPlaceholder.textContent = t("outputQueued");
      elements.outputPlaceholder.classList.add("processing");
    }
  }
  await flushPendingRegionUpdates();
  stopRegionUpdateTimers();
  const result = await invoke("runBatch", {
    operation,
    pageIDs,
    forceRecalculation,
  }).catch((error) => {
    showError(error);
    return null;
  });
  if (!result?.jobID) {
    regionUpdatesSuspended = false;
    renderRegions(activePage());
  }
  return result;
}

elements.outputPreview.addEventListener("error", () => {
  hideOutputPreview();
  elements.outputPlaceholder.textContent = t("outputPreviewLoadFailed");
  elements.outputPlaceholder.classList.remove("processing");
});
elements.outputPreview.addEventListener("load", () => {
  resetCanvasStackLayout(elements.outputPreviewStack, elements.outputPreview);
  requestAnimationFrame(() => {
    applyCanvasViewport();
    renderTranslationLayer(activePage());
  });
});
elements.sourcePreview.addEventListener("load", () => {
  resetCanvasStackLayout(elements.sourceImageStack, elements.sourcePreview);
  requestAnimationFrame(() => {
    applyCanvasViewport();
    renderTranslationLayer(activePage());
  });
});

window.addEventListener("resize", () => {
  resetCanvasStackLayout(elements.sourceImageStack, elements.sourcePreview);
  resetCanvasStackLayout(elements.outputPreviewStack, elements.outputPreview);
  requestAnimationFrame(() => {
    applyCanvasViewport();
    renderTranslationLayer(activePage());
  });
});

for (const stage of [elements.sourceImageStage, elements.outputImageStage]) {
  stage.addEventListener("wheel", zoomCanvas, { passive: false });
  stage.addEventListener("pointerdown", beginCanvasPan);
  stage.addEventListener("pointermove", continueCanvasPan);
  stage.addEventListener("pointerup", finishCanvasPan);
  stage.addEventListener("pointercancel", finishCanvasPan);
}

function addGlossaryEntry() {
  const sourceTerm = elements.glossarySource.value.trim();
  const translatedTerm = elements.glossaryTargetTerm.value.trim();
  if (!sourceTerm || !translatedTerm) {
    showError(new Error(t("glossaryTermRequired")));
    return;
  }
  invoke("upsertGlossaryEntry", {
    sourceTerm,
    translations: { [resolvedTargetLanguageCode(state.options.targetLanguageCode)]: translatedTerm },
  }).then(() => {
    elements.glossarySource.value = "";
    elements.glossaryTargetTerm.value = "";
  }).catch(showError);
}

document.querySelector("#import-pages").addEventListener("click", () => invoke("chooseSourceDirectory").catch(showError));
elements.deleteProject.addEventListener("click", () => deleteActiveProject().catch(showError));
document.querySelector("#open-settings").addEventListener("click", () => {
  showSettingsPage("general");
  elements.settingsDialog.showModal();
});
document.querySelector("#close-settings").addEventListener("click", () => elements.settingsDialog.close());
document.querySelector("#close-settings-icon").addEventListener("click", () => elements.settingsDialog.close());
elements.calculationDialog.addEventListener("cancel", (event) => event.preventDefault());
elements.modelLoadingDialog.addEventListener("cancel", (event) => {
  const loading = state?.modelLoadingState;
  if (loading?.phase !== "failed") {
    event.preventDefault();
    return;
  }
  dismissedModelLoadingFailureID = loading.id?.toLowerCase() ?? "unknown";
});
elements.modelLoadingClose.addEventListener("click", () => {
  const loading = state?.modelLoadingState;
  dismissedModelLoadingFailureID = loading?.id?.toLowerCase() ?? "unknown";
  closeModelLoadingDialog();
});
elements.calculationCancel.addEventListener("click", () => {
  elements.calculationCancel.disabled = true;
  closeCalculationDialog();
  invoke("cancelProcessing").catch((error) => {
    showError(error);
  });
});
for (const tab of document.querySelectorAll("[data-settings-tab]")) {
  tab.addEventListener("click", () => showSettingsPage(tab.dataset.settingsTab));
}
const inspectorTabs = [...document.querySelectorAll("[data-inspector-tab]")];
for (const [index, tab] of inspectorTabs.entries()) {
  tab.addEventListener("click", () => showInspectorTab(tab.dataset.inspectorTab));
  tab.addEventListener("keydown", (event) => {
    const nextIndex = event.key === "ArrowRight"
      ? (index + 1) % inspectorTabs.length
      : event.key === "ArrowLeft"
        ? (index - 1 + inspectorTabs.length) % inspectorTabs.length
        : event.key === "Home"
          ? 0
          : event.key === "End"
            ? inspectorTabs.length - 1
            : null;
    if (nextIndex === null) return;
    event.preventDefault();
    const nextTab = inspectorTabs[nextIndex];
    showInspectorTab(nextTab.dataset.inspectorTab);
    nextTab.focus();
  });
}
showInspectorTab(localStorage.getItem(inspectorTabStorageKey) ?? "project");
document.querySelector("#empty-create-project").addEventListener("click", () => invoke("chooseSourceDirectory").catch(showError));
elements.appendPages.addEventListener("click", () => invoke("appendPages").catch(showError));
document.querySelector("#rescan-source").addEventListener("click", () => invoke("rescanSourceDirectory").catch(showError));
document.querySelector("#export-psd").addEventListener("click", async () => {
  try {
    await flushPendingRegionUpdates();
    const pageIDs = state?.selectedPageIDs?.length ? state.selectedPageIDs : (activePage() ? [activePage().id] : []);
    await invoke("exportPSD", { pageIDs });
  } catch (error) {
    showError(error);
  }
});
document.querySelector("#process-selected").addEventListener("click", () => {
  runBatchWithCalculationDialog("fullPage", state?.selectedPageIDs ?? []).catch(showError);
});
document.querySelector('.workflow-step[data-step="pages"]').addEventListener("click", () => selectWorkflowStep("pages"));
document.querySelector("#detect-selected").addEventListener("click", () => {
  selectOrCalculateWorkflowStep("mask", "detectMasks").catch(showError);
});
document.querySelector("#translate-selected").addEventListener("click", () => {
  selectOrCalculateWorkflowStep("translate", "translate").catch(showError);
});
document.querySelector("#compose-selected").addEventListener("click", () => {
  selectOrCalculateWorkflowStep("compose", "compose").catch(showError);
});
document.querySelector("#cancel-processing").addEventListener("click", () => invoke("cancelProcessing").catch(showError));
document.querySelector("#clear-finished-jobs").addEventListener("click", () => invoke("clearFinishedBatchJobs").catch(showError));
elements.glossaryAdd.addEventListener("click", addGlossaryEntry);
elements.regionAdd.addEventListener("click", () => addTextRegion().catch(showError));
elements.regionContextDuplicate.addEventListener("click", () => duplicateContextRegion().catch(showError));
elements.regionContextDelete.addEventListener("click", () => deleteContextRegion().catch(showError));
elements.pageContextRename.addEventListener("click", () => renameContextPage().catch(showError));
elements.pageContextUp.addEventListener("click", () => moveContextPage(-1).catch(showError));
elements.pageContextDown.addEventListener("click", () => moveContextPage(1).catch(showError));
elements.pageContextDelete.addEventListener("click", () => removeContextPage().catch(showError));
document.addEventListener("pointerdown", (event) => {
  if (!elements.regionContextMenu.hidden && !elements.regionContextMenu.contains(event.target)) {
    hideRegionContextMenu();
  }
  if (!elements.pageContextMenu.hidden && !elements.pageContextMenu.contains(event.target)) {
    hidePageContextMenu();
  }
}, true);
window.addEventListener("blur", () => {
  hideRegionContextMenu();
  hidePageContextMenu();
});
window.addEventListener("resize", () => {
  hideRegionContextMenu();
  hidePageContextMenu();
  renderTranslationLayer(activePage());
});
document.querySelector("#select-visible").addEventListener("click", () => {
  const ids = filteredPages().map((page) => page.id);
  setSelection(ids, ids[0] ?? state.selectedPageID);
});
document.querySelector("#clear-selection").addEventListener("click", () => invoke("clearPageSelection").catch(showError));
document.querySelector("#reveal-output").addEventListener("click", () => {
  const page = activePage();
  if (!page) return;
  if (activeWorkflowStep === "compose") {
    invoke("revealOutput", { pageID: page.id }).catch(showError);
  } else if (activeWorkflowStep === "pages") {
    resetSelectedWorkflowPages().catch(showError);
  } else if (activeWorkflowStep === "mask") {
    selectOrCalculateWorkflowStep("mask", "detectMasks", true).catch(showError);
  } else if (activeWorkflowStep === "translate") {
    selectOrCalculateWorkflowStep("translate", "translate", true).catch(showError);
  }
});
elements.workflowNext.addEventListener("click", () => {
  advanceWorkflowStep().catch(showError);
});
elements.superResolution.addEventListener("click", () => {
  const page = activePage();
  if (!page) return;
  const hasModel = state.loadedModels.some((model) => model.capability === "superResolution");
  if (!hasModel) {
    showNotice(
      t("superResolutionModelRequiredTitle"),
      t("superResolutionModelRequired"),
      t("openSettings")
    ).then(() => {
      showSettingsPage("models");
      elements.settingsDialog.showModal();
    });
    return;
  }
  runBatchWithCalculationDialog("superResolve", [page.id]).catch(showError);
});
elements.canvasPixelPreview.addEventListener("click", showNativePixelPreview);

elements.maskBrush.addEventListener("click", () => {
  maskTool = "add";
  renderMaskEditor(activePage());
});
elements.maskEraser.addEventListener("click", () => {
  maskTool = "erase";
  renderMaskEditor(activePage());
});
elements.maskBrushSize.addEventListener("input", () => {
  elements.maskBrushSizeValue.value = `${elements.maskBrushSize.value} px`;
  updateMaskBrushCursor();
});
elements.translationFontDecrease.addEventListener("click", () => adjustSelectedTranslationFontSize(-1));
elements.translationUndo.addEventListener("click", () => {
  const page = activePage();
  if (page) invoke("undoRegionEdit", { pageID: page.id }).catch(showError);
});
elements.translationRedo.addEventListener("click", () => {
  const page = activePage();
  if (page) invoke("redoRegionEdit", { pageID: page.id }).catch(showError);
});
elements.translationFontIncrease.addEventListener("click", () => adjustSelectedTranslationFontSize(1));
elements.translationFontRegular.addEventListener("click", () => setSelectedTranslationFontWeight("regular"));
elements.translationFontBold.addEventListener("click", () => setSelectedTranslationFontWeight("bold"));
elements.maskUndo.addEventListener("click", () => {
  const page = activePage();
  const region = selectedMaskRegion(page);
  if (!page || !region) return;
  const preview = maskPreviewState(page);
  const pendingIndex = preview.pendingStrokes.findLastIndex((stroke) => stroke.regionID === region.id);
  const pendingStroke = pendingIndex >= 0 ? preview.pendingStrokes.splice(pendingIndex, 1)[0] : null;
  if (!preview.pendingStrokes.length) preview.pendingBaseRevision = null;
  renderMaskCanvas(page);
  renderMaskEditor(page);
  invoke("undoMaskStroke", { pageID: page.id, regionID: region.id }).catch((error) => {
    if (pendingStroke) preview.pendingStrokes.splice(pendingIndex, 0, pendingStroke);
    renderMaskCanvas(activePage());
    renderMaskEditor(activePage());
    showError(error);
  });
});
elements.maskRedo.addEventListener("click", () => {
  const page = activePage();
  const region = selectedMaskRegion(page);
  if (!page || !region) return;
  invoke("redoMaskStroke", { pageID: page.id, regionID: region.id }).catch(showError);
});
elements.maskDrawingLayer.addEventListener("pointermove", updateMaskBrushCursor);
elements.maskDrawingLayer.addEventListener("pointerenter", updateMaskBrushCursor);
elements.maskDrawingLayer.addEventListener("pointerleave", hideMaskBrushCursor);
elements.maskDrawingLayer.addEventListener("pointerdown", beginMaskStroke);
elements.maskDrawingLayer.addEventListener("pointermove", continueMaskStroke);
elements.maskDrawingLayer.addEventListener("pointerup", (event) => finishMaskStroke(event));
elements.maskDrawingLayer.addEventListener("pointercancel", (event) => finishMaskStroke(event, true));

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && (!elements.regionContextMenu.hidden || !elements.pageContextMenu.hidden)) {
    event.preventDefault();
    hideRegionContextMenu();
    hidePageContextMenu();
    return;
  }
  const target = event.target;
  if (target instanceof HTMLInputElement
      || target instanceof HTMLTextAreaElement
      || target instanceof HTMLSelectElement
      || target?.isContentEditable) return;
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
    const page = activePage();
    if (!page || activeWorkflowStep !== "translate") return;
    event.preventDefault();
    invoke(event.shiftKey ? "redoRegionEdit" : "undoRegionEdit", { pageID: page.id }).catch(showError);
    return;
  }
  const delta = event.key === "+" || event.code === "NumpadAdd"
    ? 1
    : event.key === "-" || event.code === "NumpadSubtract"
      ? -1
      : 0;
  if (!delta || activeWorkflowStep !== "translate" || !selectedTranslationRegion(activePage())) return;
  event.preventDefault();
  adjustSelectedTranslationFontSize(delta);
});

elements.projectSelector.addEventListener("change", () => {
  if (elements.projectSelector.value) {
    selectionAnchorID = null;
    invoke("switchProject", { projectID: elements.projectSelector.value }).catch(showError);
  }
});
elements.pageSearch.addEventListener("input", renderPages);
elements.pageFilter.addEventListener("change", renderPages);
elements.settingsLanguage.addEventListener("change", () => {
  setInterfaceLanguage(elements.settingsLanguage.value);
});
elements.settingsColorScheme.addEventListener("change", () => {
  applyColorScheme(elements.settingsColorScheme.value);
  updateGlobalSettings({ colorScheme: elements.settingsColorScheme.value });
});
elements.settingsImageCompositingBackend.addEventListener("change", () => {
  updateGlobalSettings({
    imageCompositingBackend: elements.settingsImageCompositingBackend.value,
  });
});
elements.settingsMCPEnabled.addEventListener("change", () => {
  updateGlobalSettings({ mcpEnabled: elements.settingsMCPEnabled.checked });
});
elements.settingsAutomaticSuperResolution.addEventListener("change", () => {
  updateGlobalSettings({
    automaticSuperResolutionEnabled: elements.settingsAutomaticSuperResolution.checked,
  });
});
elements.settingsMCPPort.addEventListener("change", () => {
  const port = Number(elements.settingsMCPPort.value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    showError(new Error(t("invalidMCPPort")));
    renderGlobalSettings();
    return;
  }
  updateGlobalSettings({ mcpPort: port });
});
document.querySelector("#choose-data-directory").addEventListener("click", () => {
  choosePreferenceDirectory("chooseDataDirectory", {
    value: (path) => ({ dataDirectoryPath: path }),
  });
});
document.querySelector("#reset-data-directory").addEventListener("click", () => {
  updateGlobalSettings({ dataDirectoryPath: null });
});
document.querySelector("#choose-image-to-text-model").addEventListener("click", () => {
  invoke("chooseModelDownloadDirectory", { capability: "imageToText" })
    .then((result) => {
      if (!result?.path) return;
      updateGlobalSettings({
        imageToTextModelDownloadDirectoryPath: result.path,
        imageToTextModelVariant: result.variant ?? state.globalSettings.imageToTextModelVariant,
      });
    })
    .catch(showError);
});
elements.settingsImageToTextModelVariant.addEventListener("change", () => {
  updateGlobalSettings({
    imageToTextModelVariant: elements.settingsImageToTextModelVariant.value,
  });
});
elements.settingsImageToTextModelDownload.addEventListener("click", () => {
  invoke("downloadPreferredModel", {
    capability: "imageToText",
    variantID: elements.settingsImageToTextModelVariant.value,
  }).catch(showError);
});
elements.settingsImageToTextModelClear.addEventListener("click", () => {
  if (state.globalSettings.modelDownloadState?.capability === "imageToText") {
    invoke("cancelModelDownload").catch(showError);
    return;
  }
  updateGlobalSettings({
    imageToTextModelPath: null,
    imageToTextModelDownloadDirectoryPath: null,
  });
});
elements.settingsImageToTextModelDelete.addEventListener("click", () => {
  const settings = state.globalSettings;
  if (!settings.imageToTextModelInstalled) return;
  const modelName = elements.settingsImageToTextModelVariant.selectedOptions[0]?.textContent
    ?? settings.imageToTextModelVariant;
  requestConfirmation(
    t("deleteInstalledModelTitle"),
    t("deleteInstalledModelConfirmation", { name: modelName }),
    t("delete")
  ).then((confirmed) => {
    if (!confirmed) return;
    return invoke("deleteInstalledModel", {
      capability: "imageToText",
      variantID: settings.imageToTextModelVariant,
    });
  }).catch(showError);
});
document.querySelector("#choose-image-to-image-model").addEventListener("click", () => {
  choosePreferenceDirectory("choosePreferredModelDirectory", {
    request: { capability: "imageToImage" },
    value: (path) => ({ imageToImageModelPath: path }),
  });
});
document.querySelector("#clear-image-to-image-model").addEventListener("click", () => {
  updateGlobalSettings({ imageToImageModelPath: null });
});
document.querySelector("#choose-super-resolution-model").addEventListener("click", () => {
  invoke("chooseModelDownloadDirectory", { capability: "superResolution" })
    .then((result) => {
      if (!result?.path) return;
      updateGlobalSettings({
        superResolutionModelDownloadDirectoryPath: result.path,
        superResolutionModelVariant: result.variant ?? state.globalSettings.superResolutionModelVariant,
      });
    })
    .catch(showError);
});
elements.settingsSuperResolutionModelVariant.addEventListener("change", () => {
  updateGlobalSettings({
    superResolutionModelVariant: elements.settingsSuperResolutionModelVariant.value,
  });
});
elements.settingsSuperResolutionModelDownload.addEventListener("click", () => {
  invoke("downloadPreferredModel", {
    capability: "superResolution",
    variantID: elements.settingsSuperResolutionModelVariant.value,
  }).catch(showError);
});
elements.settingsSuperResolutionModelClear.addEventListener("click", () => {
  if (state.globalSettings.modelDownloadState?.capability === "superResolution") {
    invoke("cancelModelDownload").catch(showError);
    return;
  }
  updateGlobalSettings({
    automaticSuperResolutionEnabled: false,
    superResolutionModelPath: null,
    superResolutionModelDownloadDirectoryPath: null,
  });
});
elements.settingsSuperResolutionModelDelete.addEventListener("click", () => {
  const settings = state.globalSettings;
  if (!settings.superResolutionModelInstalled) return;
  const modelName = elements.settingsSuperResolutionModelVariant.selectedOptions[0]?.textContent
    ?? settings.superResolutionModelVariant;
  requestConfirmation(
    t("deleteInstalledModelTitle"),
    t("deleteInstalledModelConfirmation", { name: modelName }),
    t("delete")
  ).then((confirmed) => {
    if (!confirmed) return;
    return invoke("deleteInstalledModel", {
      capability: "superResolution",
      variantID: settings.superResolutionModelVariant,
    });
  }).catch(showError);
});
function addMCPClient() {
  const client = elements.settingsMCPClient.value.trim().toLocaleLowerCase();
  if (!client) {
    showError(new Error(t("mcpClientRequired")));
    return;
  }
  const clients = [...new Set([...state.globalSettings.mcpAllowedClients, client])];
  updateGlobalSettings({ mcpAllowedClients: clients }).then((updated) => {
    if (updated) elements.settingsMCPClient.value = "";
  });
}

document.querySelector("#add-mcp-client").addEventListener("click", addMCPClient);
elements.settingsMCPClient.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    addMCPClient();
  }
});

window.addEventListener("mangakitchen-language-change", () => {
  elements.settingsLanguage.value = interfaceLanguageSetting();
  if (state) {
    renderPage();
    renderModelLoadingDialog();
  }
  syncNativeInterfaceLanguage().catch(showError);
});

elements.fontNameTrigger.addEventListener("click", () => {
  if (elements.fontNameList.hidden) openFontPreviewList();
  else closeFontPreviewList();
});
elements.fontNameTrigger.addEventListener("keydown", (event) => {
  if (["ArrowDown", "Enter", " "].includes(event.key)) {
    event.preventDefault();
    openFontPreviewList();
    elements.fontNameList.querySelector('[aria-selected="true"]')?.focus();
  }
});
elements.fontNameList.addEventListener("keydown", (event) => {
  const options = [...elements.fontNameList.querySelectorAll(".font-preview-option")];
  const index = options.indexOf(document.activeElement);
  let destination = null;
  if (event.key === "ArrowDown") destination = options[Math.min(options.length - 1, index + 1)];
  if (event.key === "ArrowUp") destination = options[Math.max(0, index - 1)];
  if (event.key === "Home") destination = options[0];
  if (event.key === "End") destination = options.at(-1);
  if (event.key === "Escape") {
    closeFontPreviewList();
    elements.fontNameTrigger.focus();
    event.preventDefault();
    return;
  }
  if (destination) {
    destination.focus();
    destination.scrollIntoView({ block: "nearest" });
    event.preventDefault();
  }
});
document.addEventListener("pointerdown", (event) => {
  if (elements.fontNameList.hidden) return;
  if (elements.fontNameList.contains(event.target) || elements.fontNameTrigger.contains(event.target)) return;
  closeFontPreviewList();
});

for (const control of [
  elements.targetLanguage,
  elements.readingDirection,
  elements.writingDirection,
  elements.fontName,
  elements.useImageModel,
  elements.translationPageContext,
  elements.translationReviewPass,
  elements.translationQualityCheck,
  elements.translationPreserveLiteral,
  elements.translationLengthMode,
]) {
  control.addEventListener("change", updateSettings);
}
elements.translationStyleGuide.addEventListener("change", updateSettings);

applyColorScheme(colorSchemeSetting());
applyTranslations();
onState(render);
invoke("bootstrap").catch(showError);
