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
- `BatchJob` 固定保存建立當下的 `projectID`、`operation` 與 `pageIDs`，執行途中切換專案會被阻止。
- GPU 模型工作使用單一循序佇列；新工作可以排隊，但不會取消正在執行的前一筆工作。
- App 非正常結束後，原本為 `queued` 或 `running` 的紀錄會復原為 `cancelled`，不會未經確認自動重跑模型。

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
- **GUI 路徑**：步驟二由內建 `MangaBubbleSegmentationCoreMLRuntime` 以 Apple Neural Engine 優先產生對話框 BBOX，再以原圖像素連通元件將 `bounds` 與遮罩收斂到實際字形；此時不載入或呼叫圖生文模型。模型無法載入或推論失敗時，才後備至 `MangaBubbleCandidateDetector` 的封閉白區演算法。步驟三才由 `VLMRegionTranscriptionService` 在既有 BBOX 中分類、轉錄，接著翻譯；未載入圖生文模型時不會回退至系統文字辨識。
- **MCP 路徑**：譯文一律由外部 Agent 提供，後端永不呼叫內建圖生文模型翻譯；區域來源以 `region_source` 切換（`agent` 由 Agent 提供／`local` 用本機封閉區域偵測與 VLM）。後端共用像素遮罩收斂、背景修補與排版。詳見〈MCP 介面〉。
- `maskRefinementApplied == true` 表示遮罩已由封閉區域或 Agent 粗框收斂成亮度／連通元件字形多邊形，產生遮罩時只再向外擴張 1～3 px。
- `maskCoverageRatio` 是像素精修保留的前景筆畫比例；`null` 代表精確多邊形由人工／Agent 直接提供，或尚未執行自動檢查。
- `maskCoverageComplete == true` 表示前景覆蓋率通過且文字沒有碰到搜尋邊界；擴張搜尋遇到貼著 `bubbleBounds` 的元件時會排除該元件以免抹掉泡泡框線，但仍回報 false，因為它也可能是範圍太窄而被截掉的文字。此時應擴大安全範圍、重算遮罩，或由 Agent／人工補入精確多邊形與畫筆。
- `bounds` 是涵蓋完整原文的粗搜尋範圍，不直接作為最終遮罩；`bubbleBounds` 必須涵蓋整個對話框內緣，像素搜尋及多邊形都不得越界。
- `DialogueStyle.fontSize == null` 表示先依原文字形遮罩面積／字數估算接近原稿的起始字級，再於 `minimumFontSize...maximumFontSize` 內自動配適；指定數值代表優先字級，但譯文超出安全框時仍會向下縮小。排版以原文字形中心為錨點，縮字後仍無法容納時才逐步使用更多泡泡空間；同一泡泡內相鄰且重疊的排版區會按錨點中線分割成互不重疊的欄位，最後一律裁切於各自欄位與 `bubbleBounds` 安全內框。
- 掃描結果以來源目錄下的 `relativeSourcePath` 自然排序。
- `.str` 是原圖 sidecar，固定放在原圖旁並使用相同檔名主體；例如來源 `chapter01/003.jpg` 對應來源側的 `chapter01/003.str`。輸出目錄只按相同子目錄結構保存 `chapter01/003.png`。
- 輸出目錄不得等於來源目錄，也不得位於來源目錄內，避免重新掃描輸出檔或覆寫原圖。

## 頁面狀態

穩定狀態如下：

| 狀態 | 意義 | 可執行的下一步 |
|---|---|---|
| `scanned` | 已掃描原圖 | 偵測遮罩 |
| `maskReady` | VLM／Agent 原文、區域及遮罩已保存 | 人工修遮罩、翻譯 |
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
| `runBatch(operation, pageIDs)` | 將明確的頁面集合加入遮罩、翻譯、合成或完整處理佇列 |
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
| `mangakitchen.workspace.configure` | 調整目標語言與預設處理設定 |
| `mangakitchen.glossary.list` | 讀取指定工作區的完整多語詞表 |
| `mangakitchen.glossary.upsert` | 新增詞條或以 `entry_id` 更新完整映射 |
| `mangakitchen.glossary.remove` | 移除指定詞條 |
| `mangakitchen.model.load` | 載入本機模型 manifest 目錄 |
| `mangakitchen.workspace.pages` | 取得檔案工作清單與每頁 `next_action`，供 Agent 迴圈處理 |
| `mangakitchen.page.detect_masks` | 步驟二 |
| `mangakitchen.page.supplement_regions` | 外部 Agent 批次補入遺漏文字，並由後端精修與重建遮罩 |
| `mangakitchen.page.translate` | 步驟三 |
| `mangakitchen.page.compose` | 步驟四 |
| `mangakitchen.page.run_full` | 一鍵完整頁或批次完整處理 |
| `mangakitchen.region.create` | 新增區域 |
| `mangakitchen.region.update` | 修改文字／位置／字型／字級 |
| `mangakitchen.region.remove` | 移除區域 |
| `mangakitchen.mask.add_stroke` | 添加或擦除遮罩筆劃 |
| `mangakitchen.mask.undo_stroke` | 復原最後一筆遮罩 |

四個頁面工具的 `page_ids` 可省略；省略或傳空陣列代表工作區全部頁面。長工序若收到 MCP `_meta.progressToken`，會發送 `notifications/progress`。MCP 的 request cancellation 會傳遞至 Swift Task 與模型 Pipeline。

**MCP 的譯文一律由 Agent 提供。** 後端永遠不會呼叫內建圖生文（imageToText）模型翻譯 —— 這不是靠旗標控制，而是兩條管線的 translator 位置都固定是 `AgentDrivenTranslator`，結構上就無法退回本機翻譯。實務上 Agent 的翻譯品質也遠勝可在本機執行的小模型。

**區域來源可切換**，用 `workspace.configure` 的 `region_source` 設定（工作區層級，隨 session 保存）：

| `region_source` | 區域（文字位置與原文） | 翻譯 | 適用情境 |
| --- | --- | --- | --- |
| `agent`（預設） | 由 Agent 提交；後端不執行本機區域辨識 | Agent | 沒有本機模型，或 Agent 的版面判讀較準 |
| `local` | 本機 Core ML 氣泡 BBOX 與像素遮罩 | Agent | 想使用本機穩定幾何，再由 Agent 提供原文與譯文 |

`agent` 模式使用 `AgentDrivenRegionDetector` 與 `AgentDrivenTranslator`，不啟動本機區域辨識；`local` 模式改用 `MangaBubbleMaskRegionDetector`，但 translator 仍固定為 `AgentDrivenTranslator`。

兩種模式下後端共用像素級遮罩收斂、背景修補與排版。`model.load` 可載入 imageToImage 模型供 `page.compose` 的生成式背景修補使用；MCP 的原文與譯文一律由 Agent 提供，`region_source: local` 也不在 `page.detect_masks` 載入 imageToText 模型。

⚠️ 切到 `local` 後，`page.detect_masks` 會**重新產生區域並覆寫**該頁既有結果（含已寫入的譯文）；`agent` 模式則保證不覆寫。

標準流程：

`region_source: agent`（預設）：

1. `page.detect_masks` —— 不做辨識，只把目前已提交的區域收斂成像素級遮罩並輸出遮罩圖，**不會覆寫**既有區域。頁面還沒有區域時輸出空白遮罩。
2. 讀取 `mangakitchen://page/{page_id}` 與 `/source`，由 Agent 自行辨識。
3. `page.supplement_regions` 批次提交區域與原文。
4. `region.update` 寫入 `translated_text`。
5. `page.compose` 輸出。

`region_source: local`：

1. `page.detect_masks` —— 本機偵測氣泡 BBOX，並產生像素級遮罩；不載入 imageToText 模型。
2. 讀取 `mangakitchen://page/{page_id}` 與原圖 resource，由 Agent 取得各區域原文。
3. `region.update` 寫入 `source_text` 與 `translated_text`。
4. `page.compose` 輸出。

`page.translate` 在此模式下不可用，呼叫會回傳可操作的錯誤訊息，指引改用 `region.update` 寫入譯文。`page.run_full` 只有在所有區域都已有譯文時才會成功，否則會停在同一個錯誤。

### 整批處理：由 Agent 自行迴圈

全自動與否取決於使用者的指令，後端不會自己啟動批次。使用者要求整批處理時，Agent 以 `mangakitchen.workspace.pages` 取得檔案工作清單，依每頁的 `nextAction` 逐頁執行：

| `nextAction` | 意義 | Agent 該做的事 |
| --- | --- | --- |
| `submitRegions` | 這一頁還沒有任何區域 | 讀 `sourceURI` 原圖辨識，`page.supplement_regions` 提交 |
| `writeSourceText` | 有區域但原文不完整 | `region.update` 寫回 `source_text` |
| `writeTranslation` | 原文齊全但缺譯文 | `region.update` 寫入 `translated_text` |
| `compose` | 譯文齊全但尚未輸出 | `page.compose` |
| `done` | 已輸出 | 略過 |

清單另含 `stage`、`regionCount`、`regionsMissingSourceText`、`regionsMissingTranslation`、`regionsWithIncompleteMask`、`hasMask`、`hasOutput` 與 `errorMessage`（輸出沿用 Codable 的 camelCase；只有工具**輸入**參數是 snake_case，例如 `pending_only`），可據此判斷是否需要回頭補遮罩。輸入參數 `pending_only` 預設 `true`，只回傳還有待辦的頁面；完成一頁後重新取清單即可續跑，因此中斷後可以安全接續。

這份清單**刻意不含 `regions` 內容**：`ComicPage` 內嵌完整 `DialogueRegion`（含數千點的 `maskPolygons`），整個專案列出來會是巨大的 payload。需要單頁細節時再讀 `mangakitchen://page/{page_id}`。同一份資料也以 `mangakitchen://workspace/current/pages` 資源提供（該資源一律回傳全部頁面）。

專案（工作區）層級的列表則用 `mangakitchen.workspace.list` 或 `mangakitchen://workspace/list`。

`page.supplement_regions` 是 Agent 提交區域的主要入口。每筆候選需要涵蓋完整原文的粗 `bounds` 與已確認的 `source_text`，也可提供 `writing_direction` 或精確 `mask_polygons`。`bounds` 要貼著文字本身，它同時決定譯文落點與字級推估；`bubble_bounds` 只在文字確實被封閉對話框、旁白框或標題框包住時提供，代表遮罩與譯文都不得越界。無框台詞（直接排在畫面或放射線上的字）請**省略** `bubble_bounds`：省略代表沒有硬邊界，遮罩改為只依 `maskExpansion` 由文字外擴；為無框文字或整格分鏡杜撰一個框，會把譯文推到分鏡中央。既有區域若帶著錯誤的框，可用 `region.update` 傳 `"bubble_bounds": null` 清除。未提供多邊形時，Swift 後端先分析粗框；若對話框內緣仍有可信前景，就擴大搜尋區重算，最終只保存字形級多邊形。覆蓋率不足或文字碰到搜尋邊界時會在 `warnings` 說明，不會以擴大的矩形冒充精確遮罩。候選若與既有或同批區域重疊超過一半就略過，因此同一請求可以安全重送。接受的區域會保留相容欄位 `ocrTextRefined: true`、合併至頁面、重建完整 mask 並同步 `.str`。

對已存在但來源文字不完整的區域，Agent 使用 `region.update` 寫回已確認的 `source_text`。修改來源文字而未同時提供譯文時，既有譯文會清空，避免沿用失效翻譯。

`region.update` 對「nil 本身就是有效狀態」的欄位採三態語意：**省略＝維持原值，`null`＝清除回預設，帶值＝設定**。適用欄位與清除後的行為：

| 欄位 | 傳 `null` 的意義 |
| --- | --- |
| `bubble_bounds` | 這個區域沒有對話框；遮罩與譯文改為只依 `maskExpansion` 由文字外擴，不設硬邊界 |
| `translation_anchor` | 譯文落點還原成預設（對話框中心／原文位置） |
| `font_size` | 恢復自動配適字級，等同 `automatic_font_size: true` |

其餘欄位維持「省略＝不變」。`mask_polygons` 傳空陣列 `[]` 即可清除並讓後端重新精修。

`page.supplement_regions` 的 `regions` 格式如下，座標皆為左上原點的 0...1 正規化值：

```json
{
  "workspace_id": "<uuid>",
  "page_id": "<uuid>",
  "regions": [
    {
      "bounds": { "x": 0.82, "y": 0.305, "width": 0.06, "height": 0.16 },
      "source_text": "欲しいの？",
      "bubble_bounds": { "x": 0.76, "y": 0.285, "width": 0.17, "height": 0.19 },
      "writing_direction": "vertical"
    }
  ]
}
```

`page.translate` 只接受每個區域都有非空 `sourceText` 的資料，不會額外重跑文字辨識或改寫來源文字。`page.compose` 與 `page.run_full` 會檢查遮罩、來源文字、譯文與輸出產物，缺少時才逐級回到必要的前一步；已完成資料不會被重做。

### Resources

```text
mangakitchen://workspace/list
mangakitchen://workspace/current
mangakitchen://workspace/current/glossary
mangakitchen://page/{page_id}
mangakitchen://page/{page_id}/strings
mangakitchen://page/{page_id}/source
mangakitchen://page/{page_id}/mask
mangakitchen://page/{page_id}/output
```

JSON 狀態與 `.str` 以 text resource 回傳；原圖、遮罩與輸出圖以 binary resource 回傳。Server 也提供相同 URI 的 resource templates。

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
