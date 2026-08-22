# MangaKitchen

[繁體中文](README.zh-TW.md) | English | [日本語](README.ja.md) | [한국어](README.ko.md)

MangaKitchen is a native macOS workspace for translating comics. Its frontend remains HTML + JavaScript, while the Swift Package backend is separated into a domain core, a Metal/Core ML runtime, and a WKWebView app. The core focuses on model boundaries, page-by-page workflows, dialogue regions, masks, and typesetting without coupling them to a particular UI layout.

<p align="center">
  <img src="AppPic/screen01.jpg" alt="MangaKitchen application window" width="800">
</p>

[Download the latest notarized DMG](https://github.com/VaderChen/MangaKitchen/releases/latest) · Requires macOS 14 or later

## Copyright and Lawful Use

All imported comic pages, characters, text, artwork, trademarks, and other content remain the property of their respective authors, publishers, licensed platforms, and other lawful rights holders. Using MangaKitchen does not transfer those rights or grant permission to reproduce, translate, publicly transmit, distribute, or sell a work.

MangaKitchen is intended to help authorized translators, localization teams, and other lawful users manage pages, masks, translations, terminology, and typesetting with less repetitive work, so readers can receive faster, higher-quality legitimate translations. A translation may be a derivative work. Obtain all required permissions before publishing, sharing, or distributing source material or translated output, and comply with applicable laws, content licenses, and the terms of any model or AI service you use.

Do not use MangaKitchen to create or distribute pirated copies, unauthorized scanlations, cracked content, or material that circumvents DRM, watermarks, or other rights-protection measures. The developers do not encourage or support copyright infringement. Please purchase official print editions, ebooks, subscriptions, and licensed merchandise through legitimate channels to support authors, translators, publishers, and the wider creative community.

## Software Licensing

MangaKitchen uses a dual-licensing model. Code in this repository that is owned by the MangaKitchen copyright holder and does not state otherwise is offered by default under the [GNU General Public License version 3 only](LICENSE) (`GPL-3.0-only`). A separate [commercial license](COMMERCIAL-LICENSE.md) is available for closed-source integration, proprietary distribution, or different contractual terms.

GPLv3 itself permits commercial use and paid distribution, subject to its source-code and copyleft obligations. Commercial licensing is an alternative and does not restrict rights already received under GPLv3. Third-party packages, models and weights, fonts, and comic content are outside MangaKitchen's dual license and remain subject to their own terms.

## Current Features

- macOS 14+ SwiftUI / WKWebView application shell.
- Asynchronous JSON bridge between HTML/JavaScript and Swift.
- Web UI in `AUTO`, Traditional Chinese, English, Japanese, and Korean. AUTO follows macOS; manual choices persist across launches and also apply to native panels and the MCP menu bar item.
- Global Settings dialog with General, Advanced, Models, MCP, and About tabs for language, color scheme, CPU/GPU image compositing, data location, multimodal/text/OCR/localization/SR model roles, MCP port, and IP/CIDR allowlist.
- Global Settings also persists the canvas selection color and a default output root. New projects use a sanitized project-name subfolder under that root; an existing project's explicit output folder is never replaced.
- Each source directory is an independent project. Multiple projects can be saved and switched from the toolbar.
- Recursive image scanning with relative subdirectory paths, natural sorting, and collision-safe handling of duplicate filenames.
- Command/Shift multi-selection, search, status filters, and batch mask detection, translation, and composition.
- A single sequential batch queue with current-page progress, success/failure counts, cancellation, history cleanup, and failed-page retry; region-by-region translation also reports the current region, total regions, and actual progress.
- A project-specific multilingual glossary. One source term can map to multiple BCP-47 languages, with automatic selection for the current target language.
- Four-stage workflow with strict artifact ownership: project/pages; dialogue regions, pixel masks, and clean background; transcription, translation, optional SR, and HTML typesetting preview; then final-output save. A later stage never reruns an earlier stage implicitly.
- One versioned `.str` JSON file per image, storing text, position, font, fixed/automatic size, and mask strokes.
- Pixel-layer dilation first absorbs anti-aliased edges, then normalized brush strokes add, erase, and undo masks before generating a binary PNG. Failed pixel refinement retains the coarse dialogue mask instead of silently dropping the region. After stage two, a CPU/GPU mask-cleanup preview with the original text removed appears immediately.
- Project-level erase-paper colors include `AUTO` estimation plus common white, cool-white, warm-white, ivory, and newsprint presets. A stage-one eyedropper samples the source page, while fixed-color cleanup removes pale JPEG/scanner halos without consuming dark speech-balloon outlines.
- A bundled manga109 bubble-segmentation Core ML model, preferring Apple Neural Engine execution, produces dialogue BBOX candidates and bubble shapes for black-and-white manga. Stage two always refines those confirmed bubbles into pixel-level glyph masks from the original image; changing an OCR/VLM text-localization preference cannot replace or alter this mask path. Apple Vision OCR is not used. Sound effects, page numbers, footer credits, people, and empty regions are deliberately excluded from the primary workflow.
- Stage two requires neither PP-OCR text detection nor an `imageToText` VLM. The Medium Det and VLM localization runtimes remain isolated from mask generation so model changes cannot regress existing bubble and pixel-mask behavior.
- Bundled native Swift/Core ML PP-OCRv6 Medium OCR is the default source-text recognizer during stage-three per-region or full-page translation, with the verified Small recognizer as fallback. Every OCR result remains separated by model ID with confidence, line boxes, and reading order; when `sourceText` is empty, the default OCR result becomes the translation source without changing bounds or masks. Existing VLM, Agent, or manually confirmed source text is never overwritten, and an OCR-only result does not claim the legacy `ocrTextRefined` confirmation flag.
- Translation can use a downloaded text-to-text model or a multimodal model. Text-to-text is the default and consumes the source text produced by OCR/VLM without reading the page image; multimodal translation can also use page context and can be selected for source localization and transcription. A multimodal VLM is therefore optional rather than a global workflow prerequisite.
- Stage-three controls can explicitly re-extract all region source text, retranslate using the existing source text, or re-extract and translate one selected region; these operations keep stage-two masks and clean backgrounds intact. Calculation dialogs show an elapsed `MM:SS` timer while work is waiting or running.
- Accepted dialogue regions use the dialogue BBOX as their search boundary, then are refined into pixel glyph masks from original-image pixels and shrink to the unexpanded glyph extents. Automatic layout direction prefers the measured glyph arrangement. Each candidate is isolated: if OCR or translation fails for one region, that region is preserved and the remaining regions continue; only cancellation stops the whole job.
- Page-context or text-only prompts and strict JSON response parsing for local translation models.
- Direct loading of local Hugging Face MLX text and multimodal model directories through `mlx-swift-lm` on Apple Silicon/Metal.
- Text and multimodal models are registered at startup but loaded only when first used. Canonical model identity prevents duplicate loads, concurrent requests for one capability are serialized, and high unified-memory pressure releases other runtimes before a large model is loaded.
- **Think Mode (Beta)** is optional and off by default. It streams a short reasoning pass into a safe Markdown view, keeps reasoning out of persistent logs, and uses the same loaded model for a deterministic non-thinking JSON finalization pass if reasoning did not produce a complete final value.
- Model-manifest loading for `.mlmodelc`, `.mlmodel`, and `.mlpackage`, with Core ML configured for Metal GPU execution.
- Dialogue masks use one or more pixel-level shapes to cover the original letters, clip to speech-area boundaries, and accept additive/eraser brush strokes; CPU or Metal GPU repair is available without an image model.
- HTML/CSS is the single source of truth for translation layout, including horizontal/vertical writing, fixed or automatic font sizing, per-region bold toggles, dragging, and resizing. WebKit renders the stage-three preview at the real SR pixel size, and stage four saves that exact preview without rebuilding it.
- Optional 2×/4× super-resolution preserves cleaned mask pixels, rerenders translated text at the resolved dimensions, and invalidates older 1× output so the final PNG and PSD cannot silently fall back to the pre-SR image.
- Source and output images are exposed to the Web UI through restricted custom URL schemes rather than arbitrary file access.
- Project indexes and states persist as versioned JSON. The previous version is kept as `.bak` before each write and validated on restore.
- Advanced settings can store a default output root. New projects without an explicit output folder automatically use a project-name subfolder under it, while an existing project's chosen output folder remains unchanged.
- Optional macOS 26 Swift/MLX Qwen Image Edit worker, using the mask both as model conditioning and as the final composition boundary.
- Optional standard MCP Streamable HTTP server with four-stage tools, workspace/image resources, cancellation, and progress notifications.
- When MCP is enabled, the app remains in the macOS menu bar and can reopen the main window after it is closed.
- An in-memory application log can be opened from the toolbar and cleared at any time. The bottom status bar shows live GPU/unified-memory use, image resolution, and canvas zoom through a transient update path that does not rebuild or interrupt editor controls.
- On-demand model loading is shown in a progress dialog. A separate launch-time check reports newer stable GitHub Releases, while Settings → About visibly lists the official repository and Releases URLs and provides a manual **Check for Updates** action. External navigation is restricted to those official GitHub paths; MangaKitchen never downloads or installs an update automatically.

## Two Usage Modes, One Project and Four-Step Workflow

MangaKitchen supports two operating modes. They change who performs inference and orchestration, but they do not create separate data formats or pipelines. Every job begins with a source-directory project; pages, masks, translations, typesetting settings, glossary entries, and output states remain scoped to that project.

Both modes follow these four steps:

1. **Project and pages**: choose a source directory, scan images recursively, and build a multi-selectable, batch-processable page list.
2. **Text, masks, and clean background**: locate dialogue BBOX candidates and bubble shapes with the bundled Core ML segmentation model, refine the original-image pixels into glyph masks, apply manual strokes, and produce the confirmed text-free background.
3. **OCR, translation, and typesetting preview**: the GUI extracts source text with bundled OCR or the selected VLM path, then translates with the selected text-to-text or multimodal model. Optional second-pass review and semantic QA use that same translation path. MCP instead gives an Agent an App-generated page bundle. The App preserves stage-two artifacts, optionally applies SR, and renders the complete HTML/CSS translation preview.
4. **Output**: copy the confirmed stage-three preview to the project's output directory. This stage does not rerun detection, masking, cleanup, transcription, translation, SR, or typesetting.

The four steps define resumable states, artifacts, and dependencies; they are not a mandatory checklist that restarts at step 1 every time. Both the GUI and MCP should inspect the App-provided page state and work package first, then begin at any step whose prerequisites already exist. Existing masks can go directly to translation, existing translations can go directly to typesetting or composition, and a single region can be edited without reprocessing the page. Completed region detection, masks, translations, and manual edits are not overwritten unless a user or Agent explicitly requests that stage again.

Before starting at any stage, each page must be validated against its actual artifacts rather than trusting the state label alone. If the requested stage lacks a prerequisite, walk backward one stage at a time until reaching the nearest work that must be regenerated:

- Before step 4, validate that the stage-three translation preview exists and is newer than any prior output. A missing or stale preview falls back to step 3; missing regions, mask, or clean background falls back again to step 2.
- Before step 3, validate the source page, text regions, source text supplied by OCR, VLM, Agent, or the user, and the mask. Incomplete data falls back to step 2.
- Before step 2, validate that the source image still exists and the project's page index is valid. Missing data falls back to step 1 and a rescan.
- Fallback regenerates only missing or invalid artifacts. Valid prerequisites remain untouched, and different pages may resume from different stages.

### Mode A: Download Models and Work Fully Offline

Download a text-to-text or multimodal translation model under Settings → Models. Region detection, source extraction, translation, background restoration, and composition run locally on the Mac. Once model files have been downloaded, comic content does not need to be sent to an external AI service.

- Text-to-text translation uses OCR/VLM source text without reading the image. The `imageToText` VLM is required only when the project explicitly selects VLM source extraction or multimodal translation. Stage-two masks, PP-OCR **Re-extract text**, text-only translation, re-typesetting, and output work without it. The app never falls back to Apple Vision OCR; an MCP Agent can provide source text and translations instead. Sound effects remain outside the current workflow.
- In the translation step, “Re-extract text” refreshes source text and clears dependent translations, while “Re-translate” reuses the current source text. A region-level refresh updates only the selected region and then rerenders the page preview.
- Background restoration belongs to step 2 and uses the configured Metal GPU neighborhood repair or CPU dominant-color speech-area repair; GPU failures automatically fall back to CPU. Later steps consume this clean background and never regenerate it.
- The GUI can run each step separately or use “Process Selected/All.” One-click processing still executes steps 2–4 in order and preserves their intermediate data.
- Every result is written back to the project and `.str`, so users can correct any stage and rerun only the downstream steps.

### Mode B: Proofread Through MCP (Recommended)

> **Recommended flow: finish stage two locally, then use MCP for proofreading.** MCP preserves the App-generated regions, masks, and clean background instead of rebuilding or overwriting them. A later stage never runs an earlier stage implicitly.

Enable MCP under Settings → MCP, configure the port and client IP/CIDR allowlist, then connect an AI Agent that supports Streamable HTTP. MCP provides one page work package instead of asking the Agent to decompose, clear, or rebuild the four stages.

1. In the GUI, open the project and complete stage two (regions, pixel mask, and clean background) for the requested pages.
2. Enable MCP under Settings → MCP and connect an AI Agent that supports Streamable HTTP.
3. The Agent calls `mangakitchen.workspace.open` to obtain `workspace_id`, then calls `mangakitchen.page.prepare_agent_task` for each requested page. The tool only packages completed stage-two data; if the mask or clean background is missing, it stops and asks the user to finish stage two in the App.
4. The Agent processes each existing region: treat non-empty `sourceText` and `translatedText` as drafts to proofread against the image, fill or correct empty or inaccurate text, and adjust HTML typesetting bounds, anchor, size, weight, and writing direction. It must not add, remove, merge, or modify regions or masks.
5. Call `mangakitchen.page.submit_agent_result` once with all proofread text, translations, and typesetting results. This completes the stage-three translation/typesetting preview without writing final output. Only when the user requests export, call `mangakitchen.page.render`; stage four copies the completed preview to the output directory without rerunning masking, background cleanup, translation, or typesetting.

`region_source` and the older per-region tools remain for compatibility and are not the default MCP flow. MCP step three is fully Agent-owned; the App does not run its built-in VLM transcription or translation. The Agent must not search for, read, or create `.str` files, and it does not need to read multiple page resources or call `region.update`.

For existing projects, the Agent must not clear, rescan, or rerun completed stages on its own; it prepares a work package only for pages requested by the user. `workspace.pages` is a status query, not an instruction to start an autonomous loop.

MCP mode also supports multiple workspaces, explicit `workspace_id` values, multi-page batches, project glossaries, cancellation, and progress notifications. The AI Agent is a workflow operator, not a separate storage backend.

## Running

```bash
swift build
swift run MangaKitchen
```

Start the MCP server together with the GUI:

```bash
swift run MangaKitchen --mcp=on
```

The GUI always starts. When `--mcp` is omitted, the saved Settings value is used; `--mcp=on|off` overrides it for the current launch. The listener binds to `0.0.0.0`, uses port `12080` by default, and only accepts the actual source IP/CIDR entries in the allowlist. The default allowlist contains only `127.0.0.1`. The local endpoint is `http://127.0.0.1:12080/mcp`; `--mcp-port=<port>` overrides the port for the current launch. Closing the main window does not terminate the app, which can be reopened from the menu bar.

Data-location changes take effect after restart. Image-to-text and super-resolution model changes are applied immediately. Changing the MCP switch, port, or allowlist restarts the listener.

Project indexes, project states, and intermediate files are stored by default under:

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Artifacts/<page-uuid>/
```

Each `.str` is stored beside its source image: for example, `ComicTest/001.webp` maps to `ComicTest/001.str`. The selected output folder contains only final PNG files. Legacy `.str` files are copied beside their source images and retained at their old locations.

A legacy `Workspace/workspace.json` is migrated into the first project on initial launch. The original file is retained.

## Model Format

Every model directory must contain `mangakitchen-model.json`. Examples are available at:

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

Manifest feature names must match the actual Core ML model. The current Core ML adapter supports:

- Image-to-text: an image feature, an optional string prompt feature, and a string output feature.
- Image-to-image: an image feature, optional mask/prompt features, and an image output feature.

The Core ML manifest is a generic adapter for models packaged as one prediction. Models such as Qwen-VL that require tokenizers and autoregressive decoding use a dedicated MLX adapter. Diffusion models with sampler loops likewise require a dedicated `ImageToImageGenerating` adapter; changing only the Core ML feature names is insufficient. The core pipeline does not need to change.

`MLXTextRuntime` and `MLXVLMRuntime` load local text-only or multimodal models whose `model_type` is supported by `mlx-swift-lm`. The managed catalog recommends `mlx-community/Qwen3-4B-4bit` for text-only translation and the approximately 3 GB `lmstudio-community/Qwen3.5-4B-MLX-4bit` for multimodal work:

1. Download the complete Hugging Face model into a local directory.
2. Copy `Examples/Models/MLXVLMModel/mangakitchen-model.json` into the model directory root.
3. Select that directory in the app. The path is registered immediately; the model container loads on first use and is then reused across pages until memory pressure requires release.

The `mlx-swift-lm` factory selects architecture from `config.json`, so a single safetensors file is not enough. Keep the tokenizer, processor, chat template, and config files together.

## Qwen Image Edit Worker

Image-to-image inference uses a separate Swift Package so large models can be fully released after completion or cancellation without raising the main app's deployment target. It currently requires macOS 26:

```bash
Scripts/build-qwen-image-edit-worker.sh
```

Development builds automatically search for:

```text
RuntimeSupport/QwenImageEditWorker/.build/release/MangaKitchenQwenImageEditWorker
```

A production `.app` should copy it into `Contents/Helpers/`. `MANGAKITCHEN_QWEN_WORKER` can also specify its absolute path.

INT4 model directory layout:

```text
QwenImageEditModel/
  mangakitchen-model.json
  snapshot/
    vae/
    text_encoder/
    processor/
    transformer/       # Required for INT8/FP16; may remain for INT4
  quantized/
    qie-2511-dit-int4-mod8.safetensors
    qie-2511-vl7b-int4.safetensors
```

`snapshot` comes from the Qwen Image Edit 2511 base model, while the two INT4 files are prequantized for the Swift runtime. This is not a generic `mlx_lm` layout. The worker receives the source image and binary mask; the main app then composites generated pixels only inside the mask.

## Package Layers

```text
MangaKitchenCore
  Domain data, geometry, processing options, model and workflow protocols

MangaKitchenRuntime
  Enclosure detection and VLM transcription, reading order, Core ML/Metal, masks, restoration

MangaKitchenApp
  SwiftUI window, WKWebView, custom URL schemes, JSON bridge, HTML/JavaScript layout and PNG output

MangaKitchenApp/MCP
  Toggleable MCP Streamable HTTP adapter and lifecycle in the GUI process
```

See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for architectural decisions and data flow.
See [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md) for the four-stage Swift/JavaScript/MCP contract.
See [the build 0323 release notes](Documentation/RELEASE_NOTES_1.26.0823-build-0323.md) for the latest packaged changes, Developer ID signature, notarization status, and verified download checksum.
See [the current development release notes](Documentation/RELEASE_NOTES_UNRELEASED.md) for changes after the latest package.

## Known Boundaries

- The bundled `manga109-segmentation-bubble`, PP-OCRv6 Medium Core ML default, and PP-OCRv6 Small fallback models are derived from Apache-2.0 source models. Original image-to-text weights, super-resolution weights, and experimental image-edit model weights are not bundled; their size, licensing, and distribution policy remain separate concerns. The converted OCR `.mlpackage` packages, character lists, and adjacent Apache-2.0 notices are included in this repository.
- Dialogue BBOX or Agent boxes are refined with luminance and connected components from original-image pixels; segmentation shapes clip the search area and the mask uses pixel-layer dilation. Dark/color artwork and non-dialogue text still require precise Agent polygons without changing `DialogueRegion` output.
- Fixed-paper-color and Metal neighborhood cleanup work best in dialogue areas with a stable paper tone. Complex screen tones or text crossing line art may still need mask correction and manual retouching.
- The optional Qwen Image Edit worker remains experimental, needs roughly 25 GB of inference memory, and is not part of the default four-stage cleanup path.
- Direct Swift Package execution does not yet include App Sandbox security-scoped bookmarks, signing, notarization, or production `.app` packaging.
- Moving source or model directories can invalidate restored paths until security-scoped bookmarks are implemented.
