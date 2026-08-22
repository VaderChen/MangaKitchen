# OCR 獨立可行性驗證報告

驗證日期：2026-08-22

## 結論

PP-OCRv6 Small 可在不整合 MangaKitchen 的前提下完成原生 Core ML 轉換，且能在目前專案的 macOS 14 deployment target 上完整使用 Apple Neural Engine。建議後續若要整合，採「官方 safetensors → 固定尺寸 Core ML」路徑；ONNX Runtime 可作 Metal 備案，但不適合作為 ANE 主路徑。

## 測試環境

- Mac mini，Apple M4 Pro，64 GB RAM
- macOS 26.6
- MangaKitchen deployment target：macOS 14
- PaddleOCR 3.7.0 / PaddlePaddle 3.3.1
- Transformers 5.15.1 / PyTorch 2.13.0
- Core ML Tools 9.0
- ONNX Runtime 1.29.0
- 模型：PP-OCRv6 Small detector / recognizer，Apache-2.0

Core ML Tools 9.0 會警告 PyTorch 2.13 尚未列入官方測試版本；本次已另外驗證 Torch trace 零差異、Core ML token 決策一致及實際漫畫輸出，正式建置時仍應鎖定一組 Apple 明列支援的 PyTorch 版本重新產製模型。

## 漫畫辨識品質

官方 PaddleOCR 完整 CPU pipeline 在三張現有樣本上的 warm 結果：

| 頁面 | 時間 | 偵測區域 | 觀察 |
|---|---:|---:|---|
| Gemini_Image_001 | 4.344 秒 | 54 | 多數對話可讀；彩色背景、擬聲詞與混合直排/英文造成誤檢及切分錯誤 |
| Gemini_Image_002 | 2.510 秒 | 15 | 直排對話幾乎完整 |
| Gemini_Image_003 | 1.431 秒 | 24 | 直排對話幾乎完整，出現一個重複假名 |

第二、三頁共人工校對 28 條對話文字，擬聲詞不列入：

- 24/28 條完全一致（85.7%）
- 嚴格字元錯誤率 CER：4/125 = 3.2%
- 錯誤為三個標點遺漏及一個重複假名
- 模型能辨識直排日文，但輸出仍是「文字行」；同一泡泡內必須依右至左欄序重組

第一頁顯示專用 OCR 仍會把擬聲詞、圖案及場景線條當文字，因此不能直接以整頁結果取代現有泡泡區域。較安全的做法是沿用既有區域，再在區域內偵測文字行。

## 原生 Core ML 正確性

從官方 `PP-OCRv6_small_rec_safetensors` 與 `PP-OCRv6_small_det_safetensors` 直接轉成固定尺寸 MLProgram：

- recognizer：`1×3×48×320`，約 10 MB
- detector：`1×3×640×416`，約 4.8 MB
- deployment target：macOS 14
- 隨機輸入的 recognizer token 決策一致率 100%
- detector 在第二頁縮放輸入上，PyTorch 與 Core ML 都產生 16 個框，座標差異約在數個像素內
- 全 Core ML detector → 透視裁切 → recognizer 流程覆蓋 28/28 條對話，23/28 條完全一致，嚴格 CER 為 5/125 = 4.0%

## M4 Pro 硬體結果

下列為固定尺寸、warm median；不含影像前後處理：

| 模型 | ANE | GPU / Metal | CPU | Compute Plan |
|---|---:|---:|---:|---|
| recognizer 48×320 | 0.56 ms | 2.22 ms | 2.42 ms | ANE 167/167 計算算子 |
| detector 640×416 | 1.94 ms | 3.75 ms | 10.10 ms | ANE 192/192 計算算子 |

辨識與偵測模型在 `CPU_AND_NE` 下皆完全分派到 Neural Engine，不是只有指定 compute unit。這也代表 NPU 路線在 macOS 14 模型格式上成立。

ANE 模型初次載入約 0.49–0.53 秒；表格中的 warm latency 不含載入及影像前後處理。

## ONNX 路徑判定

官方 ONNX 模型可由 ONNX Runtime CoreML EP 執行，但結果不理想：

- 動態尺寸會把圖形切成多個 Core ML/CPU partition。
- 固定尺寸後雖可收斂成單一 Core ML partition，但 `CPUAndNeuralEngine` 的 compute plan 仍把全部算子放在 CPU。
- Auto / `CPUAndGPU` 實際使用 GPU，適合作為 Metal 路徑。
- 同一 recognizer 以原生 Core ML 直接轉換後可完整進入 ANE，且明顯更快。

因此：

1. ANE 主路徑：直接由官方 safetensors 轉 Core ML。
2. Metal 備用路徑：同一 Core ML 模型使用 `CPU_AND_GPU`，不需要另外帶 ONNX Runtime。
3. 不建議在正式 App 內加入 ONNX Runtime，除非未來模型無法由 Core ML Tools 轉換。

## 尚未處理的整合議題

- 泡泡內直排文字行的右至左排序與串接。
- 固定 detector 尺寸的頁面比例策略；本次 `640×416` 適合現有兩張直排樣本，通用方案應使用少量 enumerated shapes 或區域內 letterbox。
- OCR confidence 與 VLM fallback 門檻。
- 擬聲詞、標題與正文的分類。
- Core ML 模型 manifest、下載與版本管理。

## 工作樹整合狀態（2026-08-22）

本報告原本驗證的是獨立 PoC；目前工作樹已將 recognizer 以 `PPOCRRecognitionRuntime` 接入 MangaKitchenRuntime。整合採保守的候選保存策略：VLM 先決定區域，OCR 只追加 `ocrResults`，不自動取代 `sourceText`、座標或遮罩。轉換後的 `.mlpackage` 已納入 repository；App 在找不到模型資源時仍會回到原本的 VLM 路徑。

PoC 腳本本身仍不連結 MangaKitchen target；正式 App 的整合程式與回歸測試則位於 `Sources/MangaKitchenRuntime/` 與 `Tests/MangaKitchenRuntimeTests/`。

## 官方來源

- [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR)
- [PP-OCRv6 Small recognition model](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors)
- [PP-OCRv6 Small detection model](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_safetensors)
- [Core ML Tools：PyTorch conversion](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch.html)
