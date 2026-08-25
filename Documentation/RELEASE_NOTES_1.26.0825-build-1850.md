# MangaKitchen 1.26.0825 (build 1850)

## Highlights

- Second-pass proofreading now starts only after the first-pass translation has been saved and previewed. Cancelling proofreading no longer discards completed translations.
- Proofreading is now a single page-wide translation revision that normalizes names, glossary terms, numbers, negation, tone, and length without rerunning OCR, text extraction, or per-region translation.
- Added a dedicated application layer and a process-wide runtime composition root so the GUI and MCP share the same workflow rules and inference resources.
- Split large AppStore, WebKit bridge, and MCP coordination responsibilities to reduce duplicated state and contract assembly.

## Translation and proofreading

- When second-pass proofreading is enabled, the first-pass draft is written to the `.str` file and project snapshot, then rendered as a typeset preview before proofreading begins.
- Proofreading treats the existing `sourceText` as authoritative and only improves page-wide translation consistency and quality.
- Cancelling proofreading, or a proofreading failure, preserves the committed first-pass draft and preview.
- Single-region re-extraction does not trigger second-pass proofreading, keeping local OCR correction separate from page-wide translation revision.

## Application and MCP architecture

- Added the `MangaKitchenApplication` target to centralize artifact completeness, page progress, and output-directory safety rules.
- Added `MangaKitchenRuntimeEnvironment` so the GUI and MCP share Metal, model runtimes, the typesetter, workflow pipelines, and the artifact root.
- Moved editing history, batch workflow execution, and model lifecycle management into dedicated coordinators.
- Extracted WebKit command routing, parameter decoding, and native panel operations from `HybridBridgeController`, with all commands dispatched through an explicit allowlist.
- Separated MCP tool names, workspace indexing, and page contract presentation so the workflow actor no longer owns transport, storage, and JSON contract assembly at the same time.

## OCR experimentation

- Consolidated the OCR PoC under `Experiments/OCRPoC/`.
- Preserved PP-OCRv6 quality evaluation, Core ML conversion, and Auto/ANE/GPU/CPU benchmarking.
- Apple Vision is outside the scope of this validation workflow.

## Compatibility

- Requires macOS 14 or later.
- Apple Silicon `arm64` only.
- Bundle identifier: `person.vader.mangakitchen`.
- Existing projects and `.str` files remain compatible; no data migration is required for this release.
