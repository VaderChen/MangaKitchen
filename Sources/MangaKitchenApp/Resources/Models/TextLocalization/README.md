# PP-OCRv6 Medium Det Core ML model

`ppocrv6-medium-det-736x480-macos14.mlpackage` is a fixed-input Core ML
MLProgram converted from the official
[PP-OCRv6 Medium detector](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det_onnx).
MangaKitchen uses it through the native Swift `PPOCRTextDetectionRuntime`; no
Python runtime or Apple Vision OCR is required.

- Upstream project: PaddlePaddle / PaddleOCR
- Upstream license: Apache License 2.0
- Input: BGR NCHW `1×3×736×480`
- Output: probability map `1×1×736×480`
- Core ML precision: FP16 MLProgram, macOS 14+
- App model ID: `ppocrv6-medium-det`
- DB thresholds: pixel `0.2`, box `0.45`, unclip ratio `1.4`
- Compute plan verified on M4 Pro: `224/224` operations on Apple Neural Engine
- License copy: [LICENSE-PP-OCRv6-Medium-Det.txt](LICENSE-PP-OCRv6-Medium-Det.txt)

The weight file at `Data/com.apple.CoreML/weights/weight.bin` is approximately
30 MB. SHA-256:
`60cc437da1143ead9a9f26afca19af287be01300fb50434779c04858d97210dc`.

The detector only returns independent text-line coordinates and does not perform
OCR or translation. It is intentionally isolated from stage-two mask generation:
stage two always detects speech balloons and refines their original-image pixels
without invoking Medium Det or a VLM. Text-localization experiments therefore
cannot alter dialogue-region geometry or masks.
