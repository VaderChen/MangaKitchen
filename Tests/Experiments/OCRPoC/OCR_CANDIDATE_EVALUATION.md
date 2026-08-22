# OCR 候選模型評估

評估日期：2026-08-22

這份評估只比較候選模型與原生執行可行性；本次沒有把新模型加入 MangaKitchen 正式 OCR pipeline。
目前 App 仍只使用已驗證的 PP-OCRv6 Small Core ML recognizer。

## 結論摘要

| 候選 | 日文漫畫適配性 | 授權 | 原生 macOS／Swift 可行性 | 結論 |
|---|---|---|---|---|
| PP-OCRv6 Small（目前） | 能處理日文、直排；已有漫畫 PoC 與 Core ML 驗證 | Apache-2.0 | Core ML MLProgram，已可用 | 保留為目前主候選 |
| PP-OCRv5 mobile rec | 官方說明支援繁中、英文、日文、直排、手寫與稀有字；48×320、18,385 類別 | Apache-2.0 | PyTorch 可載入；Core ML 轉換目前失敗 | 最值得下一輪修轉換器的候選 |
| Manga OCR base | 專為日文漫畫，訓練於 Manga109-s，支援直排、振假名、背景疊字與多字體 | Apache-2.0 | VisionEncoderDecoder + 自回歸 decoder；ONNX 也需 encoder／decoder／tokenizer loop | 品質候選，但不是目前無依賴的 Swift／Core ML 路徑 |
| Manga OCR ONNX（mayocream / l0wgear） | 延續 Manga OCR 的日文漫畫能力 | Apache-2.0（mayocream；l0wgear 未在 metadata 標出） | 可由 ONNX Runtime 執行，但 App 目前沒有 ONNX Runtime；轉 Core ML 要處理 decoder 狀態 | 暫不整合 |

## 小型驗證

### PP-OCRv5 mobile recognizer

來源：[PaddlePaddle/PP-OCRv5_mobile_rec_safetensors](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_rec_safetensors)

使用 macOS Apple Silicon、Python 3.12、PyTorch 2.8、Core ML Tools 9.0 與 Transformers master 的暫時環境驗證：

- Hugging Face 模型可載入。
- 輸入固定為 `1×3×48×320`。
- PyTorch 輸出為 `1×40×18385`。
- TorchScript trace 最大絕對誤差為 `0.0`。
- Core ML Tools 9.0 轉換在 attention encoder 的 `int` 節點失敗：
  `TypeError: only 0-dimensional arrays can be converted to Python scalars`。

因此它不是模型權重或 Swift runtime 介面不相容，而是目前 Core ML Tools 對 PP-OCRv5 這個 attention graph 的轉換問題。下一輪可嘗試固定 attention shape、改用較新的 Core ML Tools／PyTorch 組合，或從 Paddle／ONNX graph 轉換；在此之前不應把模型檔放入 App。

### Manga OCR

來源：[kha-white/manga-ocr-base](https://huggingface.co/kha-white/manga-ocr-base)、[mayocream/manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx)

metadata 驗證結果：

- `kha-white/manga-ocr-base` 是 Apache-2.0 的 `vision-encoder-decoder`，encoder 為 DeiT，decoder 為自回歸文字模型。
- ONNX 版本拆成 `encoder_model.onnx` 與 `decoder_model.onnx`，並需要 tokenizer／generation config。
- `mayocream` ONNX 權重約為 encoder 343 MB、decoder 117 MB；不是單一可直接餵入目前 `PPOCRRecognitionRuntime` 的 logits 模型。

## 建議順序

1. 先保留 PP-OCRv6 Small；它已完成 Core ML／ANE 與漫畫裁切驗證。
2. 下一輪優先修 PP-OCRv5 的 Core ML conversion，再以相同 `LocalOCRRecognizing` 介面做獨立候選比較。
3. Manga OCR 只在願意引入自回歸 decoder runtime（ONNX Runtime、MLX 或完整 Core ML decoder loop）時再評估。
4. 不引入 Apple Vision OCR；目前評估範圍限定為可自行管理權重與 runtime 的 OCR 模型。
