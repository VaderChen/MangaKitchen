# 漫畫廚房（MangaKitchen）四階段工作流與 API 契約

## 設計目標

工作流由四個可獨立執行、可重做、可持久化的階段組成。HTML/JavaScript Bridge、Swift App 與 MCP server 都呼叫相同的 `ComicTranslationPipeline`，不各自實作區域辨識、翻譯或合成演算法。

```text
1. scan directory
      ↓ ComicPage[]
2. Core ML dialogue BBOXes → glyph mask refinement ⇄ edit mask strokes
      ↓ DialogueRegion[]（未確認原文）+ dialogue-mask.png + 去字校對預覽 + page.str
3. VLM classification/transcription → translate + auto layout ⇄ edit text/style
      ↓ page.str + translation preview.png
4. save output
      ↓ copy confirmed translation preview to translated page.png
```

一鍵模式不是第五套流程。`runFullPage` 只依序呼叫步驟二、三、四；步驟一提供已掃描的頁面列表。

## 專案、複選與批次規則

- 一個來源目錄對應一個 `projectID`，各自保存來源、輸出、處理設定、頁面與模型目錄。
- `selectedPageID` 是中央畫布顯示的單一作用中頁面；`selectedPageIDs` 是批次命令集合，兩者不可混為同一狀態。
- Command 點擊切換個別選取，Shift 點擊加入連續範圍；搜尋或狀態篩選只改變列表顯示，不會隱式刪除既有頁面。
- `BatchJob` 固定保存建立當下的 `projectID`、`operation`、`pageIDs` 與是否強制重算，執行途中切換專案會被阻止。
- GPU 模型工作使用單一循序佇列；新工作可以排隊，但不會取消正在執行的前一筆工作。
- App 非正常結束後，原本為 `queued` 或 `running` 的紀錄會復原為 `cancelled`，不會未經確認自動重跑模型。

### 逐區處理與進度

- 步驟三的 VLM 轉錄與翻譯都以區域為獨立工作單位。單一區域的裁切、模型推論、回應解析或翻譯失敗時，該區保留原有 `DialogueRegion`，其他區域仍會繼續；`CancellationError` 不會被吞掉，取消工作仍會停止整體佇列。
- `RegionTranslating.translate` 透過 `PageRegionProgress` 回報 1-based 的 `(current, total)`；`ComicTranslationPipeline` 另外透過 `PagePipelineProgress` 回報頁面 0...1 實際進度。兩者不可互相推算，UI 應使用前者顯示文字、後者更新 progress bar。
- App 的等待 DLG 在逐區翻譯時顯示「第 current / total 區」，進度條則使用目前頁面進度與批次已完成頁面數計算，不會因區域索引跳動而跳格。

### 專有名詞資料規則

每個專案快照包含獨立的 `ProjectGlossary`。一筆 `GlossaryEntry` 只有一個來源原詞，但可用 BCP-47 語言代碼保存多個譯詞：

```json
{
  "id": "GLOSSARY-ENTRY-UUID",
  "sourceTerm": "王都",
  "translations": {
    "zh-Hant": "王都",
    "en": "Royal Capital",
    "ja": "王都",
    "ko": "왕도"
  },
  "note": "國家首都的正式名稱"
}
```

語言解析依序為：

1. 完整 BCP-47 不分大小寫比對，例如 `zh-Hant`。
2. 完整鍵不存在時，只回退至明確保存的基礎語言鍵，例如 `zh`。
3. 不會用其他變體替代，例如 `zh-Hans` 不會自動套用至 `zh-Hant`。
4. 每次翻譯只注入本頁 `sourceText` 實際出現、且目前目標語言有譯詞的詞條。

詞表是後續翻譯的約束；修改詞表不會暗中覆寫既有 `.str` 譯文，使用者可針對選取頁面重新執行翻譯。

## 共用資料規則

- `NormalizedPoint` 與 `NormalizedRect` 都以原圖左上角為原點，範圍為 `0...1`。
- 遮罩畫筆的 `diameter` 是相對於原圖短邊的比例，範圍為 `0.001...1`。
- `MaskStroke.mode` 為 `add` 或 `erase`，筆劃依保存順序套用。
- `rawSourceText` 保留 VLM、MCP Agent 或人工最初提供的原文；`sourceText` 是目前供詞表比對與翻譯使用的來源文字。
- `ocrTextRefined` 是為了既有 `.str` 相容而保留的欄位；新流程的 `true` 代表來源文字已由 VLM、MCP Agent 或人工確認，不會觸發任何 OCR 校正服務。
- **GUI 路徑**：步驟二由內建 `MangaBubbleSegmentationCoreMLRuntime` 以 Apple Neural Engine 優先產生對話框 BBOX 與氣泡形狀，再以原圖像素連通元件將 `bounds` 與遮罩收斂到實際字形；此時不載入或呼叫圖生文模型。模型無法載入或推論失敗時，才後備至 `MangaBubbleCandidateDetector` 的封閉白區演算法。步驟三才由 `VLMRegionTranscriptionService` 在既有 BBOX 中分類、轉錄，接著翻譯；未載入圖生文模型時不會回退至系統文字辨識。
- **MCP 路徑**：App 先完成區域與像素遮罩，再由 `prepare_agent_task` 將原圖及完整遮罩 JSON 一次交給 Agent；Agent 只依既有 `region_id` 抽取原文、翻譯與決定排版，最後以 `submit_agent_result` 一次回寫並由 App 合成。MCP 不接受 Agent 修改區域或遮罩，也不呼叫內建 VLM 翻譯。詳見〈標準 MCP〉。
- `maskRefinementApplied == true` 表示遮罩已由封閉區域或 Agent 粗框收斂成亮度／連通元件字形像素遮罩；抗鋸齒遲滯與固定像素膨脹都在像素層完成，不再對逐條矩形做向量描邊，因此輸出的 `dialogue-mask.png` 維持二值邊界。
- `maskCoverageRatio` 是系統像素精修保留的前景筆畫比例；`null` 代表尚未執行自動檢查。
- `maskCoverageComplete == true` 表示前景覆蓋率通過且文字沒有碰到搜尋邊界；擴張搜尋遇到貼著 `bubbleBounds` 的元件時會排除該元件以免抹掉泡泡框線。若未通過，由使用者回到 App 步驟二調整，不讓 Agent 變更邊界或重建遮罩。
- `bounds` 是涵蓋完整原文的粗搜尋範圍，不直接作為最終遮罩；`bubbleBounds` 必須涵蓋整個對話框外接範圍，`bubbleMaskPolygons` 則是已知的實際氣泡形狀，像素搜尋、遮罩與裁切都不得越界。
- `bubbleLayoutBounds` 是完全位於氣泡形狀內的最大軸對齊矩形，只供譯文安全排版；不能用它取代 `bubbleBounds`，否則貼近弧線的原文字形可能無法被遮罩。
- 自動排版方向優先使用像素字形 BBOX 的實際排列偵測結果；只有字形不足或排列模稜兩可時，才回退既有的自動判定規則。明確指定 `writingDirection` 時仍以使用者設定為準。
- `DialogueStyle.fontSize == null` 表示先依原文字形遮罩面積／字數估算接近原稿的起始字級，再於 `minimumFontSize...maximumFontSize` 內自動配適；指定數值代表優先字級，但譯文超出安全框時仍會向下縮小。排版以原文字形中心為錨點，縮字後仍無法容納時才逐步使用更多泡泡空間；同一泡泡內相鄰且重疊的排版區會按錨點中線分割成互不重疊的欄位，最後一律裁切於各自欄位與 `bubbleLayoutBounds`／`bubbleBounds` 安全內框。
- 掃描結果以來源目錄下的 `relativeSourcePath` 自然排序。
- `.str` 是原圖 sidecar，固定放在原圖旁並使用相同檔名主體；例如來源 `chapter01/003.jpg` 對應來源側的 `chapter01/003.str`。輸出目錄只按相同子目錄結構保存 `chapter01/003.png`。
- 輸出目錄不得等於來源目錄，也不得位於來源目錄內，避免重新掃描輸出檔或覆寫原圖。

## 頁面狀態

穩定狀態如下：

| 狀態 | 意義 | 可執行的下一步 |
|---|---|---|
| `scanned` | 已掃描原圖 | 偵測遮罩 |
| `maskReady` | App／Agent 區域及像素遮罩已保存，MCP 尚待 Agent 抽取原文與翻譯 | 人工修遮罩、翻譯 |
| `translationReady` | 譯文及排版設定已保存 | 人工修文、合成 |
| `completed` | 已輸出合成圖 | 重做任一步驟 |
| `failed` | 最近命令失敗 | 修正問題後重做該步驟 |

`detectingText`、`translating`、`composing` 是執行中狀態。舊版的 `recognizing`、`masking`、`restoringBackground`、`typesetting` 僅保留工作區向後相容。

## Swift API

### 目錄與路徑

```swift
let pages = try ComicDirectoryScanner().scan(sourceDirectoryURL)
let paths = try WorkflowPathResolver().paths(
    sourceURL: page.sourceURL,
    relativeSourcePath: page.relativeSourcePath!,
    outputDirectoryURL: outputDirectoryURL
)
```

`ComicDirectoryScanner` 會遞迴讀取 PNG、JPEG、HEIC/HEIF、TIFF 與 WebP，回傳圖片尺寸與相對路徑。`WorkflowPathResolver` 會拒絕絕對路徑、`.` 與 `..` 路徑穿越。

### Pipeline

```swift
let detection = try await pipeline.detectMasks(
    page: page,
    options: options,
    progress: progress
)

let maskURL = try await pipeline.regenerateMask(
    page: page,
    regions: editedRegions,
    options: options
)

let translatedRegions = try await pipeline.translate(
    page: page,
    regions: editedRegions,
    options: options,
    progress: progress
)

let composition = try await pipeline.compose(
    page: page,
    regions: translatedRegions,
    options: options,
    outputURL: finalOutputURL,
    progress: progress
)
```

保留的一鍵 API：

```swift
let result = try await pipeline.process(
    page: page,
    options: options,
    outputURL: finalOutputURL,
    progress: progress
)
```

### `.str` 儲存

```swift
let table = ComicStringTable(page: page, targetLanguageCode: "zh-Hant")
try await ComicStringTableRepository().save(table, to: stringTableURL)
```

寫入使用 atomic replace；更新前會把上一版複製為同路徑的 `.bak`。讀取主檔失敗時會嘗試備份。

## `.str` 格式

副檔名是 `.str`，內容為 UTF-8、版本化 JSON。第一版主要結構如下：

```json
{
  "schemaVersion": 1,
  "sourceRelativePath": "chapter01/003.jpg",
  "pixelWidth": 1600,
  "pixelHeight": 2400,
  "targetLanguageCode": "zh-Hant",
  "updatedAt": "2026-08-16T10:00:00Z",
  "entries": [
    {
      "id": "REGION-UUID",
      "order": 0,
      "bounds": { "x": 0.62, "y": 0.08, "width": 0.24, "height": 0.18 },
      "rawSourceText": "原妏",
      "sourceText": "原文",
      "ocrTextRefined": true,
      "translatedText": "譯文",
      "translationAnchor": { "x": 0.74, "y": 0.17 },
      "confidence": 0.94,
      "style": {
        "fontName": "PingFang TC",
        "fontSize": 24,
        "minimumFontSize": 9,
        "maximumFontSize": 40,
        "writingDirection": "vertical",
        "textColorHex": "#111111"
      },
      "automaticMaskEnabled": true,
      "maskRefinementApplied": true,
      "maskStrokes": [
        {
          "id": "STROKE-UUID",
          "mode": "erase",
          "diameter": 0.015,
          "points": [{ "x": 0.71, "y": 0.12 }, { "x": 0.73, "y": 0.14 }]
        }
      ]
    }
  ]
}
```

`.str` 不保存來源圖片的絕對路徑，因此整個來源／輸出目錄可一起搬移。

## HTML/JavaScript API

`workflow.js` 暴露 `window.MangaKitchenWorkflow`，介面設計只需使用這個物件，不直接組裝 Native message。

| 方法 | 用途 |
|---|---|
| `getInterfaceLanguage()` | 取得 `{ setting, resolvedLanguage }`；`setting` 可能是 `auto` |
| `setInterfaceLanguage(language)` | 設定 `auto`、`zh-Hant`、`en`、`ja` 或 `ko`，立即重繪並保存偏好 |
| `updateGlobalSettings(settings)` | 更新完整全域設定；包含色系、資料位置、偏好模型與 MCP 網路設定 |
| `chooseDataDirectory()` | 開啟原生資料目錄選擇面板；回傳 `{ path }`，套用後需重新啟動 |
| `choosePreferredModelDirectory(capability)` | 選取並驗證 `imageToText` 或 `imageToImage` 模型目錄 |
| `chooseModelDownloadDirectory(capability)` | 選取模型儲存根目錄；若直接選到支援的既有模型，會回傳其版本 |
| `downloadPreferredModel(capability, variantID)` | 從 Hugging Face 下載所選圖生文模型；已存在時不重複下載 |
| `createProject()`／`chooseSourceDirectory()` | 以來源目錄建立專案；既有目錄則切換並重掃 |
| `switchProject(projectID)` | 切換目前專案 |
| `renameProject(name)` | 修改目前專案顯示名稱 |
| `rescanSourceDirectory()` | 重新掃描目前來源 |
| `chooseOutputDirectory()` | 選取只存放最終 PNG 的輸出目錄；`.str` 不會隨之移動 |
| `setPageSelection(pageIDs, activePageID)` | 同時設定批次選取與中央畫布頁面 |
| `selectAllPages()`／`clearPageSelection()` | 全選或清除批次選取 |
| `runBatch(operation, pageIDs, forceRecalculation)` | 將明確的頁面集合加入遮罩、翻譯、合成或完整處理佇列；重算翻譯時設為 `true`，會重新呼叫 VLM，不沿用既有原文／譯文 |
| `detectMasks(scope)` | `selected` 或 `all` 的步驟二 |
| `translate(scope)` | `selected` 或 `all` 的步驟三 |
| `compose(scope)` | `selected` 或 `all` 的步驟四；只儲存步驟三已完成的翻譯預覽 |
| `runFullPage(scope)` | 保留的一鍵完整頁／全部頁面 |
| `retryFailedBatchJob(jobID)` | 以原操作重新排入該工作的失敗頁面 |
| `clearFinishedBatchJobs()` | 清除已完成、失敗或取消的工作紀錄 |
| `upsertGlossaryEntry(sourceTerm, translations, entryID, note)` | 新增或更新一詞對多語言詞條 |
| `removeGlossaryEntry(entryID)` | 移除目前專案的詞條 |
| `createMaskRegion(pageID, bounds)` | 新增區域，回傳 `{ regionID }` |
| `appendMaskStroke(pageID, regionID, mode, diameter, points)` | 添加或擦除遮罩 |
| `undoMaskStroke(pageID, regionID)` | 復原該區域最後一筆遮罩 |
| `removeRegion(pageID, regionID)` | 移除區域 |
| `updateRegion(pageID, regionID, changes)` | 更新文字、`translationAnchor` 譯文中心點、字型、字級及排字設定 |

命令 Promise 代表 Native 已接受命令。長工序的實際狀態、進度及結果由 `window.MangaKitchenNative.receiveState` 持續推送。

`translationAnchor` 使用左上角原點的 0...1 正規化座標，只改變譯文 Layer 與最終排版位置，不會改動來源文字 `bounds`、對話框或遮罩。像素遮罩覆蓋檢查只提供警告；人工遮罩或目前自動遮罩仍可繼續翻譯與合成，不會作為硬性阻擋條件。

介面語言與專案的 `targetLanguageCode` 是兩個獨立設定。改變介面語言只影響 WebUI、原生目錄選擇面板與 MCP menu bar，不會修改譯文語言或專有名詞的對照目標。

## 標準 MCP

`MangaKitchen` 使用官方 Swift MCP SDK `0.12.1`，提供 MCP `2025-11-25` 的標準 Streamable HTTP transport、tools、resources、resource templates、取消與 progress notification。MCP adapter 在 GUI process 內運作，但 JSON-RPC 或 transport 型別不會進入漫畫核心。

啟動參數：

| 參數 | 行為 |
|---|---|
| 省略 | 啟動 GUI，MCP 是否啟動由已保存的設定決定；初始預設關閉 |
| `--mcp=off` | 啟動 GUI，本次啟動停用 MCP |
| `--mcp=on` | 啟動 GUI、MCP listener 與 macOS menu bar 狀態項目 |
| `--mcp` | `--mcp=on` 的簡寫 |
| `--mcp-port=12080` | 覆寫本次啟動的 MCP listener port；設定預設為 `12080` |

GUI 一定會建立。MCP 開啟後即使關閉主視窗，App 與 MCP listener 仍會常駐；可由 menu bar 選單重新開啟主視窗、複製 endpoint 或完整結束 App。布林值也接受 `true/false`、`1/0` 與 `yes/no`；其他值會直接回報參數錯誤。

### Tools

| Tool | 對應功能 |
|---|---|
| `mangakitchen.workspace.list` | 列出 MCP process 內已開啟的所有目錄工作區 |
| `mangakitchen.workspace.open` | 開啟來源／輸出目錄並掃描，回傳明確的 `workspace_id` |
| `mangakitchen.workspace.activate` | 切換 `workspace/current` resource；其他工具仍以明確 ID 操作 |
| `mangakitchen.workspace.rescan` | 重掃來源目錄 |
| `mangakitchen.workspace.set_output` | 設定輸出目錄 |
| `mangakitchen.workspace.configure` | 調整目標語言與預設處理設定；未指定閱讀順序時預設由右至左 |
| `mangakitchen.glossary.list` | 讀取指定工作區的完整多語詞表 |
| `mangakitchen.glossary.upsert` | 新增詞條或以 `entry_id` 更新完整映射 |
| `mangakitchen.glossary.remove` | 移除指定詞條 |
| `mangakitchen.model.load` | 載入本機模型 manifest 目錄 |
| `mangakitchen.workspace.pages` | 查詢每頁產物狀態；`nextAction` 只是摘要，不會授權 Agent 自行執行 |
| `mangakitchen.page.prepare_agent_task` | 主要入口；一次回傳指定頁原圖與步驟二遮罩 JSON |
| `mangakitchen.page.submit_agent_result` | 一次回寫指定頁全部區域的原文、譯文與排版，再直接執行步驟四 |

舊的 `page.detect_masks`、`page.supplement_regions`、`page.translate`、`page.compose`、`page.run_full` 與 `region.*` handler 只保留程式相容性，不再列入 MCP `tools/list`，避免 Agent 自行拆解流程或誤刪、重建區域。

### 單頁工作包契約

MCP 初始化與工具清單只描述能力，不代表應立即操作資料。除非使用者明確要求，Agent 不得清除、重新掃描、重建、刪除、合併或新增區域。重疊區域可能是合法的氣泡／文字配置，不能作為自動清理依據。

標準流程固定為：

1. App 已載入步驟一原圖；若步驟二尚未完成，由 `prepare_agent_task` 在 App 內建立。
2. Agent 呼叫 `page.prepare_agent_task(workspace_id, page_id)`。
3. Tool result 的 image content 直接包含原圖；structured content 的 `regionData` 內嵌所有區域、BBOX、氣泡形狀、像素遮罩、筆刷與現有排版資料，也同時提供目標語言、閱讀順序與專有名詞。
4. Agent 只依既有 `region_id` 處理文字：`sourceText` 與 `translatedText` 若已有內容就是待校稿草稿，必須對照原圖確認或修正；空白欄位才重新抽取或翻譯。同時檢查並必要時調整 `translationAnchor`、`translationBounds`、`fontSize`、`automaticFontSize`、`fontWeight` 與 `writingDirection`。
5. Agent 呼叫 `page.submit_agent_result`，一次送回本頁全部區域。
6. App 驗證回傳 `region_id` 集合與步驟二完全一致，保留遮罩、更新內部專案資料，再直接執行步驟四合成與輸出。

`prepare_agent_task` 只在區域或遮罩不存在時自動建立步驟二；已有資料時直接沿用，不會覆蓋使用者修改。若已有抽取文字、翻譯或排版，這些資料會完整包含在 `regionData.entries` 中，交由 Agent 校稿與調整後回傳。所有 Agent 必要資料均包含於單次 tool result，Agent 不得搜尋、讀取或建立 `.str` 檔案，也不需額外讀取 page resource。

`submit_agent_result.regions` 的格式如下，座標皆為左上原點的 0...1 正規化值：

```json
{
  "workspace_id": "<uuid>",
  "page_id": "<uuid>",
  "regions": [
    {
      "region_id": "<existing-region-uuid>",
      "source_text": "欲しいの？",
      "translated_text": "你想要嗎？",
      "translation_anchor": { "x": 0.82, "y": 0.305 },
      "translation_bounds": { "x": 0.76, "y": 0.285, "width": 0.17, "height": 0.19 },
      "automatic_font_size": true,
      "font_weight": "regular",
      "writing_direction": "vertical"
    }
  ]
}
```

`regions` 必須完整包含工作包內所有 `region_id`，不可重複、缺少或多出項目。`source_text` 與 `translated_text` 必填；其餘排版欄位可省略以沿用 App 的既有或自動設定。Agent 回傳內容不接受 `bounds`、`bubble_bounds`、`mask_polygons` 或筆刷資料，因此不會改動步驟二。

### Resources

```text
mangakitchen://workspace/list
mangakitchen://workspace/current
mangakitchen://workspace/current/glossary
mangakitchen://page/{page_id}
mangakitchen://page/{page_id}/source
mangakitchen://page/{page_id}/mask
mangakitchen://page/{page_id}/output
```

頁面 JSON 狀態以 text resource 回傳；原圖、遮罩與輸出圖以 binary resource 回傳。標準 Agent 流程只使用 `prepare_agent_task` 的內嵌資料，不需要逐一讀取上述 resource。

### 啟動設定

```bash
swift build -c release --product MangaKitchen
```

先啟動 App：

```bash
.build/release/MangaKitchen --mcp=on
```

再將支援 Streamable HTTP 的 MCP client 指向下列 endpoint：

```json
{
  "mcpServers": {
    "mangakitchen": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:12080/mcp"
    }
  }
}
```

不同 MCP client 的設定欄位名稱可能不同。Listener 綁定 `0.0.0.0`，遠端 client 應以這台 Mac 的實際 LAN 位址組合 endpoint，並先在設定 DLG 將單一 IP 或 CIDR（例如 `192.168.1.0/24`）加入白名單。白名單使用 TCP socket 的來源位址，不信任 `X-Forwarded-For`；空白名單會拒絕全部 request。服務目前仍是明文 HTTP，若跨越受信任區網，仍應另加 TLS、身分驗證與 macOS 防火牆規則。
