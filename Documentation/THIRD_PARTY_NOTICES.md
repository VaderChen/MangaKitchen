# 第三方模型與授權聲明

## Medium 模型轉換工具

Medium Core ML artifact 的離線轉換使用
[`onnx2coreml`](https://github.com/devin-lai/onnx2coreml) 1.1.0，BSD 3-Clause
License。轉換工具本身不隨 MangaKitchen App 一起發佈；此處僅保留其產製的
模型 artifact。

## PP-OCRv6 Medium recognizer（預設）

MangaKitchen 內含 `ppocrv6-medium-rec-macos14.mlpackage`，它是由
[PaddlePaddle PP-OCRv6 Medium recognizer](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec)
經 Paddle2ONNX 與 `onnx2coreml` 轉換成 macOS 14 Core ML MLProgram 的模型。

- 上游專案：PaddlePaddle／PaddleOCR
- 上游模型：`PaddlePaddle/PP-OCRv6_medium_rec`
- 上游授權：Apache License 2.0
- 轉換內容：固定 `1×3×48×320` 輸入、FP16 Core ML MLProgram，並修補一個等價的空 shape Reshape 節點。
- 授權全文：[模型目錄內的 LICENSE-PP-OCRv6-Medium.txt](../Sources/MangaKitchenApp/Resources/Models/OCR/LICENSE-PP-OCRv6-Medium.txt)

這個模型是目前預設 OCR recognizer，直接辨識步驟二已定位的對話文字區域。結果會依模型 ID 保存於 `ocrResults`；當 `sourceText` 空白時會成為翻譯原文，但不改動座標或遮罩，也不覆寫已確認的原文。

## PP-OCRv6 Medium detector（文字定位候選）

MangaKitchen 內含 `ppocrv6-medium-det-736x480-macos14.mlpackage`，它是由
[PaddlePaddle PP-OCRv6 Medium detector](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det_onnx)
經 `onnx2coreml` 轉換成 macOS 14 Core ML MLProgram 的模型。

- 上游專案：PaddlePaddle／PaddleOCR
- 上游模型：`PaddlePaddle/PP-OCRv6_medium_det_onnx`
- 上游授權：Apache License 2.0
- 轉換內容：固定 BGR NCHW `1×3×736×480` 輸入、FP16 Core ML MLProgram。
- 授權全文：[模型目錄內的 LICENSE-PP-OCRv6-Medium-Det.txt](../Sources/MangaKitchenApp/Resources/Models/TextLocalization/LICENSE-PP-OCRv6-Medium-Det.txt)

這個模型目前只透過獨立 `LocalTextLocating` 介面產生文字行座標，不取代既有
VLM 定位，也不會在 OCR、翻譯或遮罩階段修改專案資料。

## PP-OCRv6 Small recognizer

MangaKitchen 內含 `ppocrv6-small-rec-macos14.mlpackage`，它是由
[PaddlePaddle PP-OCRv6 Small recognizer](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors)
轉換成 macOS 14 Core ML MLProgram 的模型。

- 上游專案：PaddlePaddle／PaddleOCR
- 上游模型：`PaddlePaddle/PP-OCRv6_small_rec_safetensors`
- 上游授權：Apache License 2.0
- 轉換內容：固定 `1×3×48×320` 輸入並封裝為 Core ML MLProgram；未修改上游權重或字元表。
- 授權全文：[模型目錄內的 LICENSE-PP-OCRv6-Small.txt](../Sources/MangaKitchenApp/Resources/Models/OCR/LICENSE-PP-OCRv6-Small.txt)

這個模型是 Medium 資源無法載入時的 fallback，使用同一套獨立 `ocrResults` 與空白原文採用規則；不改動區域座標或遮罩。
