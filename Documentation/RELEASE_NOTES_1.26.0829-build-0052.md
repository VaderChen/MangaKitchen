# MangaKitchen 1.26.0829 (build 0052)

## Highlights

- Restored selectable text-only translation through `MLXTextRuntime` and added `Qwen3-4B-4bit` plus `Qwen3-8B-4bit` to the downloadable translation catalog. Qwen3 4B is the default text-only option; GPT-OSS remains available but is marked as not recommended for multilingual translation.
- Added Gemma 4 E2B, E4B, and 12B 4-bit MLX checkpoints to the Multimodal model catalog.
- Added a Qwen3.5 multimodal processor fallback for Safetensors checkpoints. When `processor_config.json` and `preprocessor_config.json` are absent, the factory derives a compatible Qwen3VLProcessor configuration from `config.json` and its `vision_config`.
- Fixed Gemma 4 E-series KV-shared tail loading. Shared layers no longer declare local K/V projections that are absent from the checkpoint, so Gemma 4 E2B and E4B models pass strict weight loading.
- Reordered the Translation Quality controls to: full-page context, literal draft, translation quality check, and second-pass review.
- Updated the model-loading dialog with a high-visibility orange border, focus outline, spinner, and progress indicator.

## Native DFlash speculative decoding

- Added a vendorized `mlx-swift-lm` fork based on the DFlash-enabled implementation used by LlamaLoader. The App supports native Metal DFlash 1／2 decoding for compatible Qwen3／Qwen3.5 text targets and Qwen3-VL／Qwen3.5-VL multimodal targets without replacing the existing Safetensors／MLX checkpoint or GGUF loading paths.
- Added DFlash switches to the Translation and Multimodal model settings. Compatible Draft models are discovered automatically in the same model root as the selected target; incompatible or unavailable Draft models safely fall back to standard generation.

## GGUF loading

- Added native Swift／MLX GGUF loading with `group64` quantization. Supported Q4_0／Q4_1／Q1_0／Q2_0／Q2_K／Q3_K／Q4_K paths target INT4, while Q8_0／Q5_K／Q6_K target INT8 under the quality profile.
- GGUF loading remains parallel with the existing Safetensors／MLX checkpoint path. Model metadata, vocabulary, merges, special tokens, and processor settings use embedded GGUF data when available, with external files retained as fallback.

## Compatibility

- Requires macOS 14 or later.
- Apple Silicon `arm64` only.
- Bundle identifier: `person.vader.mangakitchen`.
- Existing projects and `.str` files remain compatible; no data migration is required for this release.

## Distribution

- DMG: `MangaKitchen-1.26.0829-build-0052.dmg`
- The App and DMG are signed with the configured Developer ID Application identity.
- Apple notarization was accepted for both the App and DMG, and tickets were stapled successfully.
- The DMG passes `codesign --verify --strict` and `xcrun stapler validate`.
- SHA-256: `da5b7468b28f97cb9feb87a06c9ccb64d987c67899c7447fdde3bc96dcd40e50`
