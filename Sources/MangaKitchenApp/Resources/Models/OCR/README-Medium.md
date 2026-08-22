# PP-OCRv6 Medium Core ML 模型

`ppocrv6-medium-rec-macos14.mlpackage` 是由官方
[PP-OCRv6 Medium recognizer Paddle model](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec)
經 Paddle2ONNX 與 `onnx2coreml` 轉換而成的固定輸入 Core ML MLProgram，供
macOS 14 以上的原生 OCR runtime 使用。

- 原始模型：PaddlePaddle PP-OCRv6 Medium recognizer
- 原始模型授權：Apache License 2.0
- 轉換輸入尺寸：`1×3×48×320`
- 輸出尺寸：`1×40×18,710`
- Core ML 精度：FP16
- App 模型 ID：`ppocrv6-medium-rec`
- 字元表：`ppocrv6-medium-rec-characters.json`
- 上游授權副本：[LICENSE-PP-OCRv6-Medium.txt](LICENSE-PP-OCRv6-Medium.txt)

轉換時將 Paddle2ONNX 產生的空 shape `Reshape` 節點等價改為 `Identity`；
ONNX 輸出在修補前後完全一致。固定輸入後，Core ML Compute Plan 的 221 個
運算子均可分派至 Apple Neural Engine。

模型權重檔 `Data/com.apple.CoreML/weights/weight.bin` 大小約 36 MB，SHA-256：
`e2f75e5578c4d78fa2305a924a2ed967b76a411d1210bcf0892246db1463ecae`。

Medium 是目前 MangaKitchen 的預設 OCR recognizer；若 Medium 模型資源無法載入，App
會回退到 `ppocrv6-small-rec`。
