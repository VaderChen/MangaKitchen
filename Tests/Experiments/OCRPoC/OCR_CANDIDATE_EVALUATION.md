# OCR 候選模型評估

評估日期：2026-08-22

這份評估只比較候選模型與原生執行可行性；本次沒有把新模型加入 MangaKitchen 正式 OCR pipeline。
目前 App 預設使用已驗證的 PP-OCRv6 Medium Core ML recognizer，Small 保留為 fallback。

## 結論摘要

| 候選 | 日文漫畫適配性 | 授權 | 原生 macOS／Swift 可行性 | 結論 |
|---|---|---|---|---|
| PP-OCRv6 Small（fallback） | 能處理日文、直排；已有漫畫 PoC 與 Core ML 驗證 | Apache-2.0 | Core ML MLProgram，已可用 | 保留為 fallback |
| PP-OCRv6 Medium rec | 同系列較大的辨識模型；官方日文辨識指標高於 Small | Apache-2.0 | 直接 PyTorch→Core ML 會失敗；Paddle2ONNX→onnx2coreml 可產生 MLProgram 並完成 ANE PoC | 品質候選；尚未整合 |
| PP-OCRv5 mobile rec | 官方說明支援繁中、英文、日文、直排、手寫與稀有字；48×320、18,385 類別 | Apache-2.0 | PyTorch 可載入；Core ML 轉換目前失敗 | 最值得下一輪修轉換器的候選 |
| Manga OCR base | 專為日文漫畫，訓練於 Manga109-s，支援直排、振假名、背景疊字與多字體 | Apache-2.0 | VisionEncoderDecoder + 自回歸 decoder；ONNX 也需 encoder／decoder／tokenizer loop | 品質候選，但不是目前無依賴的 Swift／Core ML 路徑 |
| Manga OCR ONNX（mayocream / l0wgear） | 延續 Manga OCR 的日文漫畫能力 | Apache-2.0（mayocream；l0wgear 未在 metadata 標出） | 可由 ONNX Runtime 執行，但 App 目前沒有 ONNX Runtime；轉 Core ML 要處理 decoder 狀態 | 暫不整合 |

## 小型驗證

### PP-OCRv6 Medium recognizer

來源：[PaddlePaddle/PP-OCRv6_medium_rec_safetensors](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_safetensors)

使用獨立暫存環境（Python 3.12、PyTorch 2.7／2.8、Core ML Tools 9.0 與 Transformers 5.16 development build）驗證：

- 官方權重可正常載入；參數量為 `19,134,326`，輸入固定為 `1×3×48×320`。
- 輸出為 `1×40×18,710`；Medium 的 18,710 字元字典與目前 App 的 Small 字典完全一致，因此 Swift CTC 解碼介面相容性良好。
- TorchScript trace 最大絕對誤差為 `0.0`（Torch 2.7 與 2.8 均相同）。
- 以 `dialogue-lines.json` 的 28 條人工校對日文直排裁切做辨識（不包含 detector，排除模型首次載入）：

  | 模型 | 完全一致 | CER | 28 條裁切推論時間 |
  |---|---:|---:|---:|
  | PP-OCRv6 Small | 23/28 | 4.8% | 0.466 秒 |
  | PP-OCRv6 Medium | 24/28 | 3.2% | 1.027 秒 |

- 嘗試用現有的固定尺寸 PyTorch→Core ML MLProgram 轉換流程時，Torch 2.7 與 2.8 都在 `model/head/encoder/0/self_attn/929` 的 `int` 節點失敗：
  `TypeError: only 0-dimensional arrays can be converted to Python scalars`。

結論：Medium 在這組漫畫裁切上比 Small 少一個字元錯誤，品質方向值得保留；直接 PyTorch 轉換受 Core ML Tools attention graph 限制，但不代表 Medium 無法走 Core ML。

### Paddle2ONNX → Core ML 路徑

為驗證截圖建議的替代路徑，另外使用官方 Paddle inference 權重與下列工具做轉換：

- `paddlepaddle 3.3.1`
- `paddle2onnx 2.1.0`
- `onnx 1.18.0`、`onnxruntime 1.21.0`
- `onnx2coreml 1.1.0`（社群 ONNX→MIL/Core ML converter）與 `coremltools 9.0`

驗證結果：

1. Paddle2ONNX 可成功將 `PP-OCRv6_medium_rec` 的 `inference.json`／`inference.pdiparams` 匯出為 ONNX opset 11。
2. 匯出的 ONNX 與官方 `PP-OCRv6_medium_rec_onnx` 在固定 `1×3×48×320` 輸入上的 argmax 完全一致，最大絕對差約 `1.1e-6`。
3. Paddle2ONNX graph 有一個空 shape 的 `Reshape.76`，`onnx2coreml` 會將它誤判為 FP32 shape；將該節點等價改為 `Identity` 後，ONNX 輸出前後完全一致，Core ML 轉換成功。
4. 使用固定輸入、FP16、fuse 開啟轉成 `.mlpackage` 後，Core ML Compute Plan 顯示 `221/221` 個運算子分派到 `MLNeuralEngineComputeDevice`。
5. Medium Core ML ANE warm median 約 `1.35 ms`（internal 約 `1.22 ms`）；作為比較，目前 Small 直接 Core ML recognizer 約 `0.56 ms`。Medium 約為 Small 的 2.4 倍，但仍是可接受的本機裁切辨識延遲。
6. 28 條漫畫裁切實測為 `24/28` 完全一致、CER `3.2%`，與 PyTorch Medium 結果一致；輸出仍為 `1×40×18,710`，可沿用目前字典與 Swift 解碼器。

這條路徑已證明技術上可行，但目前只完成獨立 PoC，尚未將轉換腳本、修補後 ONNX 或 37 MB 的 Core ML artifact 放進正式 App。後續若採用，必須把「固定輸入尺寸、Reshape 修補、模型 hash／版本」納入可重現的離線產製流程，再重新跑 App 回歸測試。

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

1. PP-OCRv6 Medium 目前作為預設 recognizer，採 Paddle2ONNX → `onnx2coreml` 的固定尺寸 Core ML／ANE artifact。
2. PP-OCRv6 Small 保留作為資源缺失或模型載入失敗時的 fallback。
3. 若要再提升品質，先以更多漫畫頁面驗證 Medium 的 OCR confidence、直排排序與 VLM fallback 門檻，再考慮 PP-OCRv5 或 Manga OCR。
4. 不引入 Apple Vision OCR；目前評估範圍限定為可自行管理權重與 runtime 的 OCR 模型。
