# 第三方模型與授權聲明

## PP-OCRv6 Small recognizer

MangaKitchen 內含 `ppocrv6-small-rec-macos14.mlpackage`，它是由
[PaddlePaddle PP-OCRv6 Small recognizer](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors)
轉換成 macOS 14 Core ML MLProgram 的模型。

- 上游專案：PaddlePaddle／PaddleOCR
- 上游模型：`PaddlePaddle/PP-OCRv6_small_rec_safetensors`
- 上游授權：Apache License 2.0
- 轉換內容：固定 `1×3×48×320` 輸入並封裝為 Core ML MLProgram；未修改上游權重或字元表。
- 授權全文：[模型目錄內的 LICENSE-PP-OCRv6-Small.txt](../Sources/MangaKitchenApp/Resources/Models/OCR/LICENSE-PP-OCRv6-Small.txt)

這個模型只在既有 VLM 對話區域內提供 OCR 候選，結果會依模型 ID 保存於 `ocrResults`，不會取代 VLM 的原文、座標或遮罩。
