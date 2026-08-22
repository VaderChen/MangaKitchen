# MangaKitchen 1.26.0823 (build 0323)

## Highlights

- Added a fully native Swift/Core ML PP-OCRv6 Medium OCR path. Medium recognition is now the default, the verified Small recognizer remains available as fallback, and every model keeps its own text, confidence, line boxes, and reading direction in `DialogueRegion.ocrResults`.
- Added the bundled PP-OCRv6 Medium Det text-localization model. It locates rows or vertical columns only inside confirmed dialogue regions during stage three; it never detects speech balloons, scans sound effects outside balloons, or changes stage-two masks.
- Preserved strict workflow ownership: stage two is always speech-balloon detection, original-pixel mask refinement, and clean-background generation. OCR/VLM extraction, translation, SR, typesetting, and output remain separate downstream operations.
- Added a native MLX text-to-text runtime and selectable text-to-text or multimodal translation. Text-to-text is the default and does not require a VLM after OCR has provided source text. Multimodal models remain available for page-aware translation and optional VLM source extraction.
- Reorganized model settings into Multimodal, Text Localization, OCR, Text-to-Text, Super Resolution, and the currently disabled Image-to-Image categories. Qwen3.5-4B 4-bit is the recommended multimodal model; Qwen3-4B 4-bit is the recommended text-only model.

## Model loading and memory

- Text and multimodal models are registered at startup but loaded only when their capability is first used.
- Model ID, capability, canonical path, and resolved symlink path are compared before loading. Concurrent loads for the same capability are serialized, and source extraction plus translation reuse the same container when they select the same model.
- Before a large model is loaded, MangaKitchen checks unified-memory pressure and releases other model runtimes when necessary. Preferred model paths remain registered for later on-demand reload.
- Added a visible model-loading dialog and kept model switching, failure, and reuse details in the in-memory application log.

## Think Mode (Beta) and structured JSON

- Added **Think Mode (Beta)** for supported text and multimodal models. It is disabled by default and uses a short lightweight reasoning pass.
- If reasoning ends without a complete final JSON value, the same loaded model performs a deterministic second pass with thinking disabled. This prevents the reasoning stream from consuming the entire output budget without producing machine-readable output.
- Structured-response decoding now ignores JSON fragments inside reasoning, detects repeating generation tails, and repairs recoverable truncated arrays before decoding.
- The calculation dialog can expand or collapse the reasoning stream. THINK content renders a safe Markdown subset for headings, lists, emphasis, code, quotations, and links; raw HTML is escaped and unsafe link protocols are blocked.
- Reasoning remains transient in memory and is never persisted to a project or copied into the application log.

## Workflow and translation reliability

- Added full-page **Re-extract text** and **Re-translate** actions plus a region-level re-extract-and-translate action. These actions preserve masks, clean backgrounds, and other stage-two artifacts.
- Full-page translation reports the current region and total count. Optional second-pass review is labeled explicitly as proofreading, and incomplete page responses use one bounded recovery pass instead of repeatedly translating successful regions.
- Stage four warns when source text or translation is missing but still lets the user continue. It saves the confirmed stage-three preview without rerunning OCR, translation, SR, or typesetting.
- Automatic Chinese targets now resolve ambiguous `zh` to Traditional Chinese. Simplified Chinese is selected only for explicit Hans/CN/SG targets, and output is normalized to the requested script before persistence.
- Fixed SR preview continuity so stage four retains the stage-three super-resolved background and actual rendered dimensions.

## Interface and diagnostics

- Added an in-memory application log dialog with a black background, white monospaced text, refresh, and clear actions.
- Added live GPU and unified-memory usage to the status bar, followed by image resolution and canvas zoom. High-frequency metrics and THINK updates use a transient bridge path and no longer rebuild the editor DOM or interrupt text selection, menus, dragging, and resizing.
- Added collapsible region cards, region-level source reprocessing, aligned text-color controls, configurable selection color, stage-one-only eyedropper behavior, automatic/common paper-color choices, a default output root, and automatic project-name output subdirectories.
- Added startup and manual GitHub release checks plus visible official repository and Releases URLs under Settings → About. Update checks never download or install software automatically.
- Temporarily hid generated speaker IDs because current character attribution is not reliable enough for user-facing display.

## Compatibility

- Requires macOS 14 or later.
- Apple Silicon `arm64`.
- Bundle identifier: `person.vader.mangakitchen`.
- Existing `.str` files and project snapshots remain backward compatible; new processing and model-choice fields decode with safe defaults.
- Apple Vision OCR is not used. Sound effects remain outside the current dialogue workflow and are reserved for a separate future pipeline.

## Packaged artifact

- DMG: `MangaKitchen-1.26.0823-build-0323.dmg`
- Size: 90,111,677 bytes
- SHA-256: `ff841478f1a96498a8d49260abc4ea57a5213a0c306a6d3bc604d63d7cc074d8`
- App version: `1.26.0823` (`CFBundleVersion` `0323`)
- The App and DMG are signed with `Developer ID Application: CHUN CHUAN CHEN (8QB2QM35YM)`.
- Apple notarization tickets are stapled. Gatekeeper reports both the App inside the DMG and the DMG as `accepted` with source `Notarized Developer ID`.

## Verification

- `swift build` succeeds.
- All 71 Swift tests pass with zero failures.
- Web UI JavaScript passes syntax checks, and the Markdown renderer passes HTML/script escaping checks.
- `codesign --verify --deep --strict` succeeds for the App inside the DMG.
- `codesign --verify --strict` succeeds for the DMG.
- `xcrun stapler validate` succeeds for the DMG.
- The packaged resource bundle contains the PP-OCRv6 Medium recognizer and Medium Det Core ML weights.
