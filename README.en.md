# MangaKitchen

[繁體中文](README.md) | English | [日本語](README.ja.md) | [한국어](README.ko.md)

MangaKitchen is a native macOS workspace for translating comics. Its frontend remains HTML + JavaScript, while the Swift Package backend is separated into a domain core, a Metal/Core ML runtime, and a WKWebView app. The core focuses on model boundaries, page-by-page workflows, dialogue regions, masks, and typesetting without coupling them to a particular UI layout.

<p align="center">
  <img src="AppPic/screen01.jpg" alt="MangaKitchen application window" width="800">
</p>

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
- Global Settings dialog with General, Advanced, Models, MCP, and About tabs for language, color scheme, CPU/GPU image compositing, data location, model paths, MCP port, and IP/CIDR allowlist.
- Each source directory is an independent project. Multiple projects can be saved and switched from the toolbar.
- Recursive image scanning with relative subdirectory paths, natural sorting, and collision-safe handling of duplicate filenames.
- Command/Shift multi-selection, search, status filters, and batch mask detection, translation, and composition.
- A single sequential batch queue with current-page progress, success/failure counts, cancellation, history cleanup, and failed-page retry.
- A project-specific multilingual glossary. One source term can map to multiple BCP-47 languages, with automatic selection for the current target language.
- Four-stage workflow: scan, text/mask, translation/typesetting settings, and background restoration/composition, plus full-page and all-page orchestration.
- One versioned `.str` JSON file per image, storing text, position, font, fixed/automatic size, and mask strokes.
- Normalized vector brush strokes for adding, erasing, and undoing masks before generating a binary PNG. After stage two, a CPU/GPU mask-cleanup preview with the original text removed appears immediately without starting the image-to-image model.
- For black-and-white manga, system Vision OCR and enclosed-light-region detection run independently. Each OCR block is assigned to its best enclosure, while unassigned blocks remain standalone text. Every enclosure is sent to the image-to-text model even when OCR found nothing; OCR, VLM output, and enclosure geometry are then merged and deduplicated. Sound effects, page numbers, footer credits, people, and empty regions are deliberately excluded from the current primary workflow.
- Candidate text is refined into glyph polygons with connected components before OCR is proofread in full-page-context batches; raw and corrected text are stored, and a page is not marked complete when any region is missing.
- Page-context prompts and strict JSON response parsing for image-to-text translation models.
- Direct loading of local Hugging Face MLX VLM directories through `mlx-swift-lm` on Apple Silicon/Metal.
- Model-manifest loading for `.mlmodelc`, `.mlmodel`, and `.mlpackage`, with Core ML configured for Metal GPU execution.
- Dialogue masks use one or more polygons to cover the original letters, clip to speech-area boundaries, and accept additive/eraser brush strokes; CPU or Metal GPU repair is available without an image model.
- Core Text anchors translations to the original glyph position and scale, supports horizontal/vertical typesetting, shrinks overflow first, partitions multiple regions in one bubble into non-overlapping lanes, and hard-clips text to the bubble interior before relayout after manual edits.
- Source and output images are exposed to the Web UI through restricted custom URL schemes rather than arbitrary file access.
- Project indexes and states persist as versioned JSON. The previous version is kept as `.bak` before each write and validated on restore.
- Optional macOS 26 Swift/MLX Qwen Image Edit worker, using the mask both as model conditioning and as the final composition boundary.
- Optional standard MCP Streamable HTTP server with four-stage tools, workspace/image resources, cancellation, and progress notifications.
- When MCP is enabled, the app remains in the macOS menu bar and can reopen the main window after it is closed.

## Two Usage Modes, One Project and Four-Step Workflow

MangaKitchen supports two operating modes. They change who performs inference and orchestration, but they do not create separate data formats or pipelines. Every job begins with a source-directory project; pages, masks, translations, typesetting settings, glossary entries, and output states remain scoped to that project.

Both modes follow these four steps:

1. **Project and pages**: choose a source directory, scan images recursively, and build a multi-selectable, batch-processable page list.
2. **Text and masks**: detect dialogue regions and source text, refine coarse boxes into glyph masks, and correct OCR once with a local LLM, Agent, or human before mask editing.
3. **Translation and typesetting**: write each region's source text, translated text, position, font, and size to the image's `.str` file.
4. **Restoration and composition**: remove the original text, restore the background, typeset the translation, and save it to the project's output directory.

The four steps define resumable states, artifacts, and dependencies; they are not a mandatory checklist that restarts at step 1 every time. Both the GUI and MCP should inspect page state and `.str` first, then begin at any step whose prerequisites already exist. Existing masks can go directly to translation, existing translations can go directly to typesetting or composition, and a single region can be edited without reprocessing the page. Completed OCR, masks, translations, and manual edits are not overwritten unless a user or Agent explicitly requests that stage again.

Before starting at any stage, each page must be validated against its actual artifacts rather than trusting the state label alone. If the requested stage lacks a prerequisite, walk backward one stage at a time until reaching the nearest work that must be regenerated:

- Before step 4, validate the mask and usable `.str` translations/typesetting data. Missing translations fall back to step 3; missing text regions or masks fall back again to step 2.
- Before step 3, validate the source page, text regions, once-corrected OCR source text, and mask. Incomplete data falls back to step 2.
- Before step 2, validate that the source image still exists and the project's page index is valid. Missing data falls back to step 1 and a rescan.
- Fallback regenerates only missing or invalid artifacts. Valid prerequisites remain untouched, and different pages may resume from different stages.

### Mode A: Download Models and Work Fully Offline

Set an image-to-text model and, optionally, an image-to-image model under Settings → Models. OCR, translation, background restoration, and composition run locally on the Mac. Once model files have been downloaded, comic content does not need to be sent to an external AI service.

- The `imageToText` model classifies title/dialogue candidates, supplements enclosed regions missed by OCR, and completes OCR correction in step 2, then performs page-context translation in step 3. System OCR, VLM output, and enclosure geometry are merged and deduplicated first. Without a loaded model, system OCR can still build masks independently. Sound effects stay outside the current translation workflow, and proofreading and translation are batched and validated for every region.
- The `imageToImage` model performs background restoration in step 4 and is optional. Without it, Settings → Advanced selects Metal GPU neighborhood repair or CPU dominant-color speech-area repair; GPU failures automatically fall back to CPU.
- The GUI can run each step separately or use “Process Selected/All.” One-click processing still executes steps 2–4 in order and preserves their intermediate data.
- Every result is written back to the project and `.str`, so users can correct any stage and rerun only the downstream steps.

### Mode B: Let an AI Agent Operate Through MCP

Enable MCP under Settings → MCP, configure the port and client IP/CIDR allowlist, then connect an AI Agent that supports Streamable HTTP. The Agent must still operate through MCP workspace/project state and four-stage artifacts rather than producing unmanaged output, but it may resume at any stage and does not need to repeat completed work.

For a new, unprocessed project without a local image-to-text model, an Agent can complete translation as follows:

1. Call `mangakitchen.workspace.open` and retain the returned `workspace_id`.
2. Call `mangakitchen.page.detect_masks` to perform OCR and mask generation.
3. Read the page and source-image resources and compare the image with the current regions. For missing text, batch-submit rough boxes and source text through `mangakitchen.page.supplement_regions`. The backend refines glyph masks, removes duplicates, and synchronizes `.str`; the Agent may alternatively supply exact polygons.
4. For existing regions whose `ocrTextRefined` is false, the Agent first corrects `rawSourceText`, then translates and writes `source_text`, translation, and typesetting settings through `mangakitchen.region.update`.
5. Call `mangakitchen.page.compose` to restore the background and generate output.

If a local `imageToText` model is also loaded, the Agent may call `mangakitchen.page.translate`, or orchestrate steps 2–4 with `mangakitchen.page.run_full`. `page.run_full` requires a local image-to-text model; pure Agent translation should use `detect_masks → supplement_regions → region.update → compose`, omitting `supplement_regions` when nothing is missing.

For an existing project, the Agent should inspect workspace, page, and `.str` resources plus their actual artifacts, then call only the required tools. A `maskReady` page with a valid mask can begin with translation or `region.update`; a `translationReady` page with complete translated text can go directly to `compose`; and a completed page can update one region and recompose without rerunning OCR or mask detection. If validation finds missing data, the Agent walks backward using the rules above. In pure Agent mode, falling back to step 3 means the Agent supplies translations through `region.update`; it does not force a local model.

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

Data-location changes take effect after restart. Image-to-text and image-to-image model changes are applied immediately. Changing the MCP switch, port, or allowlist restarts the listener.

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

`MLXVLMRuntime` can load local VLMs whose `model_type` is supported by `mlx-swift-lm`. A suggested starting point is the approximately 3 GB `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`:

1. Download the complete Hugging Face model into a local directory.
2. Copy `Examples/Models/MLXVLMModel/mangakitchen-model.json` into the model directory root.
3. Select that directory in the app. The first load keeps the model container in memory for reuse across pages.

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
  Vision OCR, reading order, Core ML/Metal, masks, restoration, Core Text

MangaKitchenApp
  SwiftUI window, WKWebView, custom URL schemes, JSON bridge, HTML/JavaScript

MangaKitchenApp/MCP
  Toggleable MCP Streamable HTTP adapter and lifecycle in the GUI process
```

See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for architectural decisions and data flow.
See [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md) for the four-stage Swift/JavaScript/MCP contract.

## Known Boundaries

- Model weights are not bundled. Download size, licensing, and distribution policy must be addressed after production models are selected.
- Coarse OCR boxes are now refined with luminance and connected components, while precise balloon interiors, dark/color artwork, narration boxes, and large sound effects can later use segmentation without changing `DialogueRegion` output.
- Metal neighborhood restoration is a fallback. Complex screen tones or text crossing line art should use an inpainting model.
- Qwen Image Edit INT4 still needs roughly 25 GB of inference memory and runs a full diffusion pass per page; low-memory Macs should disable image-to-image restoration.
- Direct Swift Package execution does not yet include App Sandbox security-scoped bookmarks, signing, notarization, or production `.app` packaging.
- Moving source or model directories can invalidate restored paths until security-scoped bookmarks are implemented.
