# MangaKitchen 1.26.0822 (build 2139)

## Highlights

- Added a native Swift/Core ML PP-OCRv6 Small OCR runtime. OCR runs inside VLM-selected regions and stores per-model source-text candidates, confidence, line boxes, and reading direction in `ocrResults`; it never replaces VLM `sourceText`, coordinates, bubble geometry, or masks.
- Added full-page **Re-extract text** and **Re-translate** operations, plus a region-level re-extraction and translation action. Re-extraction clears translations that depend on the refreshed source text; re-translation reuses the current source text; region-level processing preserves all stage-two artifacts.
- When no `imageToText` model is available, entering stage two explains manual mode, creates a same-size all-black mask, and enables brush editing. Model-dependent recalculation, extraction, and translation actions remain disabled until a model is loaded.
- Calculation dialogs display an elapsed `MM:SS` timer while queued or running. Region-level work continues to report the current region, total regions, and page progress.
- Added automatic (`AUTO`) erase-paper color estimation while retaining pure-white, cool-white, warm-white, ivory, newsprint, and stage-one eyedropper choices.
- Added persistent global canvas selection color and a default output root. New projects use a sanitized project-name subdirectory below that root; an existing project's explicitly selected output directory is never replaced.
- Added `mcpExtractedSourceText` to MCP and `.str` data so MCP Agent extraction is distinct from local VLM/OCR candidates.
- Updated translation-quality warnings, model-setting tabs, next-step/next-page navigation, and localized interface copy for Traditional Chinese, English, Japanese, and Korean.

## Bundled OCR model and PoC

- `Sources/MangaKitchenApp/Resources/Models/OCR/ppocrv6-small-rec-macos14.mlpackage` is included in the app bundle. It is a fixed-shape Core ML MLProgram converted from the Apache-2.0 PP-OCRv6 Small recognizer, with a `1×3×48×320` input and App model ID `ppocrv6-small-rec`.
- The OCR character list, conversion notes, and complete upstream Apache-2.0 license are included beside the model. See [Documentation/THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the model [README](../Sources/MangaKitchenApp/Resources/Models/OCR/README.md).
- The model weight file is approximately 10.5 MB. Its SHA-256 is `737e0cf4201e3d9af0f94a8ced930d0957387c5f97947468f18da5ed89d11f61`.
- `Experiments/OCRPoC/` contains the PP-OCRv6 quality, Core ML conversion, and ANE/GPU/CPU benchmark scripts. `.artifacts/`, original model weights, and Python caches remain excluded from version control.

## Compatibility

- Requires macOS 14 or later.
- Existing `.str` files and project snapshots can omit the new fields; decoders provide backward-compatible defaults. `AUTO` is an erase-color sentinel and remains distinct from explicit `#FFFFFF`.
- Bundle identifier: `person.vader.mangakitchen`
- Architecture: Apple Silicon `arm64`

## Packaged artifact

- DMG: `MangaKitchen-1.26.0822-build-2139.dmg`
- Size: 39,963,204 bytes
- SHA-256: `1dc78506574508e90158c858357f9d13d70320fbd5382493c6688d7d21b3d2e1`
- The App inside the DMG is signed with `Developer ID Application: CHUN CHUAN CHEN (8QB2QM35YM)`.
- The DMG signature uses the same Developer ID identity. Gatekeeper reports `accepted` with source `Notarized Developer ID`, and `xcrun stapler validate` succeeds.

## Verification

- The packaged App passes `codesign --verify --deep --strict`.
- The packaged DMG passes `codesign --verify --strict`.
- The bundled PP-OCRv6 Core ML package is present in the App resource bundle.
