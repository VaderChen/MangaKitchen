# MangaKitchen 1.26.0824 (build 1739)

## Highlights

- Added a workflow selector for Translation and Colorization. Both workflows use the same project and page list while keeping their steps, progress, previews, reset actions, and outputs independent.
- Added a complete four-step colorization workflow: select pages, edit an anti-dialogue mask, generate a colorized preview, and save the confirmed preview without rerunning inference.
- Added downloadable DDColor Tiny Core ML support. Colorization prefers an existing translated output and falls back to the source page only when no translated output exists.
- Removed text-to-text model selection from the App. GUI translation now always uses a multimodal `imageToText` model, and legacy `textToText` project settings migrate automatically.
- Expanded the MCP workflow contract to `1.3.0`, allowing multimodal Agents to colorize pages with their own Providers and write validated results back into MangaKitchen.

## Colorization workflow

- Added a dedicated `imageColorization` model capability, manifest contract, runtime slot, model download location, and Models-tab entry.
- Added `CoreMLDDColorRuntime`, which runs the 512×512 DDColor Tiny model locally, restores chroma to the original page dimensions, and preserves original-resolution luminance.
- Added an anti-dialogue mask generator. White pixels may be colorized; black pixels protect dialogue areas and user-erased regions from model changes.
- Added colorization mask brush, eraser, undo, redo, recalculation, previous/next navigation, and selected-page reset behavior.
- Stage three now creates and displays the colorized preview immediately. Stage four only writes that existing preview to the `-colorized.png` output.
- Color-range and colorization-mode settings remain stored for forward compatibility but are disabled because DDColor Tiny does not consume those parameters.

## MCP API 1.3.0

- Added `mangakitchen.page.colorize` for local DDColor inference.
- Added `mangakitchen.page.prepare_colorization_task` to return the actual colorization input image and anti-dialogue mask in one Agent work package.
- Added `mangakitchen.page.submit_colorization_result` to accept a complete PNG, JPEG, HEIC, TIFF, or WebP page from an Agent.
- Agent colorization results are limited to 20 MiB after Base64 decoding, must exactly match the input pixel dimensions, are normalized to PNG, and have the protection mask reapplied before becoming the stage-three preview.
- Added `mangakitchen.page.render_colorization`, `mangakitchen.page.reset_colorization`, independent colorization resources, page inspection fields, progress, errors, and optimistic-concurrency revisions.
- Translation work packages now explicitly require a multimodal Agent and continue to preserve App-generated regions, masks, and clean backgrounds.

## Models and interface

- Added a downloadable DDColor Tiny model sourced from `mlboydaisuke/DDColor-Tiny-CoreML` under Apache-2.0. The model remains optional and is not bundled in the App or repository.
- Added reusable Core ML package download handling and generated manifests for both super-resolution and colorization model contracts.
- Added horizontally pannable model tabs with previous/next icon buttons so most tabs remain visible without exposing a scrollbar.
- Added workflow-specific Project Settings while preserving the shared Project Settings heading and collapsible card behavior.
- Improved translation safety so speaker labels, role descriptions, and delivery directions remain metadata instead of leaking into rendered dialogue.
- Added large-model memory preparation, low-effort reasoning for supported Qwen models, leading alignment defaults, and super-resolution preview continuity.

## Compatibility

- Requires macOS 14 or later.
- Apple Silicon `arm64`.
- Bundle identifier: `person.vader.mangakitchen`.
- Existing projects and `.str` files remain compatible. Missing colorization fields use safe defaults, and legacy text-to-text translation settings migrate to multimodal `imageToText`.
- Translation and colorization outputs remain separate; resetting colorization does not remove translation regions, masks, previews, or final output.

## Packaged artifact

- DMG: `MangaKitchen-1.26.0824-build-1739.dmg`
- Size: 90,780,343 bytes
- SHA-256: `6422ed6b4b7571b0cd0f10674b301ba70a5d8105da24333c2f534f364f33553c`
- App version: `1.26.0824` (`CFBundleVersion` `1739`)
- The App and DMG are signed with `Developer ID Application: CHUN CHUAN CHEN (8QB2QM35YM)`.
- Apple notarization tickets are stapled. Gatekeeper reports both the App and DMG as `accepted` with source `Notarized Developer ID`.

## Verification

- `swift build` succeeds.
- Web UI JavaScript files pass `node --check`.
- `git diff --check` succeeds.
- `codesign --verify --deep --strict` succeeds for the App.
- `codesign --verify --strict` succeeds for the DMG.
- Gatekeeper accepts both the App and DMG.
- `xcrun stapler validate` succeeds for the DMG.
