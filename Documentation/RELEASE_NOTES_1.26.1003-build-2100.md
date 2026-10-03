# MangaKitchen 1.26.1003 (build 2100)

This release reduces memory allocation and copying in image processing and output, improves cancellation and recovery, and updates the documentation and automatic-translation GIF. The UI, operating steps, project schema, and model defaults are unchanged by the optimization work.

## Performance and Memory

- PSD export streams layer channels in bounded chunks instead of constructing multiple full-file buffers. GUI/MCP preview saving and external-worker result copying share a 1 MiB streaming buffer with atomic replacement.
- CPU text removal reuses component traversal storage, appends grouped pixels into reserved capacity, and skips unused sampling-exclusion dilation for fixed-color fills.
- Pixel-mask refinement emits ordered row runs directly. Core ML bubble postprocessing caches tensor metadata and storage access while preserving strided tensor behavior.
- Batch snapshots share a page-name index. Generation avoids duplicate token lookups, and translation QA reuses its number expression.

Measured on the same Apple M4 / 16 GiB Mac, using the workloads documented in the linked reports:

| Workload | Before | After | Observation |
| --- | --- | --- | --- |
| PSD export, 2048 × 3072, six layers | 0.887 s; 806.5 MiB peak RSS | 0.392 s; 176.4 MiB peak RSS | 55.8% less time; 78.1% less peak RSS |
| Copy a 176 MB output file | 174.8 MiB peak RSS | 7.9 MiB peak RSS | 95.5% less peak RSS |
| Pixel-mask refinement | 219.8 MiB peak RSS | 129.6 MiB peak RSS | 41.0% less peak RSS |

Five function benchmark outputs and the PSD output match the baseline byte for byte. The three-process function medians show 18.4% less time for automatic-color cleanup, 75.2% for fixed-color cleanup, 11.3% for mask refinement, and 38.1% for bubble inference/postprocessing. These are specific workloads, not whole-app or language-model throughput claims.

See the [output performance audit](PERFORMANCE_AUDIT_2026-10-03.md) and [function-level report](FUNCTION_OPTIMIZATION_2026-10-03.md) for inputs, comparison revisions, reproducible commands, hashes, and limitations.

## Reliability Since Build 0052

- Project and `.str` writes validate recoverable backups and preserve newer schema versions. Atomic image/output replacement keeps the previous destination intact on failure.
- GUI and MCP rescans preserve exclusions, manual names, and page order. Output paths share symlink-aware validation.
- Model downloads validate complete installations, pin repository revisions, check resumed ranges, and recover the previous installation if replacement fails. Optional attachments do not block a valid main model.
- Batch cancellation, model load invalidation, MCP workspace serialization, WebKit rendering cancellation, subprocess diagnostics, and HTTP body limits now have additional regression coverage.

The [reliability audit](RELIABILITY_AUDIT_2026-09-21.md) records the tested boundaries, including the remaining limits of GUI/MCP concurrency and fault injection.

## Model Downloads and Compatibility

- Compatible DFlash Drafts download automatically into `DFlashDraftModel` beside the main model. Existing models can acquire a missing Draft without reinstalling their main weights; a missing or unavailable Draft does not prevent main-model installation.
- LFM compatibility fixes cover expanded-vocabulary image-token lookup, nested processor configuration, non-tiling image sizing, and image boundary markers. Invalid image/token counts now throw errors instead of terminating the app.
- Text and multimodal generation preserve cancellation when the output stream ends without another event, avoiding a successful return of a partial canceled translation.
- LFM2.5-VL-3B and Granite 4.2 3B did not meet the current translation-quality requirements in local evaluation. Neither was added to the download catalog, and the Qwen defaults remain unchanged. See the [research](MODEL_RESEARCH_2026-10-03.md), [evaluation results](MODEL_EVALUATION_2026-10-03.md), and [opt-in harness](../Tools/ModelEvaluation/README.md).

## Documentation and Licensing

- The four localized README files now show the automatic translation/typesetting/export GIF and explain both text-only and multimodal translation.
- README licensing descriptions now match the repository's existing [source-available, no-commercial-sales license v1.1](../LICENSE.md). This corrects stale GPL references; it does not introduce another license change.
- The packaged app retains the complete project license and translations, commercial licensing information, and upstream dependency licenses/notices under `Contents/Resources/Licenses`. The DMG also exposes a `Licenses` folder. Bundled OCR model notices remain alongside the model resources.

## Validation and Compatibility

- Full regression suite: **181 tests, 178 passed, 3 skipped, 0 failures**. The skipped tests require optional local GGUF weights or an explicitly enabled model evaluation; they are not counted as passes.
- Added PSD byte compatibility, atomic copy cancellation/error, LFM processor, strided tensor, and batch-snapshot regression coverage.
- Requires macOS 14 or later on Apple Silicon (`arm64`). Bundle identifier: `person.vader.mangakitchen`.
- Existing projects and `.str` files remain compatible; no data migration is required.
- Large translation/colorization/SR weights and the optional Qwen Image Edit worker are not bundled.

## Distribution

- DMG: [`MangaKitchen-1.26.1003-build-2100.dmg`](https://github.com/VaderChen/MangaKitchen/releases/download/v1.26.1003-build-2100/MangaKitchen-1.26.1003-build-2100.dmg) (90,949,151 bytes).
- The app and DMG are signed with Developer ID Application: CHUN CHUAN CHEN (`8QB2QM35YM`). Apple notarization was accepted for both, and their tickets were stapled and validated.
- The DMG passes signature, integrity, and Gatekeeper checks. The app mounted from that DMG also passes deep signature verification, ticket validation, and Gatekeeper assessment.
- Packaged binary identity matches the Release build; all 13 Web UI resources match the source tree. Version, architecture, and license contents were verified from the read-only mounted DMG.
- SHA-256: `34c25f43dc0738693a022d725e9084ed282f844f2926e28774f0097d013a9403`. A `SHA256SUMS.txt` asset accompanies the download.
