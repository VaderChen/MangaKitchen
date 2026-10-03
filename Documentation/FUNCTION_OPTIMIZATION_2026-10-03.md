# 函式層級最佳化（2026-10-03）

## 範圍與結果

本輪對自有程式建立函式索引並檢查配置、集合處理、像素迴圈、模型前後處理與 I/O 路徑，選擇能維持現有結果的熱點實作最佳化。修改前共有 **106 個 Swift 檔、5 個 JavaScript 檔**，靜態索引得到 1,023 個 Swift `func` 與 194 個具名 JavaScript `function` 宣告；這是文字索引，並非包含所有 initializer、computed property、closure 的 AST 或全函式 profiler 報告。

| 層級 | 檢查重點 | 本輪處理 |
| --- | --- | --- |
| Core／Application | 集合轉換、檔案邊界、原子儲存、取消與流程狀態 | 保留既有串流複製、schema 驗證及互斥契約；未改持久化格式 |
| Runtime | 連通元件、遮罩膨脹／矩形化、Core ML 張量讀取、OCR、MLX 生成、GGUF 讀取 | 改善去字、遮罩精修、分割後處理、逐 token 查找及 QA 正規表示式重複建立 |
| App／MCP | 批次資料組裝、頁面查找、圖片傳輸、輸出與診斷 | 批次工作共用每次快照的頁名索引；同一快照只解析一次目標語言 |
| WebUI | 狀態更新、集合掃描、DOM 更新與既有簽章快取 | 維持現有 HTML、CSS、JavaScript 與操作流程 |

第三方 MLX 核心、模型權重／參數、JSON 接受規則、翻譯提示及 OCR／去字門檻均未調整。本輪未聲稱每個函式都需要改寫，或已證明整個 App 不再有其他效能瓶頸。先前尚未提交的輸出與模型相容性修改全部保留。

## 實際修改

### CPU 去字

`CPUBubbleCleaner.connectedComponents` 直接保留完成遍歷的 BFS queue，移除內容完全相同的第二份像素陣列。

`groupedComponents` 先加總所需容量，再以 `append(contentsOf:)` 合併同區域的筆畫。原版每次 `partial.pixels + component.pixels` 都可能複製累積內容；密集筆畫下改成只追加新內容，保留像素順序、取色及區域匹配規則。

固定底色的 `clean` 不再計算只供自動估色使用的排除遮罩。固定底色的 halo 擴張仍執行，進度與取消檢查保留。

### 像素遮罩

`MangaTextMaskRefiner.connectedComponents` 在遍歷時直接依列累積欄位座標，省去中間 `PixelCoordinate` 陣列。

`grownMaskRectangles` 直接從已依列排列的二值遮罩產生連續區段，再合併相鄰列相同的區段。移除最終「逐像素座標 → 字典分組 → 排序 → 區段」轉換；連通元件與最終遮罩共用小型 `PixelRectangleAccumulator`。輸出多邊形順序、氣泡裁切、Otsu、八鄰域、抗鋸齒遲滯與膨脹半徑維持原規則。

### Core ML 分割後處理

`SegmentationTensorReader` 在讀取輸出時一次取得型別、stride 與 pointer，保留原 `MLMultiArray` 的生命週期。`nonMaximumSuppressedCandidates` 與 `bubbleShape` 不再於內層每個元素反覆取得 Objective-C metadata。

讀取仍支援 float16／float32／double 的原有轉換及非連續 stride；一般 prediction 的整數 fallback 與不支援 prototype 型別回傳零的行為保留。乘加順序、信心門檻、NMS、erosion 與最大內接矩形演算法不變。

### 狀態組裝與生成

- `WebBatchJob.snapshots` 每份快照只建立一次頁名索引，由所有工作共用。P 頁、J 工作的索引建置從 O(P×J) 改為 O(P)，工作與失敗資料仍逐項組裝；每次重新建立索引，因此改名與移除不會留下過期名稱。
- `WebAppState.init` 在同一快照共用解析完成的目標語言，避免每個詞條重讀系統語言。
- `MLXProtocolTokenGenerator.generate` 每個 token 只查一次文字表示，unknown token ID 於生成前取得；僅 Harmony 維護需要的 channel 文字視窗。停止判斷及 token 額度不變。
- `VLMRegionTranslationService.numberTokens` 共用不可變的已編譯正規表示式；數字匹配規則、順序與 QA flag 不變。

最後兩項未另宣稱 LLM token/s 增益；模型矩陣運算不在本輪修改範圍。

## 修改前後實測

Apple M4、16 GiB、macOS 27.0.1、Swift 6.4。原版採 `519ebc2`；四組比較來源檔在本輪開始前與該 revision 相同，故不混入前一輪最佳化的效益。兩份程式使用相同 `swiftc -O` 與共用 Core 型別編譯，依序量測三個獨立程序，以下取中位數。

| 測例 | 原版耗時 | 優化後耗時 | 耗時減少 | 原版 peak RSS | 優化後 peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 密集筆畫、自動底色去字 | 656.60 ms | 535.74 ms | 18.4% | 249.4 MiB | 241.3 MiB |
| 密集筆畫、固定白色去字 | 535.79 ms | 132.84 ms | 75.2% | 258.0 MiB | 248.5 MiB |
| 密集字形遮罩精修 | 331.62 ms | 294.30 ms | 11.3% | 219.8 MiB | 129.6 MiB |
| 漫畫氣泡偵測（含 Core ML 推論） | 86.32 ms | 53.43 ms | 38.1% | 321.0 MiB | 319.9 MiB |
| 5,000 頁／200 工作的批次狀態組裝 | 39.01 ms | 0.281 ms | 99.3% | 15.9 MiB | 15.7 MiB |

遮罩精修程序的 RSS 峰值降低 **41.0%**。其他列的小幅 RSS 差異不應解讀為穩定的整機記憶體收益；所有 RSS 都是測試程序高水位，包含輸入生成或模型載入等成本，不等於 App 常駐 RAM。

前三項使用 2048×3072 合成頁、3,150 個分離字形／筆畫；去字筆畫為 12×16，精修字形為 24×32，滿足既有最小元件面積門檻。這是密集負載測試，不代表一般漫畫平均速度。氣泡偵測使用 repository 的 `Samples/Gemini_Image_001.jpeg` 與內建分割模型，排除載入與第一次預測後，每個程序取五次偵測平均。批次組裝每個程序取十次平均，不包含完整 WebAppState、JSON 序列化或 WebKit 繪製。

未清除作業系統檔案快取；所有比較都用相同順序與輸入。沒有同時執行兩款 benchmark 或 GPU 推論測試。上述改善不能加總成整頁翻譯加速比例。

## 輸出與回歸驗證

五個測例的原版／新版、三次執行輸出皆通過完整 SHA-256 比對。PNG 是整份檔案比較；遮罩與分割結果包含全部座標、順序與相關 metadata；批次 JSON 包含全部回傳欄位。

| 輸出 | SHA-256 |
| --- | --- |
| 自動底色 PNG | `105244740f4957913a0563499cadfe765ef1b67e5e120a0a09c960feb98c74d7` |
| 固定底色 PNG | `671d85f78c6b9086ea34355ae782badc76d9b2ed0229833d0ae08a8ad8a59055` |
| 遮罩精修 JSON | `1eeaa8d65cfae0727e5e4c954a6ca721aff256f9a4b8632d7944e9695c6fc973` |
| 氣泡分割 JSON | `a1ff33154c79c776cc38dfda998b12bd8be0decd490dfd0af9ca266aea150303` |
| 批次狀態 JSON | `8460bb3833a6b06fbd0a958a2f34f6d04858692d5d25512689440a8055580b7f` |

新增測試涵蓋 padded stride 的 float16／float32／double 讀值、原陣列離開區域後的儲存生命週期、整數 prediction fallback、prototype 不支援型別、批次順序、失敗頁名稱回退及改名後的新快照。既有去字、像素遮罩與翻譯安全測試一併驗證。

完整 native SwiftPM 回歸共 **181 項：178 通過、3 跳過、0 失敗**，耗時 16.93 秒。跳過的是未指定本機權重的兩項 GGUF 測試及一項 opt-in 模型品質評估；本輪實際 Core ML 模型偵測另已納入上述比較。編譯、`git diff --check` 均通過，五個自有 WebUI JavaScript 檔的雜湊與本輪修改前相同，HTML／CSS 無變更。未另執行整個 GUI 的人工操作或大型 LLM 推論量測。

重現指令與測量邊界見 [Tools/FunctionPerformance/README.md](../Tools/FunctionPerformance/README.md)。函式索引、修改前快照、build log、完整回歸紀錄與原始數據保留於本機忽略版控的 `Artifacts/function-optimization-2026-10-03/`；正式量測在 `benchmark-final/`，最初的 `benchmark/` 因合成字形小於既有最小面積而中止，不納入上表。
