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

翻譯階段先以 `targetLanguageCode` 解析詞條，再依本頁 OCR 的 `sourceText` 篩選實際出現的專有名詞，最後只把命中的 `ResolvedGlossaryTerm` 注入 VLM Prompt。這可避免大型專案將無關詞條全部送進模型，同時讓 GUI、批次流程與 MCP 使用同一套語言選擇規則。

## 四階段處理資料流

```text
1. ComicDirectoryScanner
   └─ 遞迴掃描、自然排序、保留相對路徑

2. Vision OCR + SemanticRegionDetecting／外部 MCP Agent + MangaTextMaskRefiner + OCRTextRefining
   ├─ Vision OCR 與 MangaBubbleCandidateDetector 分別產生文字粗框及封閉白色區域候選，兩者互不作為前置條件
   ├─ 每個 OCR 粗框只歸屬重疊率最高的封閉候選；未歸屬者保留為無框文字候選
   ├─ 所有封閉候選即使沒有 OCR 命中仍送入 VLM；VLM 只做 title／dialogue／caption／ignore 分類與轉錄，不產生座標
   ├─ 系統 OCR、VLM 判讀與封閉框幾何合併、去重；刻意排除擬聲字、頁碼、頁尾資訊及無文字白區
   ├─ ReadingOrderResolver 依專案閱讀方向整理合併後的候選
   ├─ 外部 Agent 可批次提交遺漏文字粗框；重疊候選去重後走相同的像素精修與 `.str` 儲存路徑
   ├─ 文字粗框先定位；若對話框內緣仍有框外前景，就只擴大搜尋區後重新分析
   ├─ Otsu／連通元件把搜尋結果縮減成字形級多邊形，最終僅膨脹 1～3 px
   ├─ 本機 VLM 分批忠實校正且驗證每個區域都有結果；純 MCP 模式可由 Agent 寫回校正文字
   └─ 自動區域 + add/erase 向量筆劃 → dialogue-mask.png + 傳統 CPU／GPU 去字校對預覽 + page.str

3. ImageToTextGenerating
   └─ 依整頁語境分批翻譯，每批及整頁都必須覆蓋全部 region → page.str

4. PageBackgroundRestoring + CoreTextDialogueTypesetter
   ├─ ImageToImageGenerating（優先）／MetalBubbleCleaner（保底）
   └─ 固定或自動字級、橫排／直排 → PNG
```

每個步驟只透過 Swift protocol 交換 `URL`、`DialogueRegion` 與進度，因此可單獨替換與除錯。
原本的一鍵模式保留，但只負責依序組合步驟二至四。

## Target 責任

### MangaKitchenCore

- 不依賴 AppKit、Metal、Vision 或 WebKit。
- 定義 `ComicPage`、`DialogueRegion`、`ProcessingOptions`、`ProjectGlossary` 與 `GlossaryEntry`。
- 定義推論、OCR、翻譯、遮罩、修補與排版 protocol。
- 適合未來供 CLI、測試工具或其他 macOS App 重用。

### MangaKitchenRuntime

- `ModelRuntimeHub`：每個 capability 同時只保留一個 protocol-based Runtime，方便控制記憶體並混用 MLX 與 Core ML。
- `CoreMLModelRuntime`：讀取 manifest、編譯模型並透過 `MLModelConfiguration` 指定 CPU + Metal GPU。
- `MLXVLMRuntime`：載入本機 Hugging Face VLM 目錄、縮放輸入圖片、串流產生翻譯 JSON；container 跨頁重用。
- `QwenExternalImageEditRuntime`：以 JSONL 監看獨立 Swift/MLX worker，傳遞進度、錯誤與取消訊號。
- `MaskedImageCompositor`：將生成候選圖縮放回原頁，再只採用 mask 白區，避免生成模型改動未授權區域。
- `VisionOCRService`：將 Vision 左下原點座標轉成核心的左上原點座標。未載入圖生文模型時，它可獨立產生文字區域並直接進入像素遮罩精修。
- `MangaBubbleCandidateDetector`：不讀文字、不判斷語言，以封閉白色連通區提出標題框／對話泡泡候選。紙白門檻取自直方圖主峰而非固定值（JPEG 與網點會把泡泡內部壓到 240 以下，固定 245 會把整頁碎成數萬個雜訊元件）。元件切割在原始亮區遮罩上進行、補洞則逐元件在自己的外接矩形內做：全頁補洞會把對話框外框墨線填成亮區，使白底分鏡與框內留白連成一體，整格分鏡被誤判成候選。判別依據為補洞後的填充率、框內墨色佔比與最大單一洞佔比（字是許多小洞，人物線稿是一大塊），最後再以包含關係去除包住其他候選的分鏡。
- `VLMSupplementalRegionDetector`：先將每個系統 OCR 粗框指派給包含比例最高且達 0.3 的封閉白區，沒有可信歸屬者保留為無框文字。所有封閉白區都會成為候選，不要求 Vision OCR 預先命中，因此直排 CJK 即使被系統 OCR 漏掉，仍可由 VLM 從封閉框聯絡表補出。封閉候選與無框 OCR 一起裁成每批最多六張的編號聯絡表，由 VLM 對每張卡片回傳 `title`、`dialogue`、`caption` 或 `ignore` 並轉錄文字；擬聲字、頁碼、浮水印、人物與空白區一律忽略。有 OCR 時保留 OCR 原文作 `rawSourceText`，採 VLM 轉錄作 `sourceText`，且完全被框住（≥0.95）的 OCR 聯集決定 `bounds`；沒有 OCR 時直接以 VLM 轉錄建立區域，封閉框同時作為 `bounds` 與 `bubbleBounds`，再由像素精修收斂。無框來源的 `bubbleBounds` 維持空值。最後依幾何重疊及正規化文字去重，再交由 `MangaTextMaskRefiner` 處理。
- 外部 MCP Agent：讀取原圖及目前 page resource 後，可用 `page.supplement_regions` 送入遺漏文字的粗框、校正原文及可選的對話框邊界／多邊形。沒有多邊形時同樣交由 `MangaTextMaskRefiner`，因此本機 VLM 與外部 Agent 不會形成兩套遮罩格式或演算法。
- `VLMOCRTextRefinementService`：保留整頁影像語境，將區域分批傳入，只允許修正誤字、漏字、閱讀順序與標點，不翻譯或潤飾文風；缺少任一 UUID 時拒絕寫入不完整校正。
- `MangaTextMaskRefiner`：先分析 OCR／Agent 粗框；若已知完整 `bubbleBounds`，再掃描整個對話框內緣並比較可信前景，粗框外仍有文字時採用擴大搜尋結果。搜尋範圍不會直接成為遮罩，最後仍以 Otsu 閾值及八鄰域連通元件縮減成字形多邊形；擴張搜尋時會排除碰觸安全邊界的泡泡框線／人物輪廓，但仍把這類元件記為覆蓋檢查未通過，避免把貼邊文字誤判為完成。暗色背景上的亮字則交由 Agent 精確多邊形或遮罩補筆處理。
- `VLMRegionTranslationService`：保留整頁影像語境並將已校正 region 分批翻譯，讓模型保留人物語氣與上下文，且不再次校正來源文字；缺少任一句時整頁不會被標記為翻譯完成。
- `MetalBubbleCleaner`：執行 Metal compute kernel，作為圖生圖模型不可用時的背景修補。
- `CoreTextDialogueTypesetter`：以遮罩多邊形外框（缺少時才回退粗 `bounds`）作為原文字錨點，從原文字形面積與字數估算自動字級；譯文先在原位置優先縮字，只有最小字級仍無法容納時才逐步擴張。同一泡泡內重疊的直排／橫排安全框會依原文錨點中線切成互不重疊的欄位，最後再以各自欄位與 `bubbleBounds` 安全內框硬裁切。Core Text frame 同時支援橫排與直排，固定字級若超出時也會向下縮小而不允許越界。
- `ComicTranslationPipeline`：只負責階段順序與產物路徑，不知道 UI。圖生文模型可用時接收 `SemanticRegionDetecting` 已合併、去重的完整區域；模型不可用時直接沿用系統 OCR 結果。

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

1. 氣泡／旁白框 segmentation，將目前的矩形 `bubbleBounds` 升級為精準內緣 polygon。
2. 以漫畫專用 DBNet／CRAFT 或 segmentation 模型補強暗色、彩色背景與非封閉旁白框；擬聲字目前不納入主工作流，未來若支援需使用獨立偵測與排版策略。
3. 禁排規則、標點擠壓、直排旋轉字元、ruby 與 fallback font chain。
4. 翻譯長度預估與二次精簡 prompt，避免只靠縮小字級。
5. Project JSON 與原始檔 security-scoped bookmark，支援關閉後復原。
6. 批次輸出命名、格式、色彩描述檔與 metadata 保留。
