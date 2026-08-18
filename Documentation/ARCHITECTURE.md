# 漫畫廚房（MangaKitchen）架構

## 目標

核心設計遵守三個原則：

1. 頁面處理與模型實作分離，替換 Core ML、MLX Swift 或外部 Runtime 時不改專案資料。
2. 原圖座標一律使用左上原點的 `NormalizedRect`，前端 Canvas、Vision、Core Graphics 只在邊界轉換。
3. GPU 工作逐頁執行，避免同時常駐多份大型模型輸入與輸出造成 unified memory 壓力。

## 專案與批次層級

```text
ProjectLibrary
 ├─ Project A（來源目錄、輸出目錄、設定、專有名詞、頁面與複選狀態）
 ├─ Project B
 └─ BatchJob[]（全域循序佇列與最近工作紀錄）

Project
 └─ ComicPage[]
     ├─ selectedPageID：中央畫布作用中頁面
     └─ selectedPageIDs：批次命令選取集合
```

來源目錄是專案的邊界。專案索引位於 `Projects/library.json`，各專案使用 `Projects/<project-id>/project.json`；`ProjectGlossary` 也保存在該專案快照內，不會跨專案共用。每張 `.str` 固定作為原圖 sidecar 放在原圖同一目錄，輸出目錄只保存最終 PNG。讀到舊版位於輸出目錄或 `Projects/<project-id>/StringTables` 的 `.str` 時，會複製到原圖旁並保留舊檔。舊版單一 `Workspace/workspace.json` 只讀取一次並遷移，不直接覆寫或刪除。

翻譯階段先以 `targetLanguageCode` 解析詞條，再依本頁 `sourceText` 篩選實際出現的專有名詞，最後只把命中的 `ResolvedGlossaryTerm` 注入 VLM Prompt。這可避免大型專案將無關詞條全部送進模型，同時讓 GUI、批次流程與 MCP 使用同一套語言選擇規則。

## 四階段處理資料流

```text
1. ComicDirectoryScanner
   └─ 遞迴掃描、自然排序、保留相對路徑

2. MangaBubbleSegmentationCoreMLRuntime + MangaBubbleMaskRegionDetector／外部 MCP Agent + MangaTextMaskRefiner
   ├─ 內建 Core ML 氣泡分割模型優先以 Apple Neural Engine 產生對話框 BBOX 與形狀，不辨識文字
   ├─ 氣泡 instance mask 裁切 BBOX，保存 `bubbleMaskPolygons` 與供排版使用的 `bubbleLayoutBounds`
   ├─ Otsu／連通元件把搜尋結果縮減成字形級像素遮罩，並將文字 bounds 同步縮到字形外框
   └─ 像素層膨脹 + add/erase 畫筆 → 二值 `dialogue-mask.png` + CPU／GPU 去字校對預覽 + page.str

3. ImageToTextGenerating
   ├─ VLMRegionTranscriptionService 在既有 BBOX 內分類、轉錄並排除擬聲字等非翻譯項目
   └─ VLMRegionTranslationService 依整頁語境分批翻譯，每批及整頁都必須覆蓋全部 region → page.str

4. PageBackgroundRestoring + HTMLDialogueTypesetter
   ├─ ImageToImageGenerating（優先）／MetalBubbleCleaner（保底）
   └─ 與步驟三相同的 HTML/CSS 固定或自動字級、橫排／直排 → WebKit PNG
```

每個步驟只透過 Swift protocol 交換 `URL`、`DialogueRegion` 與進度，因此可單獨替換與除錯。
原本的一鍵模式保留，但只負責依序組合步驟二至四。

## Target 責任

### MangaKitchenCore

- 不依賴 AppKit、Metal 或 WebKit。
- 定義 `ComicPage`、`DialogueRegion`、`ProcessingOptions`、`ProjectGlossary` 與 `GlossaryEntry`。
- 定義推論、區域偵測、翻譯、遮罩、修補與排版 protocol。
- 適合未來供 CLI、測試工具或其他 macOS App 重用。

### MangaKitchenRuntime

- `ModelRuntimeHub`：每個 capability 同時只保留一個 protocol-based Runtime，方便控制記憶體並混用 MLX 與 Core ML。
- `CoreMLModelRuntime`：讀取 manifest、編譯模型並透過 `MLModelConfiguration` 指定 CPU + Metal GPU。
- `MLXVLMRuntime`：載入本機 Hugging Face VLM 目錄、縮放輸入圖片、串流產生翻譯 JSON；container 跨頁重用。
- `QwenExternalImageEditRuntime`：以 JSONL 監看獨立 Swift/MLX worker，傳遞進度、錯誤與取消訊號。
- `MaskedImageCompositor`：將生成候選圖縮放回原頁，再只採用 mask 白區，避免生成模型改動未授權區域。
- `MangaBubbleSegmentationCoreMLRuntime`：內建由 `manga109-segmentation-bubble` 匯出的 Core ML YOLO 分割模型。模型依 image constraint 進行方形 letterbox，優先採用 `cpuAndNeuralEngine`；輸出反算回原圖座標並經 NMS 產生 BBOX，若有 prototype 則同步解出 `bubbleMaskPolygons` 與 `bubbleLayoutBounds`。模型無法載入或推論失敗時，才由 `MangaBubbleCandidateDetector` 的封閉白色連通區演算法後備。
- `MangaBubbleMaskRegionDetector`：在步驟二將 Core ML BBOX 與氣泡形狀寫入 `DialogueRegion.bounds`、`bubbleBounds`、`bubbleMaskPolygons` 及 `bubbleLayoutBounds`，不載入或呼叫 VLM；`MangaTextMaskRefiner` 隨即依原圖像素將遮罩與文字 bounds 收斂到實際字形。
- `VLMRegionTranscriptionService`：在步驟三才將既有 BBOX 裁成候選卡片，由 VLM 分類為 `title`、`dialogue`、`caption` 或 `ignore` 並轉錄文字。接受的候選保留原 ID、BBOX、像素遮罩與人工筆劃；擬聲字、頁碼、浮水印、人物與空白區不進入翻譯或最終合成。
- 外部 MCP Agent：讀取原圖及目前 page resource 後，可用 `page.supplement_regions` 送入文字粗框、來源原文及可選的對話框邊界／多邊形。沒有多邊形時同樣交由 `MangaTextMaskRefiner`，因此本機 VLM 與外部 Agent 不會形成兩套遮罩格式或演算法。
- `MangaTextMaskRefiner`：先分析 Core ML BBOX 或 Agent 粗框；若已知 `bubbleMaskPolygons`，會先以氣泡形狀篩選元件。搜尋範圍不會直接成為遮罩，最後以 Otsu 閾值及八鄰域連通元件取得字形像素，並在像素層執行抗鋸齒遲滯與固定像素膨脹，再合併成二值遮罩矩形，避免向量描邊造成灰階毛邊；`bounds` 同步縮到未膨脹的字形外框。暗色背景上的亮字則交由 Agent 精確多邊形或遮罩補筆處理。
- `VLMRegionTranslationService`：保留整頁影像語境並將已確認來源文字的 region 分批翻譯，讓模型保留人物語氣與上下文，且不再次轉錄來源文字；缺少任一句時整頁不會被標記為翻譯完成。
- `MetalBubbleCleaner`：執行 Metal compute kernel，作為圖生圖模型不可用時的背景修補。
- `HTMLDialogueTypesetter`：將步驟三保存的 `translationBounds`、`translationAnchor`、字型、固定／自動字級、粗細及橫排／直排設定交給 WebKit；自動方向優先採用字形排列偵測結果，氣泡排版優先使用完全位於 `bubbleMaskPolygons` 內的 `bubbleLayoutBounds`。使用與 WebUI 相同的 HTML/CSS 與自動縮字演算法渲染背景及文字層，再輸出原圖像素尺寸的 PNG。GUI、批次與 MCP 共用此排版器，不再存在另一套 Core Text 輸出規則。
- `ComicTranslationPipeline`：只負責階段順序與產物路徑，不知道 UI。步驟二的 `SemanticRegionDetecting` 只需 Core ML BBOX／像素遮罩；GUI 在步驟三才要求已載入圖生文模型，且不回退至系統文字辨識。

### MangaKitchenApp

- `AppStore`：多專案切換、作用中頁面、頁面複選及單一 GPU 批次工作佇列。
- `AppPreferencesController`：保存全域介面、色系、資料位置、偏好模型與 MCP 網路設定；不寫入個別漫畫專案。
- `WorkspaceRepository`／`ProjectLibraryRepository`：分別保存專案快照與專案索引；以原子寫入更新並保留 `.bak`。
- `HybridBridgeController`：白名單方式分派 WebUI 命令。
- `i18n.js`：管理 `AUTO`、`zh-Hant`、`en`、`ja`、`ko` 五種介面選項；WebUI local storage 作為啟動畫面快取，Swift 全域偏好是持久化來源，AUTO 依 WebKit/macOS 語言解析，未支援語言回退英文。
- `NativeLocalization`：接收 WebUI 已解析的介面語言，讓原生目錄面板與 MCP menu bar 使用相同語言；介面語言屬於 App 全域偏好，不寫入個別漫畫專案，也不改變翻譯的 `targetLanguageCode`。
- `WebUISchemeHandler`：只提供 bundle 內的 HTML/CSS/JavaScript。
- `AssetSchemeHandler`：只提供已匯入頁面的 source/output 映射，不接受任意檔案路徑。
- 主 Swift Package、可執行產品與內部 modules 統一使用 `MangaKitchen` 命名。
- App 資料存於 `Application Support/MangaKitchen`。

### MangaKitchen MCP 模式

- 使用官方 Swift MCP SDK 與標準 Streamable HTTP transport，監聽 `0.0.0.0`；預設 port 為 `12080`。
- 每個 HTTP request 都以 TCP socket 的實際來源 IP 檢查 IPv4／IPv6／CIDR 白名單，不採信可偽造的轉送標頭；空白名單拒絕所有連線。
- Tools 對應多工作區管理、四階段批次命令、外部 Agent 遺漏區域補完與遮罩／文字編輯，Resources 提供工作區列表、目前工作區、`.str`、原圖、遮罩與輸出。
- 不建立第二個 executable；`MangaKitchen` 永遠啟動 GUI，MCP 開關、port 與白名單由全域設定管理，`--mcp=on|off` 與 `--mcp-port` 可覆寫本次啟動。
- MCP 開啟時建立 macOS menu bar 狀態項目。主視窗關閉後 process 與 MCP 繼續運作，並可從 menu bar 重新開啟視窗或完整結束 App。
- MCP JSON-RPC 僅存在 `MangaKitchenApp/MCP` adapter 目錄；模型 Runtime 與 Pipeline 不依賴 MCP。
- MCP tool 名稱統一使用 `mangakitchen.*`，resource URI 使用 `mangakitchen://`。
- 以標準 session header 管理 HTTP session；MCP process 可保留多個目錄工作區，工具參數仍顯式傳遞 `workspace_id`，避免操作依賴目前顯示中的專案。

完整方法、`.str` schema 與 MCP URI 請見 [WORKFLOW_API.md](WORKFLOW_API.md)。

## 模型擴充點

目前已實作：

```text
CoreMLModelRuntime : ImageToTextGenerating + ImageToImageGenerating
MLXVLMRuntime : ImageToTextGenerating
QwenExternalImageEditRuntime : ImageToImageGenerating
```

Qwen Image Edit 的主套件要求 macOS 26，因此以 `RuntimeSupport/QwenImageEditWorker` 隔離，不改變主 App 的 macOS 14 deployment target。`ModelRuntimeHub` 已使用 protocol existential 並依 manifest 的 `backend` 建立 Adapter，因此 `ComicTranslationPipeline`、AppStore 與 WebUI 不需因模型切換而更動。

## 後續 Layout 核心

UI 設計前建議依序完成：

1. 以漫畫專用 DBNet／CRAFT 或 segmentation 模型補強暗色、彩色背景與非封閉旁白框；擬聲字目前不納入主工作流，未來若支援需使用獨立偵測與排版策略。
2. 禁排規則、標點擠壓、直排旋轉字元、ruby 與 fallback font chain。
3. 翻譯長度預估與二次精簡 prompt，避免只靠縮小字級。
4. Project JSON 與原始檔 security-scoped bookmark，支援關閉後復原。
5. 批次輸出命名、格式、色彩描述檔與 metadata 保留。
