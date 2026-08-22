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

來源目錄是專案的邊界。專案索引位於 `Projects/library.json`，各專案使用 `Projects/<project-id>/project.json`；`ProjectGlossary` 也保存在該專案快照內，不會跨專案共用。每張 `.str` 固定作為原圖 sidecar 放在原圖同一目錄，輸出目錄只保存最終 PNG。全域 `defaultOutputDirectoryPath` 只作為新專案的輸出根目錄，實際會建立安全化的專案名稱子目錄；既有專案的明確 `outputDirectoryURL` 不會被覆寫。讀到舊版位於輸出目錄或 `Projects/<project-id>/StringTables` 的 `.str` 時，會複製到原圖旁並保留舊檔。舊版單一 `Workspace/workspace.json` 只讀取一次並遷移，不直接覆寫或刪除。

從圖片、資料夾、ZIP／CBZ、RAR／CBR 或 PDF 建立專案時，`ManagedImportService` 會先把頁面複製、解包或點陣化到 Application Support 的 `Imported/<uuid>`。因此原始壓縮檔、PDF 或外部圖片移動後，專案頁面仍可讀取。專案 JSON 仍採原子寫入與 `.bak` 回復策略。

既有專案可繼續追加上述來源；頁面名稱與順序屬於專案 metadata，不改寫來源檔。從專案移除頁面時只保存排除的相對路徑，不刪除託管或外部來源，因此重掃後也不會把已移除頁面自動加回。

翻譯階段先以 `targetLanguageCode` 解析詞條，再依本頁 `sourceText` 篩選實際出現的專有名詞，最後只把命中的 `ResolvedGlossaryTerm` 注入 VLM Prompt。這可避免大型專案將無關詞條全部送進模型，同時讓 GUI、批次流程與 MCP 使用同一套語言選擇規則。

## 四階段處理資料流

```text
1. ComicDirectoryScanner
   └─ 遞迴掃描、自然排序、保留相對路徑

2. MangaBubbleSegmentationCoreMLRuntime + MangaBubbleMaskRegionDetector + MangaTextMaskRefiner + PageBackgroundRestoring
   ├─ 有 `imageToText` 模型時，內建 Core ML 氣泡分割模型優先以 Apple Neural Engine 產生對話框 BBOX 與形狀，再交給文字模型辨識
   ├─ 沒有 `imageToText` 模型時跳過自動偵測，建立同尺寸全黑 `dialogue-mask.png`，由 WebUI 進入手動畫筆模式
   ├─ 氣泡 instance mask 裁切 BBOX，保存 `bubbleMaskPolygons` 與供排版使用的 `bubbleLayoutBounds`
   ├─ Otsu／連通元件把搜尋結果縮減成字形級像素遮罩，並將文字 bounds 同步縮到字形外框
   └─ 像素層膨脹 + add/erase 畫筆 → 二值 `dialogue-mask.png` + 指定底紙色／CPU／GPU 去字背景 + 專案文字狀態；MCP 直接提供這些完成產物給 Agent

3. ImageToTextGenerating／OCRRegionTextRecognitionService／外部 MCP Agent + ImageSuperResolving（選用）+ HTMLDialogueTypesetter
   ├─ VLMRegionTranscriptionService 在既有 BBOX 內逐區分類、轉錄並排除擬聲字等非翻譯項目；本機 OCR 只追加 `ocrResults` 候選，不覆寫 VLM 原文、座標或遮罩
   ├─ AppStore 支援整頁重新抽字、重新翻譯與單區重新抽取／翻譯；重新抽字不重建步驟二產物
   ├─ GUI 使用 VLMRegionTranslationService 以整頁語境產生草稿與 QA；MCP 以單頁工作包一次提供原圖、品質參數與遮罩 JSON，Agent 一次回傳全部區域
   ├─ MLX Real-ESRGAN 2×／Core ML Anime 4× 寫入獨立 SR 背景，並保護步驟二已去字的遮罩像素
   └─ 依實際背景尺寸應用 HTML/CSS 固定或自動字級、橫排／直排 → `translated.png` 步驟三預覽／分層 PSD

4. Save Output
   └─ 只將已確認的步驟三 `translated.png` 原子寫入輸出目錄；不重跑任何模型、遮罩、去字、SR 或排字
```

編輯器對文字區域保存每頁最多 50 份記憶體內 undo／redo 快照；文字圖層可調整順序、顯示、透明度、旋轉、對齊、文字顏色與 CSS 描邊，每次成功修改仍會寫回 `.str` 與專案快照。中央畫布的檢視座標與原圖座標分離：可雙軸平移，滾輪縮放以可視畫布中心為錨點，適合視窗與 `1:1` 只改變檢視倍率，不改動區域正規化座標。PSD 匯出不另建 Core Text 排版器：合併預覽與每個文字圖層都由同一份 HTML/CSS 逐層渲染，再封裝為 PSD Raster Layer，並在尺寸一致時附加乾淨背景與隱藏原圖。

翻譯 Provider 不直接擴張為 App 內建清單。MangaKitchen 將 MCP 工作包、細緻排版欄位、進度與可恢復狀態視為主要擴充邊界；外部 Agent 可自行使用其支援的本機或雲端 Provider，再透過穩定 MCP 契約回寫結果。

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
- `CoreMLSuperResolutionRuntime`：讀取模型原生輸入／輸出尺寸決定倍率；目前 Anime 512 模型為獨立 4× 權重，不再固定縮回 2×。
- `MLXRealESRGANSuperResolutionRuntime`：載入 `mlx-community/Real-ESRGAN-x2plus` 的獨立 FP16 RRDBNet 權重，執行原生 2× 超解析；不載入、不重用也不降採樣 4× Anime 模型。
- `QwenExternalImageEditRuntime`：以 JSONL 監看獨立 Swift/MLX worker，傳遞進度、錯誤與取消訊號。
- `MaskedImageCompositor`：將生成候選圖縮放回原頁，再只採用 mask 白區，避免生成模型改動未授權區域。
- `MangaBubbleSegmentationCoreMLRuntime`：內建由 `manga109-segmentation-bubble` 匯出的 Core ML YOLO 分割模型。模型依 image constraint 進行方形 letterbox，優先採用 `cpuAndNeuralEngine`；輸出反算回原圖座標並經 NMS 產生 BBOX，若有 prototype 則同步解出 `bubbleMaskPolygons` 與 `bubbleLayoutBounds`。模型無法載入或推論失敗時，才由 `MangaBubbleCandidateDetector` 的封閉白色連通區演算法後備。
- `MangaBubbleMaskRegionDetector`：在步驟二將 Core ML BBOX 與氣泡形狀寫入 `DialogueRegion.bounds`、`bubbleBounds`、`bubbleMaskPolygons` 及 `bubbleLayoutBounds`，不載入或呼叫 VLM；`MangaTextMaskRefiner` 隨即依原圖像素將遮罩與文字 bounds 收斂到實際字形。
- `VLMRegionTranscriptionService`：在步驟三才將既有 BBOX 裁成候選卡片，由 VLM 逐區分類為 `title`、`dialogue`、`caption` 或 `ignore` 並轉錄文字。每區都有獨立例外處理；裁切、推論或 JSON 解析失敗時保留原 `DialogueRegion` 並繼續下一區。接受的候選保留原 ID、BBOX、像素遮罩與人工筆劃；擬聲字、頁碼、浮水印、人物與空白區不進入翻譯或最終合成。
- `PPOCRRecognitionRuntime`／`OCRRegionTextRecognitionService`：以 repository 內建的 macOS 14 Core ML recognizer 讀取既有 VLM 區域，將每個 OCR 模型的文字、信心、行框與方向寫入 `DialogueRegion.ocrResults`；OCR 是候選提供者，不是定位、遮罩或自動覆寫來源文字的 authority。若本機建置資源缺少模型，App 仍保留原本 VLM runtime。
- 外部 MCP Agent：`prepare_agent_task` 只在 App 步驟二的區域、遮罩與去字背景均完成時，一次傳送指定頁原圖與完整遮罩 JSON；Agent 依既有 `region_id` 抽取原文、翻譯及排版，再由 `submit_agent_result` 建立步驟三預覽。只有使用者要求輸出時才以 `page.render` 執行步驟四。Agent 不新增、刪除、合併或重建區域與遮罩。
- `MangaTextMaskRefiner`：先分析 Core ML BBOX 或 Agent 粗框；若已知 `bubbleMaskPolygons`，會先以氣泡形狀篩選元件。搜尋範圍不會直接成為遮罩，最後以 Otsu 閾值及八鄰域連通元件取得字形像素，並在像素層執行抗鋸齒遲滯與固定像素膨脹，再合併成二值遮罩矩形，避免向量描邊造成灰階毛邊；`bounds` 同步縮到未膨脹的字形外框。暗色背景上的亮字由系統覆蓋檢查回報，必要時由使用者在 App 內以畫筆修正。
- `VLMRegionTranslationService`：預設將整頁已確認的來源文字依閱讀順序一次送入模型；若整頁回覆遺漏部分 UUID，只逐區補翻遺漏區域，保留已成功的整頁結果。二次整頁校稿為可選且預設關閉；單區失敗會保留既有譯文並繼續。取消例外向外拋出以停止整體工作。
- `TranslationQualityOptions`：專案級控制整頁語境、可選二次校稿、QA、直譯稿保存、忠實／平衡／精簡長度策略與 4,000 字元風格指南。結果保存 `literalTranslatedText`、`speakerID`、`tone`、`translationConfidence` 與 `translationQAFlags`，人工改寫顯示譯文時會清除已過期的信心與 QA。
- `CPUBubbleCleaner`／`MetalBubbleCleaner`：步驟二的傳統去字後端。`eraseColorHex == AUTO` 時由修補器估算底紙色；指定固定底紙色時由 CPU 精確填色，並清除遮罩外兩像素內的近底色 JPEG／掃描 halo。同一文字區域的斷開筆畫共用單一底色，避免紙紋取樣變成字形斑點。
- `HTMLDialogueTypesetter`：將步驟三保存的 `translationBounds`、`translationAnchor`、字型、固定／自動字級、粗細及橫排／直排設定交給 WebKit；自動方向優先採用字形排列偵測結果，氣泡排版優先使用完全位於 `bubbleMaskPolygons` 內的 `bubbleLayoutBounds`。使用與 WebUI 相同的 HTML/CSS 與自動縮字演算法渲染背景及文字層，再輸出原圖像素尺寸的 PNG。GUI、批次與 MCP 共用此排版器，不再存在另一套 Core Text 輸出規則。
- `ComicTranslationPipeline`：只負責階段順序與產物路徑，不知道 UI。步驟二的 `SemanticRegionDetecting` 只需 Core ML BBOX／像素遮罩；GUI 步驟三可使用內建 VLM，MCP 步驟三則由單頁 Agent 工作包提供，不會呼叫 App 內建圖生文翻譯。`PageRegionProgress` 回報目前區域與總區域，`PagePipelineProgress` 則回報頁面實際進度，兩者都可由 App UI 使用。

### MangaKitchenApp

- `AppStore`：多專案切換、作用中頁面、頁面複選及單一 GPU 批次工作佇列；負責模型缺席時的全黑遮罩手動降級與文字重抽取工作。
- `AppPreferencesController`：保存全域介面、色系、畫布框選顏色、資料位置、預設輸出根目錄、偏好模型與 MCP 網路設定；不寫入個別漫畫專案。
- `WorkspaceRepository`／`ProjectLibraryRepository`：分別保存專案快照與專案索引；以原子寫入更新並保留 `.bak`。
- `ManagedImportService`：把圖片、資料夾、ZIP／CBZ、RAR／CBR 與 PDF 正規化到受管理來源目錄；PDF 先點陣化，壓縮檔先解包，再交給同一掃描器建立頁面。
- `FontFamilyCatalog`：列出系統已安裝字型並提供 WebUI 預覽；專案預設字型變更時只同步仍使用舊預設值的區域，不覆蓋人工選字。
- `HTMLDialogueTypesetter`／`PSDExporter`：以相同 HTML/CSS 分別產生合併圖與透明文字 Raster Layer，再封裝為 PSD；SR 頁面依放大後實際尺寸渲染。
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
- Tools 對應多工作區管理與單頁 Agent 工作包；`prepare_agent_task` 提供原圖與步驟二遮罩 JSON，`submit_agent_result` 一次回寫全部區域並建立步驟三預覽，`page.render` 才儲存步驟四輸出。Resources 提供工作區列表、目前工作區、頁面、原圖、系統遮罩與輸出供診斷；Agent 不需讀取 sidecar。
- MCP 契約以 `mangakitchen.contract.describe` 與 `mangakitchen://contract/current` 公開；寫入使用 opaque page revision 做 optimistic concurrency，區域 partial patch 可透過 `region.batch_update` 先整批驗證再原子提交。
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
CoreMLSuperResolutionRuntime : ImageSuperResolving（原生 4×）
MLXRealESRGANSuperResolutionRuntime : ImageSuperResolving（獨立原生 2×）
```

Qwen Image Edit 的主套件要求 macOS 26，因此以 `RuntimeSupport/QwenImageEditWorker` 隔離，不改變主 App 的 macOS 14 deployment target。`ModelRuntimeHub` 已使用 protocol existential 並依 manifest 的 `backend` 建立 Adapter，因此 `ComicTranslationPipeline`、AppStore 與 WebUI 不需因模型切換而更動。

## 後續 Layout 核心

UI 設計前建議依序完成：

1. 以漫畫專用 DBNet／CRAFT 或 segmentation 模型補強暗色、彩色背景與非封閉旁白框；擬聲字目前不納入主工作流，未來若支援需使用獨立偵測與排版策略。
2. 禁排規則、標點擠壓、直排旋轉字元、ruby 與 fallback font chain。
3. 依實際氣泡幾何與禁排規則強化翻譯長度預估，減少只靠縮小字級。
4. Project JSON 與原始檔 security-scoped bookmark，支援關閉後復原。
5. 批次輸出命名、格式、色彩描述檔與 metadata 保留。
