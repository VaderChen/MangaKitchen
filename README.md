# MangaKitchen

[Traditional Chinese](README.zh-TW.md) | English | [Japanese](README.ja.md) | [Korean](README.ko.md)

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
- Global Settings dialog with General, Advanced, Models, MCP, and About tabs for language, color scheme, CPU/GPU image compositing, data location, multimodal/OCR/colorization/SR model roles, MCP port, and IP/CIDR allowlist.
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
- GUI translation uses the selected text-to-text or multimodal model. OCR can extract per-region source text for the text-only path, while VLM transcription and page context remain available when the multimodal path is selected.
- Stage-three controls can explicitly re-extract all region source text, retranslate using the existing source text, or re-extract and translate one selected region; these operations keep stage-two masks and clean backgrounds intact. Calculation dialogs show an elapsed `MM:SS` timer while work is waiting or running.
- Accepted dialogue regions use the dialogue BBOX as their search boundary, then are refined into pixel glyph masks from original-image pixels and shrink to the unexpanded glyph extents. Automatic layout direction prefers the measured glyph arrangement. Each candidate is isolated: if OCR or translation fails for one region, that region is preserved and the remaining regions continue; only cancellation stops the whole job.
- Page-context multimodal prompts and strict JSON response parsing for local translation models.
- Direct loading of local Hugging Face MLX multimodal model directories through `mlx-swift-lm` on Apple Silicon/Metal.
- Multimodal models are registered at startup but loaded only when first used. Canonical model identity prevents duplicate loads, concurrent requests for one capability are serialized, and high unified-memory pressure releases other runtimes before a large model is loaded.
- **Think Mode (Beta)** is optional and off by default. It streams a short reasoning pass into a safe Markdown view, keeps reasoning out of persistent logs, and uses the same loaded model for a deterministic non-thinking JSON finalization pass if reasoning did not produce a complete final value.
- Model-manifest loading for `.mlmodelc`, `.mlmodel`, and `.mlpackage`, with Core ML configured for Metal GPU execution.
- Dialogue masks use one or more pixel-level shapes to cover the original letters, clip to speech-area boundaries, and accept additive/eraser brush strokes; CPU or Metal GPU repair is available without an image model.
- HTML/CSS is the single source of truth for translation layout, including horizontal/vertical writing, fixed or automatic font sizing, per-region bold toggles, dragging, and resizing. WebKit renders the stage-three preview at the real SR pixel size, and stage four saves that exact preview without rebuilding it.
- Optional 2×/4× super-resolution preserves cleaned mask pixels, rerenders translated text at the resolved dimensions, and invalidates older 1× output so the final PNG and PSD cannot silently fall back to the pre-SR image.
- A separate four-step colorization workflow uses an anti-dialogue mask and downloadable DDColor Tiny Core ML model. It prefers an exported translated page as input and otherwise falls back to the source page; colorization state, preview, and output remain independent from translation. Color-range and colorization-mode cards are currently disabled because DDColor Tiny does not consume those settings.
- Source and output images are exposed to the Web UI through restricted custom URL schemes rather than arbitrary file access.
- Project indexes and states persist as versioned JSON. The previous version is kept as `.bak` before each write and validated on restore.
- Advanced settings can store a default output root. New projects without an explicit output folder automatically use a project-name subfolder under it, while an existing project's chosen output folder remains unchanged.
- Optional macOS 26 Swift/MLX Qwen Image Edit worker, using the mask both as model conditioning and as the final composition boundary.
- Optional standard MCP Streamable HTTP server with translation and colorization tools, workspace/image resources, cancellation, and progress notifications. A multimodal Agent can receive the colorization input plus mask, colorize with its own Provider, and write the validated full-page result back into the App preview.
- When MCP is enabled, the app remains in the macOS menu bar and can reopen the main window after it is closed.
- An in-memory application log can be opened from the toolbar and cleared at any time. The bottom status bar shows live GPU/unified-memory use, image resolution, and canvas zoom through a transient update path that does not rebuild or interrupt editor controls.
- On-demand model loading is shown in a progress dialog. A separate launch-time check reports newer stable GitHub Releases, while Settings → About visibly lists the official repository and Releases URLs and provides a manual **Check for Updates** action. External navigation is restricted to those official GitHub paths; MangaKitchen never downloads or installs an update automatically.

## Translation Workflow and MCP Usage

MangaKitchen supports local GUI translation and multimodal-Agent proofreading through MCP. They change who performs translation inference and orchestration, but share the same project data and translation artifacts. Every job begins with a source-directory project; pages, masks, translations, typesetting settings, glossary entries, and output states remain scoped to that project. Colorization is a separate workflow with independent state and output.

Both translation modes follow these four steps:

1. **Project and pages**: choose a source directory, scan images recursively, and build a multi-selectable, batch-processable page list.
2. **Text, masks, and clean background**: locate dialogue BBOX candidates and bubble shapes with the bundled Core ML segmentation model, refine the original-image pixels into glyph masks, apply manual strokes, and produce the confirmed text-free background.
3. **OCR, translation, and typesetting preview**: the GUI extracts source text with bundled OCR or the selected VLM path, then translates with the selected multimodal model. Optional second-pass review and semantic QA use that same translation path. MCP instead gives a multimodal Agent an App-generated page bundle. The App preserves stage-two artifacts, optionally applies SR, and renders the complete HTML/CSS translation preview.
4. **Output**: copy the confirmed stage-three preview to the project's output directory. This stage does not rerun detection, masking, cleanup, transcription, translation, SR, or typesetting.

The four steps define resumable states, artifacts, and dependencies; they are not a mandatory checklist that restarts at step 1 every time. Both the GUI and MCP should inspect the App-provided page state and work package first, then begin at any step whose prerequisites already exist. Existing masks can go directly to translation, existing translations can go directly to typesetting or composition, and a single region can be edited without reprocessing the page. Completed region detection, masks, translations, and manual edits are not overwritten unless a user or Agent explicitly requests that stage again.

Before starting at any stage, each page must be validated against its actual artifacts rather than trusting the state label alone. If the requested stage lacks a prerequisite, walk backward one stage at a time until reaching the nearest work that must be regenerated:

- Before step 4, validate that the stage-three translation preview exists and is newer than any prior output. A missing or stale preview falls back to step 3; missing regions, mask, or clean background falls back again to step 2.
- Before step 3, validate the source page, text regions, source text supplied by OCR, VLM, Agent, or the user, and the mask. Incomplete data falls back to step 2.
- Before step 2, validate that the source image still exists and the project's page index is valid. Missing data falls back to step 1 and a rescan.
- Fallback regenerates only missing or invalid artifacts. Valid prerequisites remain untouched, and different pages may resume from different stages.

### Separate Colorization Workflow

Colorization has its own four steps: select pages and prefer an existing translated output, build and edit the anti-dialogue mask, create a preview with downloaded DDColor Tiny or an external multimodal Agent, then save that existing preview as final output. Its mask uses white for pixels that may be colorized and black for protected dialogue or manually erased areas. Colorization requires the App-confirmed dialogue regions and mask data first, but its progress, preview, reset action, and output do not overwrite translation state.

### Mode A: Download Multimodal Models and Work Fully Offline

Download a multimodal translation model and, when needed, DDColor Tiny under Settings → Models. Region detection, source extraction, translation, background restoration, composition, and local colorization run on the Mac. Once model files have been downloaded, comic content does not need to be sent to an external AI service.

- Translation always uses `imageToText`; PP-OCR **Re-extract text** can run without the VLM, but translation, review, and semantic QA require the multimodal model. The app never falls back to Apple Vision OCR; an MCP Agent can provide source text and translations instead. Sound effects remain outside the current workflow.
- In the translation step, “Re-extract text” refreshes source text and clears dependent translations, while “Re-translate” reuses the current source text. A region-level refresh updates only the selected region and then rerenders the page preview.
- Background restoration belongs to step 2 and uses the configured Metal GPU neighborhood repair or CPU dominant-color speech-area repair; GPU failures automatically fall back to CPU. Later steps consume this clean background and never regenerate it.
- The GUI can run each step separately or use “Process Selected/All.” One-click processing still executes steps 2–4 in order and preserves their intermediate data.
- Local colorization loads the downloaded `imageColorization` model only when step three runs. It creates a preview immediately; step four only copies that preview to output.
- Every result is written back to the project and `.str`, so users can correct any stage and rerun only the downstream steps.

### Mode B: Proofread Through MCP (Recommended)

> **Recommended flow: finish stage two locally, then use MCP for proofreading.** MCP preserves the App-generated regions, masks, and clean background instead of rebuilding or overwriting them. A later stage never runs an earlier stage implicitly.

Enable MCP under Settings → MCP, configure the port and client IP/CIDR allowlist, then connect an AI Agent that supports Streamable HTTP. MCP provides one page work package instead of asking the Agent to decompose, clear, or rebuild the four stages.

1. In the GUI, open the project and complete stage two (regions, pixel mask, and clean background) for the requested pages.
2. Enable MCP under Settings → MCP and connect a multimodal AI Agent that supports Streamable HTTP.
3. The Agent calls `mangakitchen.workspace.open` to obtain `workspace_id`, then calls `mangakitchen.page.prepare_agent_task` for each requested page. The tool only packages completed stage-two data; if the mask or clean background is missing, it stops and asks the user to finish stage two in the App.
4. The Agent processes each existing region: treat non-empty `sourceText` and `translatedText` as drafts to proofread against the image, fill or correct empty or inaccurate text, and adjust HTML typesetting bounds, anchor, size, weight, and writing direction. It must not add, remove, merge, or modify regions or masks.
5. Call `mangakitchen.page.submit_agent_result` once with all proofread text, translations, and typesetting results. This completes the stage-three translation/typesetting preview without writing final output. Only when the user requests export, call `mangakitchen.page.render`; stage four copies the completed preview to the output directory without rerunning masking, background cleanup, translation, or typesetting.

Colorization can also be fully Agent-owned after the anti-dialogue mask is completed in the App: call `mangakitchen.page.prepare_colorization_task` to receive the actual input image and mask together, then write the full-page result back with `mangakitchen.page.submit_colorization_result`. The App enforces the 20 MiB decoded-result limit, validates exact pixel dimensions, normalizes PNG output, and reapplies the protection mask; call `mangakitchen.page.render_colorization` only when the user requests export.

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

The GUI always starts. When `--mcp` is omitted, the saved Settings value is used; `--mcp=on|off` overrides it for the current launch. The listener binds to `0.0.0.0`, uses port `12080` by default, and only accepts the actual source IP/CIDR entries in the allowlist. The default allowlist contains only `127.0.0.1`. The local MCP URL is `http://127.0.0.1:12080/mcp`; `--mcp-port=<port>` overrides the port for the current launch. Closing the main window does not terminate the app, which can be reopened from the menu bar.

Data-location changes take effect after restart. Image-to-text, image-colorization, and super-resolution model changes are applied immediately. Changing the MCP switch, port, or allowlist restarts the listener.

### SwiftPM and Metal build troubleshooting

MLX depends on its bundled Metal resource (`default.metallib`). The packaging script builds the application-specific `mlx.metallib` once and persists it under `Artifacts/MLXMetal/<configuration>/`, outside SwiftPM's `.build` cache; `--clean` therefore does not rebuild it unless the MLX shader sources change. If `swift test` stops with `Failed to load the default metallib`, the test has failed while initializing MLX and has not reached the MangaKitchen GGUF loader. This is not a MangaKitchen or GGUF kernel error.

Start with a clean SwiftPM dependency and build cache:

```bash
swift package clean
swift package resolve
swift test
```

Confirm that the Apple Metal command-line tools are available:

```bash
xcrun --find metal
xcrun --find metallib
```

Both commands should print paths inside an Apple Metal toolchain. The supported environment is Apple Silicon running macOS 14 or later with a complete Xcode Command Line Tools／Metal installation. If the commands resolve but `default.metallib` is still missing, repair or reinstall the Command Line Tools, reopen the terminal, and repeat the clean build. A successful `swift build` confirms compilation; the MLX runtime tests additionally require the Metal resource to be present at test execution time.

Project indexes, project states, and intermediate files are stored by default under:

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Imported/<import-uuid>/
  Artifacts/<page-uuid>/
```

Each `.str` is stored beside its source image: for example, `ComicTest/001.webp` maps to `ComicTest/001.str`. The selected output folder contains only final PNG files. Legacy `.str` files are copied beside their source images and retained at their old locations.

A legacy `Workspace/workspace.json` is migrated into the first project on initial launch. The original file is retained.

## Model Format

Core ML and external-runtime model directories use `mangakitchen-model.json`. A complete Hugging Face MLX directory with `config.json`, tokenizer files, and Safetensors can be inferred without a manifest; adding one remains supported for explicit metadata and generation settings. Examples are available at:

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

Manifest feature names must match the actual Core ML model. The current Core ML adapter supports:

- Image-to-text: an image feature, an optional string prompt feature, and a string output feature.
- Image-to-image: an image feature, optional mask/prompt features, and an image output feature.

Colorization uses a dedicated `ImageColorizing` adapter rather than the generic image-to-image contract. The managed catalog downloads Apache-2.0 [`mlboydaisuke/DDColor-Tiny-CoreML`](https://huggingface.co/mlboydaisuke/DDColor-Tiny-CoreML), builds an `imageColorization` manifest for `DDColor_Tiny.mlpackage`, and expects the `image` input plus `ab_channels` output.

The Core ML manifest is a generic adapter for models packaged as one prediction. Models such as Qwen-VL that require tokenizers and autoregressive decoding use a dedicated MLX adapter. Diffusion models with sampler loops likewise require a dedicated `ImageToImageGenerating` adapter; changing only the Core ML feature names is insufficient. The core pipeline does not need to change.

The App exposes `MLXTextRuntime` for text-only translation and `MLXVLMRuntime` for local multimodal translation models whose `model_type` is supported by `mlx-swift-lm`. The managed catalog recommends `mlx-community/Qwen3-4B-4bit` for text-only translation and also provides the larger `Qwen3-8B-4bit`. GPT-OSS remains available as an optional model, but is marked as not recommended for multilingual translation because its quality can be inconsistent. The Multimodal catalog also provides Gemma 4 E2B, E4B, and 12B 4-bit MLX checkpoints:

1. Download the complete Hugging Face model into a local directory.
2. Select that directory in the app. The path is registered immediately; the model container loads on first use and is then reused across pages until memory pressure requires release.
3. Add `Examples/Models/MLXVLMModel/mangakitchen-model.json` only when explicit display or generation overrides are needed.

For text-only translation, choose the Qwen3 4B or 8B entry in Settings → Models → Translation. These models receive OCR text without the page image; multimodal translation remains available through the separate multimodal model selection.

### DFlash speculative decoding

The Translation and Multimodal model settings can enable DFlash for compatible Qwen3／Qwen3.5 targets. The app automatically discovers the Draft in the same model root as the selected target, so no separate Draft path is stored. The native Swift／MLX implementation runs on the same Metal runtime as the target model; it does not replace Safetensors／MLX checkpoint or GGUF loading. Qwen3-VL and Qwen3.5-VL perform a vision-aware prefill before entering the same speculative decoding loop; other VLM architectures safely fall back to standard generation. If the draft is missing, incompatible, invalid, or encounters an unsupported generation configuration, the App logs the reason and falls back to standard generation. The Draft weights are not bundled with the App.

The `mlx-swift-lm` factory selects architecture from `config.json`, so a single safetensors file is not enough. Keep the tokenizer, chat template, and config files together. Other multimodal models should also retain their processor configuration; for Qwen3.5 checkpoints with `vision_config`, the factory derives a compatible Qwen3VLProcessor configuration when `processor_config.json` and `preprocessor_config.json` are absent.

### GGUF Weights

`MLXTextRuntime` and `MLXVLMRuntime` support loading `.gguf` weights directly from a model directory without converting them to Safetensors first. The production App uses the `group64` and `quality` profile by default to build MLX `wq/scales/biases` directly from GGUF raw blocks: `Q4_0`／`Q4_1`／`Q1_0`／`Q2_0`／`Q2_K`／`Q3_K`／`Q4_K` target `INT4`, while `Q8_0`／`Q5_K`／`Q6_K` target `INT8`. Developers can use the `speed` profile to requantize Q5_K／Q6_K to `INT4`, reducing decode memory bandwidth at the possible cost of quality; `quality` remains the default when no profile is specified. All GGUF F32／F16 compute weights are converted to BF16, except Qwen3.5 `blk.N.ssm_a` (`linear_attn.A_log`), which remains F32; `mmproj` uses the same group size. Other GGUF quantization types not listed here, including `Q8_K`, are explicitly reported as unsupported during inspection and before loading. The llama.cpp bridge remains only under `Tools/GGUFBackendPOC` for parser comparison and is not a production App loading dependency.

The GGUF loader first uses metadata embedded in the primary `.gguf` to build the model configuration and tokenizer; external `config.json`, `tokenizer.json`, and `tokenizer_config.json` files are fallback sources only. A text-only model with complete GGUF metadata can therefore consist of only the `.gguf` file. A multimodal model must still provide its matching `mmproj-*.gguf`; if processor settings are absent from the directory, basic settings are built from `mmproj` metadata. The external tokenizer fallback requires at least `tokenizer.json`; `tokenizer_config.json` can be combined with embedded or external tokenizer data.

`FP8`, including the `F8_E4M3`／`F8_E5M2` variants, is still requantized to `INT8`. General GGUF `F16`／`F32` compute weights follow the rules above and are converted to BF16, with only `blk.N.ssm_a` remaining F32. The standard llama.cpp GGUF type table currently has no independent FP8 tensor type, so the Swift loader does not pretend that an unknown GGUF type is FP8. `GGUFStoragePolicy.targetStorageType(for:)` fixes the target strategy for the `quality` profile, while `targetStorageType(for:profile:)` can query the speed profile. Actual FP8 decoding can be added once an upstream parser or another tensor format provides an explicit FP8 encoding.

```bash
swift run GGUFSmoke --directory /path/to/Qwen3.8-27B-GGUF \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128 \
  --gguf-group-size 64 --gguf-profile quality
swift run GGUFSmoke --directory /path/to/Qwen3.8-27B-MLX-4bit \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128
```

`GGUFSmoke` and `Tools/GGUFBackendPOC` are intended only for developer validation of format handling, numerical behavior, and performance. `GGUFSmoke` accepts `--gguf-profile quality|speed` to switch the Q5_K／Q6_K target between INT8 and INT4; `quality` is the production App default, while `speed` is intended for comparison only after quality has been validated. The benchmark and fixture results are not read by the App and do not determine runtime model selection or quality thresholds; production loading relies only on the actual checks in `GGUFStoragePolicy` and the loader. To compare formats, run the commands above separately with the same hardware and parameters, and treat the results as measurements for that run rather than fixed product values.

Multimodal GGUF models require more than the primary model file. The model directory must also retain `config.json`, the Hugging Face tokenizer／chat template, and the `mmproj-*.gguf` vision projection file paired with the primary model; without `mmproj`, the loader does not masquerade as a text-only model. The model downloader first checks whether the repository contains the requested `mmproj`, then downloads only the primary GGUF, that `mmproj`, and the required Qwen base configuration files. It does not download other Q4／Q8 or IQ GGUF files.

Specify the weight files in `mangakitchen-model.json`:

```json
{
  "schemaVersion": 1,
  "id": "local-llama-q4",
  "displayName": "Local Llama Q4",
  "capability": "imageToText",
  "backend": "mlxSwift",
  "weightsFile": "model-q4_0.gguf",
  "weightsFormat": "gguf",
  "mmprojFile": "mmproj-F16.gguf"
}
```

The model catalog retains two Qwen3.8 27B options: the original [`lmstudio-community/Qwen3.8-27B-MLX-4bit`](https://huggingface.co/lmstudio-community/Qwen3.8-27B-MLX-4bit) checkpoint and the new [`unsloth/Qwen3.8-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) `Qwen3.8-27B-Q4_0.gguf`. The GGUF option uses the `mmproj-F16.gguf` from the same repository, while the tokenizer and model configuration are provided by [`Qwen/Qwen3.8-27B`](https://huggingface.co/Qwen/Qwen3.8-27B). If a directory contains both GGUF and Safetensors checkpoints, the existing `LLMModelFactory`／`VLMModelFactory` checkpoint loading path remains in use unless `weightsFormat: "gguf"` or a GGUF `weightsFile` is explicitly specified.

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
  Enclosure detection, OCR/VLM transcription, Core ML/MLX translation, colorization, SR, masks, restoration

MangaKitchenApp
  SwiftUI window, WKWebView, custom URL schemes, JSON bridge, HTML/JavaScript layout and PNG output

MangaKitchenApp/MCP
  Toggleable MCP Streamable HTTP adapter and lifecycle in the GUI process
```

See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for architectural decisions and data flow.
See [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md) for the versioned translation/colorization Swift, JavaScript, and MCP contract.
See [the build 0052 release notes](Documentation/RELEASE_NOTES_1.26.0829-build-0052.md) for the latest packaged changes, Developer ID signature, notarization status, and verified download checksum.
See [the current development release notes](Documentation/RELEASE_NOTES_UNRELEASED.md) for changes after the latest package.

## Known Boundaries

- The bundled `manga109-segmentation-bubble`, PP-OCRv6 Medium Core ML default, and PP-OCRv6 Small fallback models are derived from Apache-2.0 source models. Original image-to-text, downloadable DDColor Tiny, super-resolution, and experimental image-edit weights are not bundled; their size, licensing, and distribution policy remain separate concerns. DDColor Tiny is Apache-2.0, and the converted OCR `.mlpackage` packages, character lists, and adjacent notices are included in this repository.
- Dialogue BBOX values are refined with luminance and connected components from original-image pixels; segmentation shapes clip the search area and the mask uses pixel-layer dilation. Dark/color artwork may require manual mask correction in the App. The standard Agent work package cannot alter regions or masks, and non-dialogue sound effects remain outside the translation workflow.
- Fixed-paper-color and Metal neighborhood cleanup work best in dialogue areas with a stable paper tone. Complex screen tones or text crossing line art may still need mask correction and manual retouching.
- The optional Qwen Image Edit worker remains experimental, needs roughly 25 GB of inference memory, and is not part of the default translation cleanup path.
- Direct Swift Package execution does not yet include App Sandbox security-scoped bookmarks, signing, notarization, or production `.app` packaging.
- Moving source or model directories can invalidate restored paths until security-scoped bookmarks are implemented.
