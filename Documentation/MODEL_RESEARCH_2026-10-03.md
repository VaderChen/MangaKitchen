# 新模型支援評估（2026-10-03）

搜尋範圍為 **2026-08-03 至 2026-10-03**，以開發團隊公布的模型發布日期為準；不把舊模型的新量化版、上傳日期或模型卡更新日期算成新模型。評估以本專案的 Swift／MLX／Core ML 架構及 Apple M4、16 GiB 統一記憶體為基準。

初步研究為官方資料與本機程式碼的靜態查核；同日已依建議下載完整權重，完成 LFM2.5-VL-3B 與 Granite 4.2 3B 的 Swift／MLX 實測。兩者在本專案的翻譯／輸出品質未達納入門檻，**未加入下載清單，預設模型與 UI 不變**。詳細方法、修正與數據見 [模型實測報告](MODEL_EVALUATION_2026-10-03.md)；下列其他候選仍僅完成靜態研究。

## 建議順位

原建議優先驗證 **LFM2.5-VL-3B** 與 **Granite 4.2 3B**：前者評估輕量圖片理解／OCR，後者評估小型純文字翻譯。實測已證實兩者能載入與生成，但架構註冊不代表可直接使用；LFM 還需要圖片前處理修正，而兩者均未通過本輪應用品質檢查。

| 模型／官方發布日期 | 建議用途 | MLX 4-bit 權重檔容量 | 本專案現況與判斷 |
| --- | --- | ---: | --- |
| [LFM2.5-VL-3B，08-12](https://www.liquid.ai/blog/lfm2-5-vl-3b) | 圖片理解、OCR；驗證漫畫直排與小字 | 2.37 GB | 已修正圖片 token／前處理並實測；整頁 OCR 與翻譯 JSON 未達門檻，暫不納入 |
| [Granite 4.2 3B，08-25](https://huggingface.co/blog/ibm-granite/granite-4-2) | OCR 後的文字翻譯、結構化 JSON | 2.06 GB | 已完成載入及翻譯對照；原廠 temperature／topP 下 14 句漏 5 句且有誤譯，暫不納入 |
| [North Micro Vision Instruct 2.4B，08-12](https://huggingface.co/blog/CohereLabs/meet-north-micro-vision-instruct) | 原生解析度 OCR、文字區域定位 | 2.17 GB | 缺少 `cohere_compass` 與 `CohereCompassProcessor`；需實作模型與影像處理器，列第二階段 |
| [LLM-jp-4-VL 9B，09-01](https://llm-jp.nii.ac.jp/blog/llm-jp-4-vl-9b/) | 日文多模態研究比較 | 5.68 GB | 缺少 `llmjpvl`／`LLMjpVLProcessor`，官方也列出漫畫理解與推理重複問題；暫緩 |
| [LFM2.5-2.6B，08-04](https://www.liquid.ai/blog/lfm2-5-2-6b) | 小型文字 Agent 候選 | 1.58 GB | `lfm2` 已存在，但模型固定先推理；不優先用於要求快速完成的翻譯工作 |

容量是查核當日 Hugging Face API 所列 `.safetensors` 檔案大小的合計，GB 採十進位；不包含 tokenizer 等附屬檔案。**權重檔容量不等於推論記憶體**，影像編碼、工作緩衝、KV cache 與其他已載入模型仍會增加用量。North Micro Vision 與 LLM-jp 的容量來自社群 MLX 轉換版，其餘三款為原廠 MLX 發布版本。

## 適用性與限制

### LFM2.5-VL-3B

官方模型卡列出中文、日文、韓文等 16 種語言，模型直接回答、不使用長推理；具有本機圖片理解與 OCR 的評估價值。[原始模型卡](https://huggingface.co/LiquidAI/LFM2.5-VL-3B)

但官方同一組測試中，DocVQA 為 91.1，Qwen3.5-4B 為 94.8；OCRBench v1 為 84.2，Qwen3.5-4B 為 85.6。這些是原廠的一般文件評測，不能推出漫畫翻譯結果，也不足以支持更換目前的預設模型。此候選的主要研究方向是降低資源需求，實際速度與漫畫品質須在 M4 上比較。[官方評測](https://www.liquid.ai/blog/lfm2-5-vl-3b)

授權為 LFM Open License 1.0，含商業使用的營收門檻條件；不能以 Apache-2.0 標示。後續若加入下載清單，應保留正確授權資訊。[模型授權](https://huggingface.co/LiquidAI/LFM2.5-VL-3B-MLX-4bit/blob/7fad79d26092c1145aa8dde873896a07d3e96a3b/LICENSE)

### Granite 4.2 3B

官方提供 MLX 4-bit 版本、結構化 JSON 與中文／日文／韓文等語言支援，使用 Apache-2.0。它是純文字模型，適合接在 OCR 後面；不能取代圖片辨識。官方能力描述尚不能證明日文漫畫轉繁體中文的品質，仍需檢查人名、語氣、擬聲詞與繁簡體一致性。[官方 MLX 模型卡](https://huggingface.co/ibm-granite/granite-4.2-3b-q4-mlx)

下載的 chat template 使用 `enable_thinking` 與 `reasoning_effort`，與目前 `MLXTextRuntime` 傳入的控制鍵一致。架構與主要設定欄位比對相符，也已完成 tokenizer 模板執行及完整生成驗證；實際翻譯仍有漏譯與語意問題，不能只因載入成功便列為可用選項。

### 其他候選

- **North Micro Vision**：小型視覺模型、Apache-2.0，適合關注文件 OCR。現有 Swift 執行器沒有其模型與 processor 實作；Python `mlx-vlm` 可執行或已有 MLX 權重，不代表 MangaKitchen 可直接載入。[官方模型卡](https://huggingface.co/CohereLabs/North-Micro-Vision-Instruct)
- **LLM-jp-4-VL 9B**：本次看的是 9 月正式版，非 4 月 beta。日本團隊的多模態資料訓練使它具有比較價值，但官方報告仍顯示其日文 OCR、文件問答落後 Qwen3.5-9B，並列出漫畫角色／台詞關聯錯誤及推理重複至無法產生答案的案例。連同較高容量與新架構移植成本，優先度較低。[官方發布與限制](https://llm-jp.nii.ac.jp/blog/llm-jp-4-vl-9b/)
- **LFM2.5-2.6B**：官方明確說明為固定先推理的模型，chat template 會開啟 `<think>`，不像 Granite 可直接使用 `enable_thinking=false` 關閉。即使架構已存在，也需先驗證推理輸出與工具呼叫格式，不能把小容量直接等同於快速翻譯。[官方模型卡](https://huggingface.co/LiquidAI/LFM2.5-2.6B)

## 暫不納入本輪支援

- **Qwen-Image 2.1（09-20）**：值得追蹤影像編輯與上色，但目前的 Qwen-Image-Edit-2511 worker 不能視為相容實作。原始發布套件權重合計約 33.12 GB，尚未驗證本專案可用的低記憶體執行方式；其 Qwen Research License 限制為非商業研究／評估，商用須另行授權。[模型與日期](https://huggingface.co/Qwen/Qwen-Image-2.1)、[授權原文](https://huggingface.co/Qwen/Qwen-Image-2.1/raw/main/LICENSE)
- **Qwen3.8-Flash-Next（08-26）**：社群 MLX 4-bit 權重合計約 111.52 GB，且為目前未註冊的 `qwen4_exp` 架構，不符合這台 16 GiB Mac 的本機支援優先順序。[官方發布](https://github.com/QwenLM/Qwen3.8-Flash-Next)、[MLX 版本](https://huggingface.co/mlx-community/Qwen3.8-Flash-Next-4bit)
- **PaddleOCR-VL-1.6**：原模型於 05-28 發布；8 月 MLX 轉換不屬於本次「兩個月內新模型」。目前也沒有 `paddleocr_vl` Swift 模型實作。[官方發布紀錄](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6)
- **LFM2.5-VL-3B-DSpark（09-24）**：是搭配主模型的實驗性推測解碼草稿模型，不是可獨立工作的 OCR／翻譯模型；需另做 DSpark 整合，不能直接套用目前 Qwen 的 DFlash 設定。[官方發布](https://www.liquid.ai/blog/lfm2-5-vl-dspark)
- **Qwen3.8-27B、Gemma 4 系列**：本專案已有對應選項；不因新量化或模型卡更新重複增加項目。

## 本機相容性查核位置

- `Sources/MangaKitchenApp/DownloadableModel.swift`：現有下載清單、用途與預設值。
- `Vendor/mlx-swift-lm/Libraries/MLXVLM/VLMModelFactory.swift`：VLM 架構與影像 processor 註冊。
- `Vendor/mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift`：文字模型註冊。
- `Vendor/mlx-swift-lm/Libraries/MLXVLM/Models/LFM2VL.swift`：LFM 圖文模型設定、影像處理及權重結構。
- `Vendor/mlx-swift-lm/Libraries/MLXLLM/Models/Granite.swift`：Granite 模型設定。
- `Sources/MangaKitchenRuntime/MLXTextRuntime.swift`：翻譯模板、thinking 控制與輸出處理。

本次保留的模型版本及容量如下，方便後續重現；版本雜湊是查核記錄，尚未加入 App 的下載設定。

| MLX repository | 查核版本 | 權重 bytes |
| --- | --- | ---: |
| [LiquidAI/LFM2.5-VL-3B-MLX-4bit](https://huggingface.co/LiquidAI/LFM2.5-VL-3B-MLX-4bit) | `7fad79d26092c1145aa8dde873896a07d3e96a3b` | 2,370,251,601 |
| [ibm-granite/granite-4.2-3b-q4-mlx](https://huggingface.co/ibm-granite/granite-4.2-3b-q4-mlx) | `0c6f39b1827afd5eb2c1c3b13751929857434953` | 2,059,005,430 |
| [mlx-community/North-Micro-Vision-Instruct-4bit](https://huggingface.co/mlx-community/North-Micro-Vision-Instruct-4bit) | `87466363e6c5f57adf91c18c3a62c3c74765f8df` | 2,172,214,057 |
| [mlx-community/llm-jp-4-vl-9b-mlx-4bit](https://huggingface.co/mlx-community/llm-jp-4-vl-9b-mlx-4bit) | `9c056d48b1e611dc586139a5deb927ae363cfe6f` | 5,679,700,630 |
| [LiquidAI/LFM2.5-2.6B-MLX-4bit](https://huggingface.co/LiquidAI/LFM2.5-2.6B-MLX-4bit) | `04efa23776ce61ec34ec95ec34c859854c89542b` | 1,583,152,892 |

原始 Hugging Face API metadata、模型設定及模板保留在本機、不納入版控的 `Artifacts/model-research-2026-10-03/`。未執行模型 repository 的遠端程式碼。

## 加入下載清單前的驗證

1. 使用目前 App 的 Swift 執行器完成權重載入與生成，確認模板、停止 token、量化格式及 VLM 圖片前處理。不得僅以 Python 可執行作為相容證明。
2. 用同一批日文直排、橫排、振假名、小字與多氣泡漫畫，比較現有 Qwen3.5-4B 圖文路徑；Granite 則與 Qwen3-4B 比較同一份 OCR 文字的翻譯。記錄漏字、誤字、閱讀順序、繁體中文品質與 JSON 完整率。
3. 在 M4 上逐一測量冷啟動、每頁完成時間、程序 RSS／MLX 記憶體峰值及多頁處理後的記憶體回落。測試取消、卸載及再次載入，不使用原廠 M5 Max 的數字當作本機結果。
4. 通過相容性與品質驗證後，先加入非預設選項；只有在品質不退步且效能或記憶體有可重現改善時，才評估變更推薦模型。
