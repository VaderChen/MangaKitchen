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
const colorSchemeStorageKey = "mangakitchen.color-scheme";

const elements = {
  projectSelector: document.querySelector("#project-selector"),
  pageList: document.querySelector("#page-list"),
  pageCount: document.querySelector("#page-count"),
  pageSearch: document.querySelector("#page-search"),
  pageFilter: document.querySelector("#page-filter"),
  modelList: document.querySelector("#model-list"),
  emptyState: document.querySelector("#empty-state"),
  workspace: document.querySelector("#page-workspace"),
  sourcePreview: document.querySelector("#source-preview"),
  outputPreview: document.querySelector("#output-preview"),
  outputPlaceholder: document.querySelector("#output-placeholder"),
  activePageTitle: document.querySelector("#active-page-title"),
  activePagePath: document.querySelector("#active-page-path"),
  regionList: document.querySelector("#region-list"),
  regionCount: document.querySelector("#region-count"),
  batchList: document.querySelector("#batch-list"),
  progress: document.querySelector("#page-progress"),
  status: document.querySelector("#status"),
  projectPath: document.querySelector("#project-path"),
  selectionSummary: document.querySelector("#selection-summary"),
  settingsDialog: document.querySelector("#settings-dialog"),
  settingsLanguage: document.querySelector("#settings-language"),
  settingsColorScheme: document.querySelector("#settings-color-scheme"),
  settingsDataDirectory: document.querySelector("#settings-data-directory"),
  dataDirectoryRestartNote: document.querySelector("#data-directory-restart-note"),
  settingsImageToTextModel: document.querySelector("#settings-image-to-text-model"),
  settingsImageToImageModel: document.querySelector("#settings-image-to-image-model"),
  settingsMCPEnabled: document.querySelector("#settings-mcp-enabled"),
  settingsMCPPort: document.querySelector("#settings-mcp-port"),
  settingsMCPClient: document.querySelector("#settings-mcp-client"),
  mcpWhitelist: document.querySelector("#mcp-whitelist"),
  settingsAppVersion: document.querySelector("#settings-app-version"),
  interfaceLanguage: document.querySelector("#interface-language"),
  targetLanguage: document.querySelector("#target-language"),
  readingDirection: document.querySelector("#reading-direction"),
  writingDirection: document.querySelector("#writing-direction"),
  fontName: document.querySelector("#font-name"),
  useImageModel: document.querySelector("#use-image-model"),
  glossaryCount: document.querySelector("#glossary-count"),
  glossaryTargetLabel: document.querySelector("#glossary-target-label"),
  glossarySource: document.querySelector("#glossary-source"),
  glossaryTargetTerm: document.querySelector("#glossary-target-term"),
  glossaryAdd: document.querySelector("#glossary-add"),
  glossaryList: document.querySelector("#glossary-list"),
  cancel: document.querySelector("#cancel-processing"),
  reveal: document.querySelector("#reveal-output"),
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

const stageLabelKeys = {
  pending: "stagePending",
  scanned: "stageScanned",
  detectingText: "stageDetectingText",
  maskReady: "stageMaskReady",
  translating: "stageTranslating",
  translationReady: "stageTranslationReady",
  composing: "stageComposing",
  completed: "stageCompleted",
  failed: "stageFailed",
};

const operationLabelKeys = {
  detectMasks: "operationDetectMasks",
  translate: "operationTranslate",
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

function activePage() {
  return state?.pages.find((page) => page.id === state.selectedPageID) ?? null;
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
  item.textContent = label;
  if (className) item.className = className;
  item.addEventListener("click", click);
  return item;
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
    return;
  }

  elements.projectSelector.disabled = state.isProcessing || state.isSwitchingProject;
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

function renderPages() {
  elements.pageList.replaceChildren();
  const visiblePages = filteredPages();
  const selected = selectedIDSet();
  elements.pageCount.textContent = t("pageCount", {
    visible: visiblePages.length,
    total: state.pages.length,
  });

  for (const page of visiblePages) {
    const item = document.createElement("li");
    item.className = "page-item";
    if (page.id === state.selectedPageID) item.classList.add("active");
    if (selected.has(page.id)) item.classList.add("selected");

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
    path.textContent = page.relativeSourcePath ?? page.title;
    const stage = document.createElement("span");
    stage.className = `stage-badge stage-${page.stage}`;
    const stageKey = stageLabelKeys[page.stage];
    stage.textContent = page.errorMessage || `${stageKey ? t(stageKey) : page.stage} · ${Math.round(page.progress * 100)}%`;
    content.append(title, path, stage);
    item.append(checkbox, preview, content);
    elements.pageList.append(item);
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
    const capability = model.capability === "imageToText" ? t("imageToText") : t("imageToImage");
    item.textContent = `${capability} · ${model.displayName}`;
    elements.modelList.append(item);
  }
}

function renderRegions(page) {
  elements.regionList.replaceChildren();
  elements.regionCount.textContent = String(page?.regions.length ?? 0);
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

    const heading = document.createElement("div");
    heading.className = "region-heading";
    const label = document.createElement("strong");
    label.textContent = t("regionNumber", { number: index + 1 });
    const confidence = document.createElement("small");
    confidence.textContent = t("recognitionConfidence", {
      percent: Math.round(region.confidence * 100),
    });
    heading.append(label, confidence);

    const source = document.createElement("p");
    source.className = "source-text";
    source.textContent = region.sourceText || t("noSourceText");

    const editor = document.createElement("textarea");
    editor.value = region.translatedText;
    editor.rows = 3;
    editor.setAttribute("aria-label", t("regionTranslationAria", { number: index + 1 }));

    const direction = document.createElement("select");
    for (const [value, labelKey] of [["automatic", "automaticTypesetting"], ["horizontal", "horizontal"], ["vertical", "vertical"]]) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = t(labelKey);
      option.selected = region.style.writingDirection === value;
      direction.append(option);
    }

    const save = makeButton(t("applyAndRelayout"), "secondary", () => {
      invoke("updateRegion", {
        pageID: page.id,
        regionID: region.id,
        translatedText: editor.value,
        writingDirection: direction.value,
      }).catch(showError);
    });
    const controls = document.createElement("div");
    controls.className = "region-controls";
    controls.append(direction, save);
    row.append(heading, source, editor, controls);
    elements.regionList.append(row);
  }
}

function renderPage() {
  const page = activePage();
  const hasProject = Boolean(state.activeProjectID);
  elements.emptyState.hidden = hasProject && Boolean(page);
  elements.workspace.hidden = !page;
  elements.reveal.disabled = !page?.outputPreviewURL;
  elements.progress.value = page?.progress ?? 0;
  elements.projectPath.textContent = state.sourceDirectoryPath ?? "";
  if (!page) {
    renderRegions(null);
    return;
  }

  elements.activePageTitle.textContent = `${page.index}. ${page.title}`;
  elements.activePagePath.textContent = page.relativeSourcePath ?? "";
  elements.sourcePreview.src = page.sourcePreviewURL;
  if (page.outputPreviewURL) {
    elements.outputPreview.src = `${page.outputPreviewURL}?updated=${Date.now()}`;
    elements.outputPreview.hidden = false;
    elements.outputPlaceholder.hidden = true;
  } else {
    elements.outputPreview.hidden = true;
    elements.outputPlaceholder.hidden = false;
  }
  renderRegions(page);
}

function renderSettings() {
  const options = state.options;
  if (document.activeElement !== elements.targetLanguage) elements.targetLanguage.value = options.targetLanguageCode;
  elements.readingDirection.value = options.readingDirection;
  elements.writingDirection.value = options.defaultStyle.writingDirection;
  if (document.activeElement !== elements.fontName) elements.fontName.value = options.defaultStyle.fontName;
  elements.useImageModel.checked = options.useImageToImageRestoration;
  for (const control of [elements.targetLanguage, elements.readingDirection, elements.writingDirection, elements.fontName, elements.useImageModel]) {
    control.disabled = !state.activeProjectID;
  }
}

function globalSettingsPayload(overrides = {}) {
  const current = state.globalSettings;
  return {
    interfaceLanguage: current.interfaceLanguage,
    colorScheme: current.colorScheme,
    dataDirectoryPath: current.dataDirectoryPath,
    imageToTextModelPath: current.imageToTextModelPath,
    imageToImageModelPath: current.imageToImageModelPath,
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
    const remove = makeButton("−", "quiet danger-text", () => {
      updateGlobalSettings({
        mcpAllowedClients: settings.mcpAllowedClients.filter((item) => item !== client),
      });
    });
    remove.title = t("removeAllowedClient");
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
  elements.interfaceLanguage.value = settings.interfaceLanguage;
  elements.settingsLanguage.value = settings.interfaceLanguage;
  elements.settingsColorScheme.value = settings.colorScheme;
  elements.settingsDataDirectory.value = settings.configuredDataDirectoryPath ?? "";
  elements.dataDirectoryRestartNote.hidden = !settings.dataDirectoryRestartRequired;
  elements.settingsImageToTextModel.value = settings.imageToTextModelPath ?? "";
  elements.settingsImageToImageModel.value = settings.imageToImageModelPath ?? "";
  elements.settingsMCPEnabled.checked = settings.mcpEnabled;
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
  const remove = makeButton("−", "quiet", () => row.remove());
  remove.title = t("removeLanguageTerm");
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

function renderGlossary() {
  const targetLanguageCode = state.options.targetLanguageCode;
  elements.glossaryCount.textContent = String(state.glossary.length);
  elements.glossaryTargetLabel.textContent = t("glossaryTarget", { language: targetLanguageCode });
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
  state = nextState;
  renderProjects();
  renderPages();
  renderModels();
  renderPage();
  renderSettings();
  renderGlobalSettings();
  renderGlossary();
  renderBatchJobs();
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
  invoke("updateSettings", {
    targetLanguageCode: elements.targetLanguage.value,
    readingDirection: elements.readingDirection.value,
    writingDirection: elements.writingDirection.value,
    fontName: elements.fontName.value,
    useImageToImageRestoration: elements.useImageModel.checked,
  }).catch(showError);
}

function runBatch(operation, pageIDs) {
  if (!pageIDs.length) {
    showError(new Error(t("selectAtLeastOnePage")));
    return;
  }
  invoke("runBatch", { operation, pageIDs }).catch(showError);
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
    translations: { [state.options.targetLanguageCode]: translatedTerm },
  }).then(() => {
    elements.glossarySource.value = "";
    elements.glossaryTargetTerm.value = "";
  }).catch(showError);
}

document.querySelector("#import-pages").addEventListener("click", () => invoke("chooseSourceDirectory").catch(showError));
document.querySelector("#open-settings").addEventListener("click", () => {
  showSettingsPage("general");
  elements.settingsDialog.showModal();
});
document.querySelector("#close-settings").addEventListener("click", () => elements.settingsDialog.close());
document.querySelector("#close-settings-icon").addEventListener("click", () => elements.settingsDialog.close());
for (const tab of document.querySelectorAll("[data-settings-tab]")) {
  tab.addEventListener("click", () => showSettingsPage(tab.dataset.settingsTab));
}
document.querySelector("#empty-create-project").addEventListener("click", () => invoke("chooseSourceDirectory").catch(showError));
document.querySelector("#choose-output").addEventListener("click", () => invoke("chooseOutputDirectory").catch(showError));
document.querySelector("#load-model").addEventListener("click", () => invoke("chooseModel").catch(showError));
document.querySelector("#rescan-source").addEventListener("click", () => invoke("rescanSourceDirectory").catch(showError));
document.querySelector("#process-selected").addEventListener("click", () => runBatch("fullPage", state?.selectedPageIDs ?? []));
document.querySelector("#process-all").addEventListener("click", () => runBatch("fullPage", state?.pages.map((page) => page.id) ?? []));
document.querySelector("#detect-selected").addEventListener("click", () => runBatch("detectMasks", state?.selectedPageIDs ?? []));
document.querySelector("#translate-selected").addEventListener("click", () => runBatch("translate", state?.selectedPageIDs ?? []));
document.querySelector("#compose-selected").addEventListener("click", () => runBatch("compose", state?.selectedPageIDs ?? []));
document.querySelector("#cancel-processing").addEventListener("click", () => invoke("cancelProcessing").catch(showError));
document.querySelector("#clear-finished-jobs").addEventListener("click", () => invoke("clearFinishedBatchJobs").catch(showError));
elements.glossaryAdd.addEventListener("click", addGlossaryEntry);
document.querySelector("#select-visible").addEventListener("click", () => {
  const ids = filteredPages().map((page) => page.id);
  setSelection(ids, ids[0] ?? state.selectedPageID);
});
document.querySelector("#clear-selection").addEventListener("click", () => invoke("clearPageSelection").catch(showError));
document.querySelector("#reveal-output").addEventListener("click", () => {
  const page = activePage();
  if (page) invoke("revealOutput", { pageID: page.id }).catch(showError);
});

elements.projectSelector.addEventListener("change", () => {
  if (elements.projectSelector.value) {
    selectionAnchorID = null;
    invoke("switchProject", { projectID: elements.projectSelector.value }).catch(showError);
  }
});
elements.pageSearch.addEventListener("input", renderPages);
elements.pageFilter.addEventListener("change", renderPages);
elements.interfaceLanguage.addEventListener("change", () => {
  setInterfaceLanguage(elements.interfaceLanguage.value);
});
elements.settingsLanguage.addEventListener("change", () => {
  setInterfaceLanguage(elements.settingsLanguage.value);
});
elements.settingsColorScheme.addEventListener("change", () => {
  applyColorScheme(elements.settingsColorScheme.value);
  updateGlobalSettings({ colorScheme: elements.settingsColorScheme.value });
});
elements.settingsMCPEnabled.addEventListener("change", () => {
  updateGlobalSettings({ mcpEnabled: elements.settingsMCPEnabled.checked });
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
  choosePreferenceDirectory("choosePreferredModelDirectory", {
    request: { capability: "imageToText" },
    value: (path) => ({ imageToTextModelPath: path }),
  });
});
document.querySelector("#clear-image-to-text-model").addEventListener("click", () => {
  updateGlobalSettings({ imageToTextModelPath: null });
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
  elements.interfaceLanguage.value = interfaceLanguageSetting();
  elements.settingsLanguage.value = interfaceLanguageSetting();
  syncNativeInterfaceLanguage().catch(showError);
});

for (const control of [elements.targetLanguage, elements.readingDirection, elements.writingDirection, elements.fontName, elements.useImageModel]) {
  control.addEventListener("change", updateSettings);
}

elements.interfaceLanguage.value = interfaceLanguageSetting();
applyColorScheme(colorSchemeSetting());
applyTranslations();
onState(render);
invoke("bootstrap").catch(showError);
