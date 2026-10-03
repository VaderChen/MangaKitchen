# 新模型實測（2026-10-03）

## 結論

本次完成 [新模型研究](MODEL_RESEARCH_2026-10-03.md) 建議的第一階段：下載完整權重，以 MangaKitchen 的 Swift／MLX 路徑驗證 **LFM2.5-VL-3B** 與 **Granite 4.2 3B**，並與現有 Qwen 模型比較。

目前兩款都**不加入下載清單，也不更換預設模型**。LFM 修正影像前處理後能完成推論，但漫畫整頁辨識與結構化翻譯仍不可靠；Granite 可載入，但有漏譯、混入日文及語意反轉。較低記憶體不足以抵銷這些問題。本次結論限於下述模型版本、參數、樣本與本專案執行器，不是模型在所有平台上的能力排名。

UI、操作流程、正常翻譯提示、JSON 接受規則及預設模型維持原狀；保留已驗證的相容性／取消修正，以及可重跑的評估工具。

## 環境與方法

- Apple M4、16 GiB 統一記憶體；macOS 27.0.1（26A434）；Swift 6.4；native SwiftPM。
- 每款模型在獨立程序內依序執行，不同時跑 GPU 推論。未清除作業系統磁碟快取，因此載入數字**不是冷啟動測量**。
- 使用正式 `ModelRuntimeHub`、影像前處理與 `VLMRegionTranslationService`；繁體中文、整頁上下文、關閉額外校稿，保留既有補翻行為。沒有為特定模型放寬 UUID 或 JSON 規則。
- 文字評估共 3 批、14 句日文：漫畫台詞 6 句，否定／數字／人名 4 句，慣用語／語氣 4 句。版本庫保留於 `Tools/ModelEvaluation/text-cases.json`。
- 圖文評估含直排、雙欄直排、人工製作的橫排與振假名、整頁 OCR，共 4 個影像輸入；另外以相同整頁影像及 6 句指定原文執行翻譯。此處翻譯是「提供 OCR 原文後的正式翻譯階段」，不是全自動偵測到排版輸出的端到端測試。
- 生成帶抽樣，未固定種子；每組設定各測一次。以下是故障篩選及單次量測，不能據此推論一般準確率或穩定速度優勢。未完成長時間、多頁 UI 壓力測試；候選已先在基本品質門檻淘汰。

## 模型與參數

| 模型 | 固定版本 | safetensors bytes | 生成設定 |
| --- | --- | ---: | --- |
| [LFM2.5-VL-3B-MLX-4bit](https://huggingface.co/LiquidAI/LFM2.5-VL-3B-MLX-4bit) | `7fad79d26092c1145aa8dde873896a07d3e96a3b` | 2,370,251,601 | temperature 0.2、topP 0.9、repetitionPenalty 1.1；另測 1.0 |
| [Granite 4.2 3B q4 MLX](https://huggingface.co/ibm-granite/granite-4.2-3b-q4-mlx) | `0c6f39b1827afd5eb2c1c3b13751929857434953` | 2,059,005,430 | temperature 1.0、topP 0.95、repetitionPenalty 1.1；另測 App 預設 0.2／0.9／1.1 |
| [Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | `4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25` | 2,263,022,529 | App 預設 0.2／0.9／1.1 |
| Qwen3.5-4B-MLX-4bit | 既有本機安裝；未重新下載或固定遠端 revision | 3,034,301,037 | App 預設 0.2／0.9／1.1；停用 thinking，未載入 DFlash |

前三款下載均核對檔案大小及 Hugging Face metadata 的 LFS SHA-256。Qwen3.5 使用 `/Volumes/Vader Ext3/AI/Manga/Qwen3.5-4B-MLX-4bit` 作為現有圖文基準，版本可追溯性弱於另外三款。

Granite 的 temperature／topP 按原廠模型卡調整，其他項目仍沿用 App。LFM 模型卡建議 temperature 0.2、top_k 50、repetition_penalty 1.0；本專案 manifest 未提供 top_k，因此第二輪只對齊 temperature 與 repetition penalty，**不宣稱完整重現原廠生成設定**。參數變更僅寫入 `Artifacts` 下的測試模型 manifest，沒有變更使用者模型或 App 預設值。

## 翻譯與辨識結果

| 路徑 | 結果 | 判斷 |
| --- | --- | --- |
| LFM 圖文，完成前處理修正 | 6 區域翻譯在既有補翻後仍拋出 `invalidModelResponse` | 不加入 |
| Qwen3.5 圖文對照 | 同一批 6 區域皆取得非空譯文、正確 UUID，可解析 | 保留目前預設；不代表所有 OCR 都正確 |
| Granite 純文字，原廠 temperature／topP | 14 句僅 9 句取得非空譯文，5 句空白；另有嚴重誤譯 | 不加入 |
| Qwen3 純文字對照 | 14 句均有非空譯文及正確 UUID，但人工檢查仍發現混入日文與慣用語誤譯 | 結構完整性優於本次 Granite；品質仍有限制 |

「非空」不等於「正確」。例如 `田中さんが来なかったわけじゃない。私が会えなかっただけ。` 意思是田中並非沒來，而是說話者沒能見到他；Granite 回覆「田中さん不在，我們無法見面。」反轉前半句。對「あと三分しかない！二人とも、先に逃げて！」則留下空白。

Qwen3 基準也把 `お前には借りができたな。` 的欠人情意思誤作「你竟然可以借到錢了啊。」，否定句仍混入日文。因此本次不把基準測試通過寫成翻譯全對，也沒有更動原有模型推薦順位。

LFM 在裁切後能讀到部分直排文字，橫排主文也大致可讀；但有漏字、振假名未依指示排除，以及文字未包成指定 JSON 陣列。整頁回覆出現影像不存在的句子。Qwen3.5 的直排裁切較可讀，但橫排／振假名與整頁測例仍有誤字或多包一層陣列。本次沒有把這些少量樣本換算成 OCR 準確率。

LFM 將 repetition penalty 調成 1.0 後，6 區域翻譯仍於 22.65 秒後得到 `invalidModelResponse`：回傳未提供的 UUID、缺少必要翻譯欄位，且混入日文與粵語。整頁 OCR 則回成物件框／標籤，沒有依要求抄錄日文。這輪補測亦通過取消、卸載與重新載入檢查，未改善納入清單所需的品質。

## 時間與記憶體

以下 LFM 採完成圖片邊界 token 修正後、repetitionPenalty 1.1 的一輪；Granite 採 temperature 1.0／topP 0.95。翻譯耗時含正式服務內既有的補翻，失敗速度不能視為成功完成工作的效能。

| 模型 | 載入秒數 | 6 句漫畫翻譯秒數 | MLX active 峰值 GiB | 程序 peak RSS GiB |
| --- | ---: | ---: | ---: | ---: |
| LFM2.5-VL-3B | 4.26 | 17.74（失敗） | 2.859 | 2.610 |
| Qwen3.5-4B VLM | 4.36 | 32.40 | 4.994 | 3.022 |
| Granite 4.2 3B | 4.46 | 39.25（漏 2 句） | 2.519 | 2.073 |
| Qwen3-4B text | 3.94 | 22.43 | 2.856 | 2.329 |

Granite 另外兩批為 68.09 秒與 23.30 秒，Qwen3 為 16.33 秒與 15.13 秒。LFM 4 個 OCR 輸入分別為 0.95、0.79、1.44、3.32 秒，Qwen3.5 為 5.25、1.60、3.28、6.79 秒；請連同上述錯誤閱讀。

記憶體峰值涵蓋此程序的測例、取消及重新載入。MLX active 不含閒置 cache；Darwin RSS 是程序高水位，兩者不能相加當作整機需求。這些是執行器測試，未包含完整 GUI、OCR 引擎、上色模型等同時駐留的成本。

取消修正後，四款皆回報 `CancellationError`，可卸載並重新載入生成。卸載含背景工作排空約 0.16–0.34 秒；MLX active 回落至 2,720–4,528 bytes，第二次卸載後為 5,400–9,048 bytes，cache 均為 0。這證實本輪權重可釋放，不能取代長時間壓力測試。

## 程式修正

1. **LFM2.5 圖片 token 與 processor 設定**：從 tokenizer 取得 `<image>`，修正舊版硬編碼 396 與新版 124907 不符造成的程序中止；讀取巢狀 `image_processor`，依此版本的非切片設定維持長寬比與圖片 token 預算，補上圖片開始／結束 token，避免重複包覆。舊版 flat config 保持原有尺寸策略。
2. **輸入錯誤可回報**：缺少或多出的圖片 placeholder、錯誤 token，以及特徵數量不合改為拋出錯誤，避免 `fatalError` 中止整個 App。
3. **取消語意**：文字與圖文 stream 在取消時可能直接結束、沒有下一個事件。生成結束及收尾後再次檢查取消，避免把半截譯文當作正常結果交回。
4. **回歸與實測入口**：新增 5 個不需權重的 LFM processor 測試，以及由環境變數啟用的本機權重評估。一般測試不會下載或載入大型模型。

影像處理對照來源為原廠隨模型提供的 `processor_config.json`、[Transformers LFM2-VL processor](https://github.com/huggingface/transformers/blob/main/src/transformers/models/lfm2_vl/processing_lfm2_vl.py) 與 [MLX-VLM LFM2-VL processor](https://github.com/Blaizzy/mlx-vlm/blob/main/mlx_vlm/models/lfm2_vl/processing_lfm2_vl.py)。本次沒有移植額外多圖切片模式或 DSpark。

## 驗證結果

- 最終程式以 native SwiftPM 編譯，5 個 LFM processor 測試全部通過。
- 完整回歸測試：178 項中 **175 通過、3 跳過、0 失敗**，耗時 18.52 秒。跳過的是兩個需指定本機 GGUF 權重的測試，以及未啟用環境變數的本次評估測試；不是把候選的品質失敗隱藏為通過。
- 另行啟用完整權重評估時，LFM 兩組最終參數均因 `invalidModelResponse` 失敗；Granite 因空白譯文斷言失敗，Qwen 兩條對照路徑通過結構檢查。這些結果與人工語意檢查一起用來決定暫不納入。
- 取消、卸載、再載入在四款模型皆有實際執行並通過；`git diff --check` 通過。

## 重現與保存

執行方式見 [Tools/ModelEvaluation/README.md](../Tools/ModelEvaluation/README.md)。測試類別為 `LocalModelEvaluationTests`；報告保存逐次 prompt、原始 output、每組結果、耗時、錯誤與記憶體。結構斷言結果另見 XCTest log；報告 `error` 為拋出的錯誤，不涵蓋全部 XCTest assertion。

本機原始檔保留在不納入版控的 `Artifacts/model-evaluation-2026-10-03/`：

- `lfm-final-evaluation.{json,log}`：完整前處理修正，repetition penalty 1.1。
- `lfm-repetition-1-evaluation.{json,log}`：repetition penalty 1.0 的補測。
- `granite-reference-evaluation.{json,log}`：原廠 temperature／topP；`granite-evaluation.*` 為初始預設參數測例，部分語料不同，不作逐秒對照。
- `qwen-vlm-evaluation.{json,log}`、`qwen-text-evaluation.{json,log}`：基準結果。
- `lfm-cases.json`、`text-cases.json`、裁切圖、`make-fixtures.swift` 與 `models/`。

本次漫畫影像來自使用者資料目錄 `~/Library/Application Support/MangaKitchen/Samples/Gemini_Image_001.jpeg`（687×1024），**與 repository 同名檔案不同**。SHA-256 為 `e3c93ed3db75236f997feb9a8b37c011220c9e2b8656c4a130692d7033cfacf5`。直排裁切範圍為 x553/y67/w92/h148，雙欄為 x44/y68/w125/h159。橫排／振假名圖由 AppKit 產生，內容為「約束を忘れないで。」「明日の午後三時、駅で待ってる。」及「やくそく」。沒有將使用者影像或模型權重放進 Git，也未執行模型 repository 的遠端程式碼。
