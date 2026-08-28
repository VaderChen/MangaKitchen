# 漫畫廚房（MangaKitchen）翻譯／上色工作流與 API 契約

## 設計目標

工作流由四個可獨立執行、可重做、可持久化的階段組成。HTML/JavaScript Bridge、Swift App 與 MCP server 都呼叫相同的 `ComicTranslationPipeline`，不各自實作區域辨識、翻譯或合成演算法。

```text
1. scan directory
      ↓ ComicPage[]
2. Core ML dialogue BBOXes → glyph mask refinement ⇄ edit mask strokes
      ↓ DialogueRegion[]（未確認原文）+ dialogue-mask.png + 去字校對預覽 + page.str
3. bundled OCR/VLM transcription → multimodal/Agent translate + auto layout ⇄ edit text/style
      ↓ page.str + translation preview.png
4. save output
      ↓ copy confirmed translation preview to translated page.png
```

一鍵模式不是第五套流程。`runFullPage` 只依序呼叫步驟二、三、四；步驟一提供已掃描的頁面列表。

步驟二固定使用內建氣泡分割與原圖像素精修，不需要 PP-OCR 文字偵測或 `imageToText` 模型，也不會因 OCR／VLM 偏好而改變遮罩。步驟三的原文抽取才依專案選項分流：PP-OCR 以 Medium Det 切欄後逐行辨識，VLM 則沿用整區轉錄；翻譯、可選二次校稿與語意 QA 依專案選項使用純文字 `textToText` 或多模態 `imageToText`。純文字路徑只接收已抽出的原文，多模態路徑才讀取頁面語境；翻譯模型可在設定中個別選擇。DFlash 會套用於相容的 Qwen3／Qwen3.5 純文字 target，以及 Qwen3-VL／Qwen3.5-VL 完成視覺 prefill 後的多模態 target；其他 VLM 安全回退標準生成。

上色是另一套四步驟流程：選頁、反對話框遮罩、DDColor 預覽、儲存輸出。上色優先使用已存在的翻譯輸出，否則回退來源圖片；`ColorizationPageState`、預覽與輸出不覆寫翻譯的 `stage`、`progress`、`translationPreviewURL` 或 `outputURL`。目前 DDColor 只使用模型預設推論，`colorizationColorRange` 與 `colorizationMode` 僅保留專案欄位，對應介面卡片目前停用，契約不宣稱它們會影響推論。

## 專案、複選與批次規則

- 一個來源目錄對應一個 `projectID`，各自保存來源、輸出、處理設定、頁面與模型目錄。
- `selectedPageID` 是中央畫布顯示的單一作用中頁面；`selectedPageIDs` 是批次命令集合，兩者不可混為同一狀態。
- Command 點擊切換個別選取，Shift 點擊加入連續範圍；搜尋或狀態篩選只改變列表顯示，不會隱式刪除既有頁面。
- `BatchJob` 固定保存建立當下的 `projectID`、`operation`、`pageIDs` 與是否強制重算，執行途中切換專案會被阻止。
- GPU 模型工作使用單一循序佇列；新工作可以排隊，但不會取消正在執行的前一筆工作。模型只在實際使用時載入；同模型 ID／capability／canonical path 直接重用，同 capability 的並行載入會序列化。
- 載入大型模型前會讀取 unified-memory 使用率；超過壓力門檻時先釋放其他 runtime，但保留偏好路徑供下次延遲載入。
- GGUF 與 Safetensors／MLX checkpoint 是並存格式。GGUF 正式載入只走 MLX 原生 loader；正式 App 預設以 `group64`、`quality` profile 直接從 GGUF raw block 建立 MLX 權重：`Q4_0`／`Q4_1`／`Q1_0`／`Q2_0`／`Q2_K`／`Q3_K`／`Q4_K` 目標為 `INT4`，`Q8_0`／`Q5_K`／`Q6_K` 目標為 `INT8`，不先建立 `group32` 再轉換。`speed` profile 才會把 Q5_K／Q6_K 二次量化為 `INT4`；它可能降低品質，預設不啟用。GGUF F32／F16 compute 權重會轉成 BF16，只有 Qwen3.5 `blk.N.ssm_a`（`linear_attn.A_log`）保留 F32，mmproj 會沿用相同 group size。其他 GGUF tensor type 會在 inspect、manifest 推斷與 runtime 選檔時拒絕。loader 優先使用 GGUF 內嵌 metadata 與 tokenizer，外部 `config.json`、`tokenizer.json`、`tokenizer_config.json` 僅作後備；完整 metadata 的純文字模型可只放單一 `.gguf`，多模態模型仍需配對的 `mmproj` 與 processor 資訊。
- App 非正常結束後，原本為 `queued` 或 `running` 的紀錄會復原為 `cancelled`，不會未經確認自動重跑模型。
- 每個等待 DLG 都顯示從開啟起算的累計時間（`MM:SS`）；逐區翻譯另顯示目前區域／總區域，進度條仍使用頁面與批次進度。

### 逐區處理與進度

- 步驟三的 OCR 辨識與多模態翻譯都以區域為獨立工作單位。單一區域的裁切、模型推論、回應解析或翻譯失敗時，該區保留原有 `DialogueRegion`，其他區域仍會繼續；`CancellationError` 不會被吞掉，取消工作仍會停止整體佇列。
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

`DialogueStyle` 除字型、字級、字重與書寫方向外，也保存 `textAlignment`、`textColorHex`、`strokeColorHex`、`strokeWidth`、`opacity`、`rotationDegrees` 與 `isVisible`。WebUI、HTML PNG 排版與 HTML 分層 PSD 必須消費同一份樣式，不得各自建立不同預設。

全域設定的 `defaultOutputDirectoryPath` 是新專案的預設輸出根目錄；尚未有專案輸出設定時，App 會在此根目錄下建立以專案名稱命名的子目錄，再把輸出寫入其中。不會覆寫既有專案的 `outputDirectoryURL`。`selectionColorHex` 保存 WebUI 畫布的選取框顏色，僅影響介面顯示，不會寫入頁面像素或 `.str`。

`TranslationQualityOptions` 預設啟用整頁語境、翻譯 QA 與直譯稿保存，二次校稿預設關閉，長度策略為 `balanced`。所選多模態模型第一階段一次讀取整頁有序區域與圖片語境，產生直譯稿、顯示譯文、語氣與信心；若整頁回覆遺漏區域，只對缺少 UUID 執行一次有界補翻。啟用二次校稿時，第一階段初稿會先寫入 `.str`、專案快照並產生翻譯預覽，第二階段才以一次整頁請求統一稱謂、詞表、數字、否定、語氣與長度。校稿把既有 `sourceText` 視為不可重抽取的正式原文，只校正整體譯文，不執行逐區 OCR 或逐區重翻；取消校稿會保留已提交初稿。UI 明確顯示「二次校稿」而不是再次顯示翻譯。QA 會檢查缺譯、詞表、數字、長度及低信心，結果保存於 `.str`，不只存在記憶體。

- `NormalizedPoint` 與 `NormalizedRect` 都以原圖左上角為原點，範圍為 `0...1`。
- 遮罩畫筆的 `diameter` 是相對於原圖短邊的比例，範圍為 `0.001...1`。
- `MaskStroke.mode` 為 `add` 或 `erase`，筆劃依保存順序套用。
- `rawSourceText` 保留 OCR、VLM、MCP Agent 或人工最初提供的原文；`sourceText` 是目前供詞表比對與翻譯使用的來源文字。
- `mcpExtractedSourceText` 只保存 MCP Agent 回傳的原文抽取結果；本機 VLM 的直譯稿不會填入此欄位，WebUI 只有在 MCP 實際回傳內容時才顯示「MCP 抽取原文」。
- `ocrResults` 以 OCR 模型 ID 分開保存各模型的候選 `text`、信心、文字行與正規化座標；當 `sourceText` 空白時，預設 OCR 候選會被採用為翻譯原文，但不覆寫已確認原文、`bounds`、`maskPolygons` 或人工筆劃。複合 OCR 與多模型校稿融合尚未啟用。
- `ocrTextRefined` 是為了既有 `.str` 相容而保留的欄位；`true` 代表來源文字已由 VLM、MCP Agent 或人工確認。單模型 OCR 候選被採用時不會冒用此標記。
- **GUI 路徑**：步驟二一律先由 `MangaBubbleSegmentationCoreMLRuntime` 產生對話框 BBOX 與氣泡形狀，再固定以原圖像素收斂為遮罩；不會呼叫 Medium Det 或 VLM。步驟三才依「原文抽取方式」選擇 `OCRRegionTextRecognitionService` 逐欄 OCR 或 `VLMRegionTranscriptionService` 整區轉錄；辨識合併只採用原文與 OCR 候選，不覆寫座標與遮罩。翻譯、可選二次校稿與語意 QA 依「翻譯模型」選用 `textToText` 或 `imageToText` runtime。
- **MCP 路徑**：App 先完成區域、像素遮罩與去字背景，再由 `prepare_agent_task` 將原圖及完整遮罩 JSON 一次交給可讀圖的多模態 Agent；Agent 只依既有 `region_id` 抽取原文、翻譯與決定排版，最後以 `submit_agent_result` 一次回寫並建立步驟三預覽。只有使用者要求輸出時才以 `page.render` 儲存步驟四結果。MCP 不接受 Agent 修改區域或遮罩，也不呼叫 App 內建 VLM 翻譯。詳見〈標準 MCP〉。
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
| `maskReady` | 步驟二區域、像素遮罩及去字背景已保存 | 人工修遮罩、翻譯 |
| `translationReady` | 步驟三原文、譯文、排版與完整預覽已保存 | 人工修文、儲存輸出 |
| `completed` | 已輸出合成圖 | 重做任一步驟 |
| `failed` | 最近命令失敗 | 修正問題後重做該步驟 |

`detectingText`、`translating`、`composing` 是執行中狀態。舊版的 `recognizing`、`masking`、`restoringBackground`、`typesetting` 僅保留工作區向後相容。

上色使用獨立的 `ColorizationProcessingStage`：`pending`、`maskReady`、`colorizing`、`previewReady`、`exporting`、`completed`、`failed`。其進度固定保存在 `ComicPage.colorizationState`，不得借用翻譯頁面的狀態欄位。

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

let colorizationPreviewURL = try await pipeline.colorize(
    page: page,
    inputURL: translatedOutputURL ?? page.sourceURL,
    regions: page.regions,
    strokes: page.colorizationMaskStrokes ?? [],
    progress: colorizationProgress
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
      "mcpExtractedSourceText": null,
      "ocrResults": {
        "ppocrv6-medium-rec": {
          "modelID": "ppocrv6-medium-rec",
          "text": "原文候選",
          "confidence": 0.91,
          "lines": [],
          "writingDirection": "vertical"
        }
      },
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
| `updateGlobalSettings(settings)` | 更新完整全域設定；包含色系、框選顏色、資料位置、預設輸出位置、偏好模型與 MCP 網路設定 |
| `chooseDataDirectory()` | 開啟原生資料目錄選擇面板；回傳 `{ path }`，套用後需重新啟動 |
| `choosePreferredModelDirectory(capability)` | 選取並驗證 `imageToText`、`imageToImage`、`imageColorization` 或 `superResolution` 模型目錄 |
| `chooseModelDownloadDirectory(capability)` | 選取多模態、上色或超高解析度模型儲存根目錄；若直接選到支援的既有模型，會回傳其版本 |
| `downloadPreferredModel(capability, variantID)` | 從 Hugging Face 下載所選多模態、上色或超高解析度模型；已存在時不重複下載 |
| `createProject()`／`chooseSourceDirectory()` | 從圖片、資料夾、ZIP／CBZ、RAR／CBR 或 PDF 建立受管理專案 |
| `appendPages()` | 將相同支援格式追加到目前專案；必要時先把外部來源轉成受管理專案 |
| `switchProject(projectID)` | 切換目前專案 |
| `deleteProject(projectID)` | 從專案索引移除專案，不刪除外部來源檔 |
| `renameProject(name)` | 修改目前專案顯示名稱 |
| `rescanSourceDirectory()` | 重新掃描目前來源 |
| `resetPages(pageIDs)` | 清除指定頁面的處理狀態與衍生產物，保留來源頁 |
| `renamePage(pageID, name)` | 修改頁面顯示名稱，不改寫來源檔名 |
| `movePage(pageID, offset)` | 依 `offset` 調整頁序 |
| `removePages(pageIDs)` | 從專案排除頁面，不刪來源；重掃時保持排除 |
| `chooseOutputDirectory()` | 選取只存放最終 PNG 的輸出目錄；`.str` 不會隨之移動 |
| `exportPSD(pageIDs)` | 選取輸出資料夾，以目前 HTML/CSS 合成圖與逐文字 Raster Layer 匯出 PSD |
| `setPageSelection(pageIDs, activePageID)` | 同時設定批次選取與中央畫布頁面 |
| `selectAllPages()`／`clearPageSelection()` | 全選或清除批次選取 |
| `runBatch(operation, pageIDs, forceRecalculation)` | 將明確頁面集合加入 `detectMasks`、`translate`、`extractText`、`retranslate`、`superResolve`、`compose`、`colorize`、`colorizationCompose` 或完整處理佇列；重算時設為 `true` |
| `detectMasks(scope)` | `selected` 或 `all` 的步驟二 |
| `translate(scope)` | `selected` 或 `all` 的步驟三 |
| `extractText(scope)` | 以目前區域與遮罩重新抽取原文；保留步驟二產物並清除依賴原文的譯文，完成後等待 `retranslate` |
| `retranslate(scope)` | 沿用目前 `sourceText`，強制重新翻譯與建立步驟三預覽，不重做文字抽取或遮罩 |
| `reextractRegion(pageID, regionID)` | 只重新抽取並翻譯指定區域，保留其他區域、遮罩與去字背景，完成後重繪整頁預覽 |
| `superResolve()` | 對選取頁面的乾淨背景執行已載入的原生 2× 或 4× 超高解析度模型 |
| `compose(scope)` | `selected` 或 `all` 的步驟四；只儲存步驟三已完成的翻譯預覽 |
| `runFullPage(scope)` | 保留的一鍵完整頁／全部頁面 |
| `retryFailedBatchJob(jobID)` | 以原操作重新排入該工作的失敗頁面 |
| `clearFinishedBatchJobs()` | 清除已完成、失敗或取消的工作紀錄 |
| `upsertGlossaryEntry(sourceTerm, translations, entryID, note)` | 新增或更新一詞對多語言詞條 |
| `removeGlossaryEntry(entryID)` | 移除目前專案的詞條 |
| `createMaskRegion(pageID, bounds)` | 新增區域，回傳 `{ regionID }` |
| `appendMaskStroke(pageID, regionID, mode, diameter, points)` | 添加或擦除遮罩 |
| `undoMaskStroke(pageID, regionID)` | 復原該區域最後一筆遮罩 |
| `redoMaskStroke(pageID, regionID)` | 重做該區域最後一筆已復原遮罩 |
| `appendColorizationMaskStroke(pageID, mode, diameter, points)` | 添加或擦除上色用反對話框遮罩 |
| `undoColorizationMaskStroke(pageID)`／`redoColorizationMaskStroke(pageID)` | 復原或重做上色遮罩畫筆 |
| `resetColorizationPages(pageIDs)` | 清除選取頁的上色畫筆、預覽、輸出與獨立進度，保留翻譯產物 |
| `undoRegionEdit(pageID)`／`redoRegionEdit(pageID)` | 復原或重做該頁文字區域編輯；每頁最多保留 50 份快照 |
| `removeRegion(pageID, regionID)` | 移除區域 |
| `moveRegion(pageID, regionID, offset)` | 調整閱讀順序及 PSD 文字圖層順序 |
| `updateRegion(pageID, regionID, changes)` | 更新文字、`translationAnchor` 譯文中心點、字型、字級及排字設定 |
| `updateSettings(changes)` | 更新專案處理設定；`textLocalizationMethod` 可為 `ppocrv6MediumDet`（預設）或 `vlm`，`eraseColorHex` 可指定 `AUTO` 或步驟二去字底紙色，`translationQuality` 可控制整頁語境、校稿、品質檢查、直譯稿、長度策略與風格指南 |

命令 Promise 代表 Native 已接受命令。長工序的實際狀態、進度及結果由 `window.MangaKitchenNative.receiveState` 持續推送。

`translationAnchor` 使用左上角原點的 0...1 正規化座標，只改變譯文 Layer 與最終排版位置，不會改動來源文字 `bounds`、對話框或遮罩。像素遮罩覆蓋檢查只提供警告；人工遮罩或目前自動遮罩仍可繼續翻譯與合成，不會作為硬性阻擋條件。

`WebPage` 以 `pixelWidth`／`pixelHeight` 表示原圖尺寸；套用超高解析度後另回傳 `superResolutionApplied`、`superResolutionScale`、`superResolutionPixelWidth`、`superResolutionPixelHeight` 與 `superResolvedBackgroundPreviewURL`。中央畫布必須使用 SR 實際尺寸計算內容座標，但檢視倍率仍以目前可視畫布與顯示尺寸計算，不能把 SR 倍率直接乘入 UI zoom。尺寸旁的 `*` 只代表目前預覽來自 SR 產物。

PSD 匯出以目前頁面順序產生 `序號_頁名.psd`。合併預覽、每個可見或隱藏文字圖層都由 `HTMLDialogueTypesetter` 使用同一份樣式渲染；尺寸相符時加入 `Clean Background` 與預設隱藏的 `Original Source`。PSD 文字目前是可分層的透明 Raster Layer，不宣稱為 Photoshop 原生可編輯文字圖層。

介面語言與專案的 `targetLanguageCode` 是兩個獨立設定。改變介面語言只影響 WebUI、原生目錄選擇面板與 MCP menu bar，不會修改譯文語言或專有名詞的對照目標。

## 標準 MCP

`MangaKitchen` 使用官方 Swift MCP SDK `0.12.1`，提供 MCP `2025-11-25` 的標準 Streamable HTTP transport、tools、resources、resource templates、取消與 progress notification；目前工作流契約版本為 `1.3.0`。MCP adapter 在 GUI process 內運作，但 JSON-RPC 或 transport 型別不會進入漫畫核心。

啟動參數：

| 參數 | 行為 |
|---|---|
| 省略 | 啟動 GUI，MCP 是否啟動由已保存的設定決定；初始預設關閉 |
| `--mcp=off` | 啟動 GUI，本次啟動停用 MCP |
| `--mcp=on` | 啟動 GUI、MCP listener 與 macOS menu bar 狀態項目 |
| `--mcp` | `--mcp=on` 的簡寫 |
| `--mcp-port=12080` | 覆寫本次啟動的 MCP listener port；設定預設為 `12080` |

GUI 一定會建立。MCP 開啟後即使關閉主視窗，App 與 MCP listener 仍會常駐；可由 menu bar 選單重新開啟主視窗、複製 MCP 網址或完整結束 App。布林值也接受 `true/false`、`1/0` 與 `yes/no`；其他值會直接回報參數錯誤。

### Tools

| Tool | 對應功能 |
|---|---|
| `mangakitchen.contract.describe` | 讀取契約版本、座標系、限制、nullable 欄位與不變量 |
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
| `mangakitchen.workspace.pages` | 以 `workflow=translation|colorization` 查詢每頁產物狀態；`nextAction` 只是摘要，不會授權 Agent 自行執行 |
| `mangakitchen.page.inspect` | 讀取完整頁面、翻譯／上色產物、上色輸入來源、可用操作與 opaque `revision` |
| `mangakitchen.page.update` | 帶入 `expected_revision` 更新頁名或頁序 |
| `mangakitchen.page.prepare_agent_task` | 主要入口；一次回傳指定頁原圖與步驟二遮罩 JSON |
| `mangakitchen.page.submit_agent_result` | 帶入工作包 revision，一次回寫全部區域並建立步驟三排字預覽 |
| `mangakitchen.page.render` | 步驟四只將既有步驟三預覽儲存到輸出目錄 |
| `mangakitchen.page.colorize` | 上色步驟三；以已載入的 `imageColorization` 模型建立預覽 |
| `mangakitchen.page.prepare_colorization_task` | 一次回傳實際上色輸入與反對話框遮罩，交由 Agent 自行上色 |
| `mangakitchen.page.submit_colorization_result` | 驗證 Agent 完整頁面結果、強制套用保護遮罩並寫回上色預覽 |
| `mangakitchen.page.render_colorization` | 上色步驟四；只把既有上色預覽儲存到輸出目錄 |
| `mangakitchen.page.reset_colorization` | 清除本頁上色畫筆、預覽、輸出與獨立進度，保留翻譯產物 |
| `mangakitchen.region.batch_update` | 原子套用 1...64 個區域 partial patch |
| `mangakitchen.region.reorder` | 以完整 ID 陣列更新閱讀與 PSD 圖層順序 |

舊的 `page.detect_masks`、`page.supplement_regions`、`page.translate`、`page.compose`、`page.run_full` 與逐筆 `region.create/update/remove` handler 只保留程式相容性，不再列入 MCP `tools/list`，避免 Agent 自行拆解流程或誤刪、重建區域。契約化的 `region.batch_update` 與 `region.reorder` 仍是公開工具。

### 單頁工作包契約

MCP 初始化與工具清單只描述能力，不代表應立即操作資料。除非使用者明確要求，Agent 不得清除、重新掃描、重建、刪除、合併或新增區域。重疊區域可能是合法的氣泡／文字配置，不能作為自動清理依據。

標準流程固定為：

1. App 已載入步驟一原圖，並由使用者在 App 完成步驟二區域、像素遮罩與去字背景。
2. 可讀取圖片的多模態 Agent 呼叫 `page.prepare_agent_task(workspace_id, page_id)`。
3. Tool result 的 image content 直接包含原圖；structured content 的 `regionData` 內嵌所有區域、BBOX、氣泡形狀、像素遮罩、筆刷與現有排版資料，也同時提供目標語言、閱讀順序與專有名詞。
4. Agent 必須實際讀取附帶原圖，再只依既有 `region_id` 處理文字：`sourceText` 與 `translatedText` 若已有內容就是待校稿草稿，必須對照原圖確認或修正；空白欄位才重新抽取或翻譯。不得降級成只讀文字欄位的文生文流程。同時檢查並必要時調整 `translationAnchor`、`translationBounds`、`fontSize`、`automaticFontSize`、`fontWeight` 與 `writingDirection`。
5. Agent 呼叫 `page.submit_agent_result`，一次送回本頁全部區域。
6. App 驗證回傳 `region_id` 集合與步驟二完全一致，保留遮罩與去字背景、更新內部專案資料，並建立步驟三排字預覽；只有使用者要求輸出時才另呼叫 `page.render`。

`prepare_agent_task` 不會自動建立、修復或重跑步驟二；任一區域、遮罩或去字背景缺少時都停止並要求回 App 完成。若已有抽取文字、翻譯或排版，這些資料會完整包含在 `regionData.entries` 中，交由 Agent 校稿與調整後回傳。所有 Agent 必要資料均包含於單次 tool result，Agent 不得搜尋、讀取或建立 `.str` 檔案，也不需額外讀取 page resource。

`prepare_agent_task` 與 `page.inspect` 都會回傳 opaque `revision`。所有寫入工具必須原樣放入 `expected_revision`；如果 GUI 或另一個 Agent 已修改頁面，server 會整筆拒絕並回傳目前 revision，呼叫端必須重新 inspect，不能自行遞增或猜測 revision。

`submit_agent_result.regions` 的格式如下，座標皆為左上原點的 0...1 正規化值：

```json
{
  "workspace_id": "<uuid>",
  "page_id": "<uuid>",
  "expected_revision": "page-<opaque-token>",
  "regions": [
    {
      "region_id": "<existing-region-uuid>",
      "source_text": "欲しいの？",
      "translated_text": "你想要嗎？",
      "literal_translated_text": "你想要它嗎？",
      "speaker_id": "speaker-1",
      "tone": "試探、口語",
      "translation_confidence": 0.92,
      "translation_qa_flags": [],
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

`region.batch_update` 是 partial patch：省略欄位代表沿用；只有 `translation_anchor`、`translation_bounds`、`bubble_bounds` 與 `font_size` 接受 `null` 清除。完整批次會先驗證 revision、ID、有限數值、顏色與範圍，任一 patch 無效時不會部分寫入。只有幾何欄位變更才重建遮罩；文字與樣式更新保留既有像素遮罩。

### 上色 MCP 契約

1. 先以 `workspace.pages(workflow: "colorization")` 或 `page.inspect` 讀取上色待辦、`colorization.stage`、獨立進度及實際產物。
2. 上色步驟二必須已在 App 完成反對話框遮罩；API 不會隱式重跑翻譯遮罩或區域偵測。
3. Agent 路徑呼叫 `page.prepare_colorization_task`，單次 tool result 依序取得工作包 JSON、實際上色輸入與反對話框遮罩；Agent 可使用自身 Provider 完成上色，不需要載入 App 本機模型。
4. Agent 以工作包 revision 呼叫 `page.submit_colorization_result`，透過 `result_image_base64` 與 `result_mime_type` 一次回寫 PNG、JPEG、HEIC、TIFF 或 WebP 完整頁面。App 會限制解碼後圖片為 20 MiB，以配合 32 MiB HTTP request 上限，並驗證像素尺寸、正規化為 PNG、再次套用遮罩，保證黑色保護區使用原輸入像素。
5. 本機替代路徑可先用 `model.load` 載入 capability 為 `imageColorization` 的 DDColor manifest，再帶入最新 `expected_revision` 呼叫 `page.colorize`。
6. 兩條路徑都優先讀取既有 `output`，沒有翻譯輸出才讀 `source`；`page.inspect.colorization.inputSource` 與 `inputURI` 會明確回報實際選擇。
7. 使用者要求輸出時才帶入新 revision 呼叫 `page.render_colorization`；需清除重來時呼叫 `page.reset_colorization`。

`page.colorize`、`page.submit_colorization_result`、`page.render_colorization` 與 `page.reset_colorization` 都使用 optimistic concurrency。DDColor 本機路徑目前固定採模型預設推論，MCP 不接受 `colorizationColorRange` 或 `colorizationMode`，避免宣稱無效參數已生效；Agent 路徑則由 Agent 自行選擇模型與 Provider，但仍必須遵守工作包尺寸、遮罩與分階段輸出契約。

### MLX 權重格式

`mangakitchen.model.load` 可載入使用 `.gguf` 權重的本機 MLX 純文字或多模態模型。唯一的 Swift `GGUFStoragePolicy` 會把 `Q4_0`／`Q4_1` 目標為 `INT4`、`Q8_0` 目標為 `INT8`；Unsloth Dynamic `Q4_0` 內混用的 `Q4_1` 也可直接載入。`Q1_0`／`Q2_0`／`Q2_K`／`Q3_K`／`Q4_K` 依來源 block 直接產生 MLX `INT4` 的 `wq/scales/biases`；quality profile 的 `Q5_K`／`Q6_K` 產生 `INT8`，speed profile 才改產生 `INT4`，不再先配置整顆 `Float16` 反量化 tensor。正式 App 的 `group64` 會對所有需量化的來源型別直接從 GGUF raw block 產生目標群組，不經 `group32` 中間結果；`Q8_K` 與其他未列入能力表的型別則明確回報不支援，不會在下載或載入十幾 GB 後才失敗。compute dtype 以 BF16 為主，只有 Qwen3.5 `blk.N.ssm_a` 保留 F32；mmproj 會沿用相同 group size。llama.cpp bridge 只在 `Tools/GGUFBackendPOC` 供 parser 對照，正式 App 不依賴外部執行檔。loader 會先讀 GGUF 內嵌的 model metadata、vocabulary、merges 與 special tokens；外部 `config.json`、`tokenizer.json`、`tokenizer_config.json` 只作 fallback。若 manifest 未指定 `weightsFile`，目錄只能有一個主 GGUF 權重檔。

若在「設定 → 模型 → 翻譯」或「多模態」開啟 DFlash，文字與多模態 runtime 都會在主模型完成載入後，從主模型同一個模型根目錄自動尋找並驗證 Draft 與 target 的 Qwen3／Qwen3.5 架構、層數、hidden size 與 vocabulary；驗證失敗只停用 DFlash，不會阻斷主模型。Qwen3-VL／Qwen3.5-VL 會以視覺 embedding 與 M-RoPE 完成首輪 prefill，再使用相同 DFlash verify loop；DFlash 使用 target 原本的 Metal／MLX context 與 tokenizer。其他 VLM、音訊輸入、rotating／量化 target KV cache 會維持標準生成。

可辨識的 `FP8`（包含 `F8_E4M3`／`F8_E5M2` 變體）統一採 `INT8` 重新量化；一般 GGUF `F16`／`F32` compute 權重轉成 BF16，只有 Qwen3.5 `blk.N.ssm_a` 保留 F32。由於 llama.cpp 標準 GGUF 目前沒有獨立的 FP8 tensor type，Swift loader 仍會拒絕未知的 GGUF type，不會誤宣稱已能載入 FP8；`GGUFStoragePolicy.targetStorageType(for:)` 已固定 `quality` profile 的目標策略，`targetStorageType(for:profile:)` 可查詢速度 profile，待 parser 提供明確 encoding 後再接入實際解碼。

目前 GGUF 的 tensor 整理由 Metal GPU 執行：`Q4_0`／`Q4_1`／`Q8_0` 的原生資料重排，以及其他需轉換型別的目標群組量化，都透過 `MLXFast.metalKernel` 直接從 GGUF raw block 產生 MLX `wq/scales/biases`；scales／biases 以 BF16 輸出，`group64` 不會先建立 `group32` 再轉換。CPU 僅負責檔案 I/O、GGUF metadata 解析與模型結構建立，不再以 Swift 逐 byte 或逐 group 計算。`GGUFSmoke` 的 `measurement=load` 會記錄載入耗時與當下 process peak RSS，`measurement=generation` 會記錄首 token 延遲、prompt tokens/sec 與 generation tokens/sec。這些測量與 `Tools/GGUFBackendPOC` 的合成 fixture 只屬於開發驗證，不會成為 App 的 runtime 設定、品質門檻或固定效能承諾。

正式 runtime 不依賴 POC 的 C++ bridge、可執行檔、benchmark 數值或測試 fixture。主線只保留經能力檢查後的 MLX 原生 GGUF loader，並以 `GGUFStoragePolicy` 決定每個來源型別的材料化方式；POC 只作為可重跑的外部交叉驗證工具。

多模態 GGUF 的主模型與 `mmproj` 視覺投影檔是不可分開的配對。管理下載目錄會保留原本的 `lmstudio-community/Qwen3.8-27B-MLX-4bit` checkpoint，並另外提供 `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_0.gguf` 加上 `mmproj-F16.gguf` 的 GGUF 選項；必要的 `config.json`、tokenizer 與 processor 設定取自 `Qwen/Qwen3.8-27B`。下載器會先驗證兩個 repository 的指定檔案，只下載這組配對，不會下載同一 repository 內其他量化版本。

既有 Safetensors checkpoint 載入方式會保留：若模型目錄含有 Safetensors 且沒有指定 `weightsFormat: "gguf"` 或 GGUF 的 `weightsFile`，runtime 仍使用原本的 `LLMModelFactory`／`VLMModelFactory` checkpoint loader。只有指定 GGUF 或目錄沒有 Safetensors 時，才會進入 Swift 原生 GGUF 解析與 MLX 量化權重路徑。

### Resources

```text
mangakitchen://contract/current
mangakitchen://workspace/list
mangakitchen://workspace/current
mangakitchen://workspace/current/pages
mangakitchen://workspace/current/colorization-pages
mangakitchen://workspace/current/glossary
mangakitchen://workspace/{workspace_id}/capabilities
mangakitchen://page/{page_id}
mangakitchen://page/{page_id}/regions
mangakitchen://page/{page_id}/source
mangakitchen://page/{page_id}/mask
mangakitchen://page/{page_id}/output
mangakitchen://page/{page_id}/colorization-preview
mangakitchen://page/{page_id}/colorization-output
```

頁面 JSON 狀態以 text resource 回傳；原圖、遮罩、翻譯輸出與上色產物以 binary resource 回傳。標準翻譯 Agent 流程只使用 `prepare_agent_task` 的內嵌資料，不需要逐一讀取上述 resource。

### 啟動設定

```bash
swift build -c release --product MangaKitchen
```

先啟動 App：

```bash
.build/release/MangaKitchen --mcp=on
```

再將支援 Streamable HTTP 的 MCP client 指向下列 MCP 網址：

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

不同 MCP client 的設定欄位名稱可能不同。Listener 綁定 `0.0.0.0`，遠端 client 應以這台 Mac 的實際 LAN 位址組合 MCP 網址，並先在設定 DLG 將單一 IP 或 CIDR（例如 `192.168.1.0/24`）加入白名單。白名單使用 TCP socket 的來源位址，不信任 `X-Forwarded-For`；空白名單會拒絕全部 request。服務目前仍是明文 HTTP，若跨越受信任區網，仍應另加 TLS、身分驗證與 macOS 防火牆規則。
