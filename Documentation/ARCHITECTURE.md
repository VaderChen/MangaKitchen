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

來源目錄是專案的邊界。專案索引位於 `Projects/library.json`，各專案使用 `Projects/<project-id>/project.json`；`ProjectGlossary` 也保存在該專案快照內，不會跨專案共用。未指定外部輸出目錄時的 `.str` 放在該專案自己的 `StringTables`。舊版單一 `Workspace/workspace.json` 只讀取一次並遷移，不直接覆寫或刪除。

翻譯階段先以 `targetLanguageCode` 解析詞條，再依本頁 OCR 的 `sourceText` 篩選實際出現的專有名詞，最後只把命中的 `ResolvedGlossaryTerm` 注入 VLM Prompt。這可避免大型專案將無關詞條全部送進模型，同時讓 GUI、批次流程與 MCP 使用同一套語言選擇規則。

## 四階段處理資料流

```text
1. ComicDirectoryScanner
   └─ 遞迴掃描、自然排序、保留相對路徑

2. Vision OCR + DialogueMaskGenerator
   ├─ TextRegionGrouper + ReadingOrderResolver
   └─ 自動區域 + add/erase 向量筆劃 → dialogue-mask.png + page.str

3. ImageToTextGenerating
   └─ 依整頁語境翻譯每個 region → page.str

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
- `VisionOCRService`：將 Vision 左下原點座標轉成核心的左上原點座標。
- `VLMRegionTranslationService`：一次傳整頁與全部 OCR region，讓模型保留人物語氣與上下文。
- `MetalBubbleCleaner`：執行 Metal compute kernel，作為圖生圖模型不可用時的背景修補。
- `CoreTextDialogueTypesetter`：以 Core Text frame 實作橫排、直排與自動縮字。
- `ComicTranslationPipeline`：只負責階段順序與產物路徑，不知道 UI。

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
- Tools 對應多工作區管理、四階段批次命令與遮罩／文字編輯，Resources 提供工作區列表、目前工作區、`.str`、原圖、遮罩與輸出。
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

1. 氣泡／旁白框 segmentation，產生精準 polygon mask，`DialogueRegion` 再增加可選 polygon。
2. OCR glyph 級座標與原始字級估算，改善擬聲詞和不規則文字。
3. 禁排規則、標點擠壓、直排旋轉字元、ruby 與 fallback font chain。
4. 翻譯長度預估與二次精簡 prompt，避免只靠縮小字級。
5. Project JSON 與原始檔 security-scoped bookmark，支援關閉後復原。
6. 批次輸出命名、格式、色彩描述檔與 metadata 保留。
