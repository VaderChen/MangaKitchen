# 漫畫廚房（MangaKitchen）四階段工作流與 API 契約

## 設計目標

工作流由四個可獨立執行、可重做、可持久化的階段組成。HTML/JavaScript Bridge、Swift App 與 MCP server 都呼叫相同的 `ComicTranslationPipeline`，不各自實作 OCR、翻譯或合成演算法。

```text
1. scan directory
      ↓ ComicPage[]
2. detect masks ⇄ edit mask strokes
      ↓ DialogueRegion[] + dialogue-mask.png + page.str
3. translate ⇄ edit text/style
      ↓ page.str
4. compose
      ↓ background.png + translated page.png
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
- `DialogueStyle.fontSize == null` 表示在 `minimumFontSize...maximumFontSize` 內自動配適；指定數值則使用固定字級。
- 掃描結果以來源目錄下的 `relativeSourcePath` 自然排序。
- 輸出保留來源子目錄結構，圖片統一輸出為 PNG；例如 `chapter01/003.jpg` 對應 `chapter01/003.png` 與 `chapter01/003.str`。
- 輸出目錄不得等於來源目錄，也不得位於來源目錄內，避免重新掃描輸出檔或覆寫原圖。

## 頁面狀態

穩定狀態如下：

| 狀態 | 意義 | 可執行的下一步 |
|---|---|---|
| `scanned` | 已掃描原圖 | 偵測遮罩 |
| `maskReady` | OCR、區域及遮罩已保存 | 人工修遮罩、翻譯 |
| `translationReady` | 譯文及排版設定已保存 | 人工修文、合成 |
| `completed` | 已輸出合成圖 | 重做任一步驟 |
| `failed` | 最近命令失敗 | 修正問題後重做該步驟 |

`detectingText`、`translating`、`composing` 是執行中狀態。舊版的 `recognizing`、`masking`、`restoringBackground`、`typesetting` 僅保留工作區向後相容。

## Swift API

### 目錄與路徑

```swift
let pages = try ComicDirectoryScanner().scan(sourceDirectoryURL)
let paths = try WorkflowPathResolver().paths(
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
      "sourceText": "原文",
      "translatedText": "譯文",
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
| `createProject()`／`chooseSourceDirectory()` | 以來源目錄建立專案；既有目錄則切換並重掃 |
| `switchProject(projectID)` | 切換目前專案 |
| `renameProject(name)` | 修改目前專案顯示名稱 |
| `rescanSourceDirectory()` | 重新掃描目前來源 |
| `chooseOutputDirectory()` | 選取輸出目錄並同步 `.str` |
| `setPageSelection(pageIDs, activePageID)` | 同時設定批次選取與中央畫布頁面 |
| `selectAllPages()`／`clearPageSelection()` | 全選或清除批次選取 |
| `runBatch(operation, pageIDs)` | 將明確的頁面集合加入遮罩、翻譯、合成或完整處理佇列 |
| `detectMasks(scope)` | `selected` 或 `all` 的步驟二 |
| `translate(scope)` | `selected` 或 `all` 的步驟三 |
| `compose(scope)` | `selected` 或 `all` 的步驟四 |
| `runFullPage(scope)` | 保留的一鍵完整頁／全部頁面 |
| `retryFailedBatchJob(jobID)` | 以原操作重新排入該工作的失敗頁面 |
| `clearFinishedBatchJobs()` | 清除已完成、失敗或取消的工作紀錄 |
| `upsertGlossaryEntry(sourceTerm, translations, entryID, note)` | 新增或更新一詞對多語言詞條 |
| `removeGlossaryEntry(entryID)` | 移除目前專案的詞條 |
| `createMaskRegion(pageID, bounds)` | 新增區域，回傳 `{ regionID }` |
| `appendMaskStroke(pageID, regionID, mode, diameter, points)` | 添加或擦除遮罩 |
| `undoMaskStroke(pageID, regionID)` | 復原該區域最後一筆遮罩 |
| `removeRegion(pageID, regionID)` | 移除區域 |
| `updateRegion(pageID, regionID, changes)` | 更新文字、位置、字型、字級及排字設定 |

命令 Promise 代表 Native 已接受命令。長工序的實際狀態、進度及結果由 `window.MangaKitchenNative.receiveState` 持續推送。

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
| `mangakitchen.page.detect_masks` | 步驟二 |
| `mangakitchen.page.translate` | 步驟三 |
| `mangakitchen.page.compose` | 步驟四 |
| `mangakitchen.page.run_full` | 一鍵完整頁或批次完整處理 |
| `mangakitchen.region.create` | 新增區域 |
| `mangakitchen.region.update` | 修改文字／位置／字型／字級 |
| `mangakitchen.region.remove` | 移除區域 |
| `mangakitchen.mask.add_stroke` | 添加或擦除遮罩筆劃 |
| `mangakitchen.mask.undo_stroke` | 復原最後一筆遮罩 |

四個頁面工具的 `page_ids` 可省略；省略或傳空陣列代表工作區全部頁面。長工序若收到 MCP `_meta.progressToken`，會發送 `notifications/progress`。MCP 的 request cancellation 會傳遞至 Swift Task 與模型 Pipeline。

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
