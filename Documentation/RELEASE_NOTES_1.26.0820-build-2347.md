# MangaKitchen 1.26.0820 (build 2347)

## Highlights

- Enforced strict four-stage artifact ownership. Stage two creates dialogue regions, the binary pixel mask, and the clean background; stage three performs transcription, translation, optional super-resolution, and HTML/CSS typesetting; stage four only saves the confirmed stage-three preview. A later stage no longer reruns or replaces work owned by an earlier stage.
- Added project-level erase-paper colors with pure white, cool white, warm white, ivory, and newsprint presets. The source-page eyedropper is available only in stage one and uses a native eyedropper cursor.
- Improved dialogue cleanup on scanned and JPEG manga. Fixed-color cleanup now removes pale anti-aliased halos outside the original mask, disconnected glyph components within one dialogue region share a stable fill color, and near-white paper samples are normalized without consuming dark balloon outlines.
- Preserved coarse dialogue masks when pixel-level refinement cannot find a plausible glyph component. Automatic dilation now covers a wider two-pixel edge, reducing regions that were detected and transcribed but left unmasked.
- Improved VLM reliability. Empty or rejected per-region responses are retried, large spoken attack text remains eligible as dialogue, and missing UUIDs in a page-context translation response are recovered individually without discarding successful page-level results.
- Added per-region bold toggles, automatic typesetting as the default layout behavior, a clearer “Clear and Restart” stage-one action, and a disabled-by-default second proofreading pass.
- Fixed super-resolution handoff. Cleaned mask pixels are protected from SR re-sharpening, WebKit renders translated text at the real 2×/4× dimensions without oversized viewport allocation, and older 1× final output is invalidated whenever the SR preview changes.
- Added visible startup model-loading progress and a launch-time stable-release check. Update notifications open only the official MangaKitchen GitHub Releases page; the app never downloads or installs updates automatically.
- Updated the MCP contract to 1.2.0. `page.prepare_agent_task` now requires completed stage-two artifacts, `page.submit_agent_result` creates the stage-three preview without exporting, and `page.render` only saves that existing preview.

## Additional Fixes

- Prevented translated output from restoring an older mask or clean background.
- Prevented stale output references after text, style, paper-color, mask, or SR changes.
- Kept HTML/CSS as the single typesetting source for the editor, PNG output, SR output, and layered PSD export.
- Improved persisted-project recovery by validating the actual mask, background, translation preview, output files, and modification order instead of trusting the saved stage label alone.
- Added localized update, paper-color, eyedropper, and workflow messaging for Traditional Chinese, English, Japanese, and Korean.

## Download

- `MangaKitchen-1.26.0820-build-2347.dmg`
- Requires macOS 14 or later
- Bundle identifier: `person.vader.mangakitchen`
- Developer ID signed, Apple notarized, stapled, and accepted by Gatekeeper
- SHA-256: `f30a5767aaefed95d638a8a6a0030edca5c245d595e2806fd9c664f8d0985f63`
