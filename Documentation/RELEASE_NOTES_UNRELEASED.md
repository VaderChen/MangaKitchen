# MangaKitchen Development Release Notes

The current packaged build is documented in [MangaKitchen 1.26.0829 (build 0052)](RELEASE_NOTES_1.26.0829-build-0052.md).

Use this file for changes made after build 0052 and before the next release artifact is produced.

## Model Downloads

- Models with a compatible DFlash Draft now download the Draft automatically into `DFlashDraftModel` beside the main model.
- Draft downloads are optional and isolated from the main model download; missing or unavailable Draft repositories do not block model installation.
- Existing installed models can acquire a missing compatible Draft without downloading the main model again.
