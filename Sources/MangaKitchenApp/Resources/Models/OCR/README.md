# PP-OCRv6 Small Core ML 模型

`ppocrv6-small-rec-macos14.mlpackage` 是由官方
[PP-OCRv6 Small recognizer safetensors](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors)
轉換而成的固定輸入 Core ML MLProgram，供 macOS 14 以上的原生 OCR runtime 使用。

- 原始模型：PaddlePaddle PP-OCRv6 Small recognizer
- 原始模型授權：Apache License 2.0
- 轉換輸入尺寸：`1×3×48×320`
- App 模型 ID：`ppocrv6-small-rec`
- 字元表：`ppocrv6-small-rec-characters.json`
- 上游授權副本：[LICENSE-PP-OCRv6-Small.txt](LICENSE-PP-OCRv6-Small.txt)

模型權重檔 `Data/com.apple.CoreML/weights/weight.bin` 大小約 10.5 MB，SHA-256：
`737e0cf4201e3d9af0f94a8ced930d0957387c5f97947468f18da5ed89d11f61`。

這個套件是模型格式轉換與固定尺寸封裝，不修改上游神經網路的權重或字元表。App 會將 OCR 結果保存為既有 VLM 區域的候選 `ocrResults`，不會自動覆寫來源文字、座標或遮罩。
