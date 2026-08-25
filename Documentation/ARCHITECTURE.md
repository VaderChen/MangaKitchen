# 漫畫廚房（MangaKitchen）架構

## 目標

核心設計遵守三個原則：

1. 頁面處理與模型實作分離，替換 Core ML、MLX Swift 或外部 Runtime 時不改專案資料。
2. 原圖座標一律使用左上原點的 `NormalizedRect`，前端 Canvas、Vision、Core Graphics 只在邊界轉換。
3. GPU 工作逐頁執行；大型模型延遲載入、同身分重用，並在 unified memory 壓力過高時先釋放其他 runtime。

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

翻譯階段先以 `targetLanguageCode` 解析詞條，再依本頁 `sourceText` 篩選實際出現的專有名詞，最後只把命中的 `ResolvedGlossaryTerm` 注入 GUI 多模態模型或 MCP 多模態 Agent 的 Prompt。這可避免大型專案將無關詞條全部送進模型，同時讓 GUI、批次流程與 MCP 使用同一套語言選擇規則。GUI 不再提供文生文模型選項；舊專案讀到 `textToText` 時會遷移為 `imageToText`。

## 翻譯與上色資料流

### 翻譯四步驟

```text
1. ComicDirectoryScanner
   └─ 遞迴掃描、自然排序、保留相對路徑

2. MangaBubbleSegmentationCoreMLRuntime + MangaTextMaskRefiner + PageBackgroundRestoring
   ├─ 內建 Core ML 氣泡分割模型優先以 Apple Neural Engine 產生對話框 BBOX 與形狀，再固定由原圖像素內縮為字形遮罩
   ├─ 這一步不需要 Medium Det 或 `imageToText` VLM；OCR／VLM 偏好不能切換或改寫遮罩幾何
   ├─ 氣泡 instance mask 裁切 BBOX，保存 `bubbleMaskPolygons` 與供排版使用的 `bubbleLayoutBounds`
   ├─ Otsu／連通元件把搜尋結果縮減成字形級像素遮罩，並將文字 bounds 同步縮到字形外框
   └─ 像素層膨脹 + add/erase 畫筆 → 二值 `dialogue-mask.png` + 指定底紙色／CPU／GPU 去字背景 + 專案文字狀態；MCP 直接提供這些完成產物給 Agent

3. OCRRegionTextRecognitionService／ImageToTextGenerating／外部多模態 MCP Agent + ImageSuperResolving（選用）+ HTMLDialogueTypesetter
   ├─ 內建 PP-OCRv6 直接辨識步驟二已建立的文字區域，分開保存每模型 `ocrResults`；`sourceText` 空白時採用預設 OCR 原文，已確認原文、座標與遮罩不覆寫
   ├─ AppStore 支援整頁重新抽字、重新翻譯與單區重新抽取／翻譯；重新抽字不重建步驟二產物
   ├─ GUI 固定使用 `imageToText` 多模態 Adapter 產生整頁草稿、可選校稿與 QA；MCP 以單頁工作包一次提供原圖、品質參數與遮罩 JSON，能讀圖的 Agent 一次回傳全部區域
   ├─ MLX Real-ESRGAN 2×／Core ML Anime 4× 寫入獨立 SR 背景，並保護步驟二已去字的遮罩像素
   └─ 依實際背景尺寸應用 HTML/CSS 固定或自動字級、橫排／直排 → `translated.png` 步驟三預覽／分層 PSD

4. Save Output
   └─ 只將已確認的步驟三 `translated.png` 原子寫入輸出目錄；不重跑任何模型、遮罩、去字、SR 或排字
```

### 上色四步驟

```text
1. Select Colorization Pages
   └─ 優先選用既有翻譯輸出作為輸入；沒有翻譯輸出時才回退原圖，不修改翻譯產物

2. ColorizationMaskGenerator
   ├─ 依既有對話區域、氣泡形狀與人工 add／erase 筆劃建立 `colorization-mask.png`
   └─ 白色像素允許上色；黑色像素保護對話框與人工擦除區，不能由模型改寫

3. CoreMLDDColorRuntime／外部多模態 MCP Agent
   ├─ 本機路徑延遲載入下載式 DDColor Tiny Core ML，以原尺寸亮度與模型色度建立 `colorized.png` 預覽
   ├─ Agent 路徑一次取得實際輸入與反對話框遮罩，回寫同像素尺寸的完整頁面
   └─ 兩條路徑都再次以遮罩合成，黑色保護區強制取回輸入像素；本步只建立預覽，不寫最終輸出

4. Save Colorization Output
   └─ 只將既有 `colorized.png` 預覽原子寫入上色輸出；不重跑 DDColor、Agent 或遮罩
```

上色使用獨立的 `ColorizationPageState`、`colorizationMaskStrokes`、`colorizationPreviewURL` 與 `colorizationOutputURL`，不借用或覆寫翻譯的頁面階段、進度、預覽與輸出。`colorizationColorRange` 與 `colorizationMode` 目前只是保留的介面設定，DDColor Tiny 不接受這兩項推論參數，因此 UI 停用且契約不宣稱它們已生效。

編輯器對文字區域保存每頁最多 50 份記憶體內 undo／redo 快照；文字圖層可調整順序、顯示、透明度、旋轉、對齊、文字顏色與 CSS 描邊，每次成功修改仍會寫回 `.str` 與專案快照。中央畫布的檢視座標與原圖座標分離：可雙軸平移，滾輪縮放以可視畫布中心為錨點，適合視窗與 `1:1` 只改變檢視倍率，不改動區域正規化座標。PSD 匯出不另建 Core Text 排版器：合併預覽與每個文字圖層都由同一份 HTML/CSS 逐層渲染，再封裝為 PSD Raster Layer，並在尺寸一致時附加乾淨背景與隱藏原圖。

翻譯 Provider 不直接擴張為 App 內建清單。MangaKitchen 將 MCP 工作包、細緻排版欄位、進度與可恢復狀態視為主要擴充邊界；外部 Agent 可自行使用其支援的本機或雲端 Provider，再透過穩定 MCP 契約回寫結果。

每個步驟只透過 Swift protocol 交換 `URL`、`DialogueRegion`、`MaskStroke` 與進度，因此可單獨替換與除錯。翻譯的一鍵模式只依序組合翻譯步驟二至四；上色仍遵循自身的遮罩、預覽、輸出邊界。

## Target 責任

### MangaKitchenApplication

- 只依賴 `MangaKitchenCore`，保存 GUI、MCP 與未來 CLI 共用的業務規則。
- `WorkflowArtifactState` 統一判斷遮罩、翻譯預覽、上色預覽與最終輸出是否完整，入口層不得各自複製檔案狀態判斷。
- `PageWorkflowProgress` 統一把各處理階段映射成頁面總進度。
- `OutputDirectoryPolicy` 統一來源與輸出目錄的安全邊界。
- 此層不依賴 AppKit、WebKit、Metal、Core ML、MLX、MCP SDK 或 SwiftNIO。

### MangaKitchenCore

- 不依賴 AppKit、Metal 或 WebKit。
- 定義 `ComicPage`、`DialogueRegion`、`ProcessingOptions`、`ColorizationPageState`、`ProjectGlossary` 與 `GlossaryEntry`。
- 定義推論、區域偵測、翻譯、上色、遮罩、修補與排版 protocol。
- 適合未來供 CLI、測試工具或其他 macOS App 重用。

### MangaKitchenRuntime

- `ModelRuntimeHub`：每個 capability 同時只保留一個 protocol-based Runtime，分別管理 `textToText`、`imageToText`、`imageToImage`、`imageColorization` 與 `superResolution`。載入前比對模型 ID、capability 與解析 symlink 後的 canonical path；同一 capability 的並行載入會序列化，第一筆完成後若身分相同即共用 runtime。`textToText` 只保留底層相容能力，GUI 與公開翻譯工作流固定使用 `imageToText`。
- `CoreMLModelRuntime`：讀取 manifest、編譯模型並透過 `MLModelConfiguration` 指定 CPU + Metal GPU。
- `MLXVLMRuntime`：載入本機 Hugging Face 多模態模型並跨頁重用 container。結構化回覆與 Think Mode 在短 reasoning 第一段沒有完整 final JSON 時，沿用同一 container，以 `enable_thinking = false`、`temperature = 0` 執行第二段收尾。`MLXTextRuntime` 仍是底層相容 runtime，但不出現在 App 模型頁或公開翻譯流程。
- `VLMStructuredResponseDecoder`：只接受 reasoning 結束後的完整 JSON，不會把 `<think>` 內的片段誤認為答案；reasoning 串流只送往記憶體內 UI store，不寫入 Application LOG 或專案資料。
- `CoreMLSuperResolutionRuntime`：讀取模型原生輸入／輸出尺寸決定倍率；目前 Anime 512 模型為獨立 4× 權重，不再固定縮回 2×。
- `MLXRealESRGANSuperResolutionRuntime`：載入 `mlx-community/Real-ESRGAN-x2plus` 的獨立 FP16 RRDBNet 權重，執行原生 2× 超解析；不載入、不重用也不降採樣 4× Anime 模型。
- `CoreMLDDColorRuntime`：載入下載式 `DDColor_Tiny.mlpackage`，以 512×512 灰階 RGB 輸入預測 Lab `ab_channels`，再把色度高品質縮放回原頁並結合原尺寸亮度；若提供反對話框遮罩，最後交由 `MaskedImageCompositor` 強制保護黑色區域。
- `ColorizationMaskGenerator`：依既有對話區域、氣泡形狀與上色專用畫筆建立原尺寸反對話框遮罩；白色允許模型輸出、黑色保留輸入，不與翻譯的 `dialogue-mask.png` 混用。
- `QwenExternalImageEditRuntime`：以 JSONL 監看獨立 Swift/MLX worker，傳遞進度、錯誤與取消訊號。
- `MaskedImageCompositor`：將生成候選圖縮放回原頁，再只採用 mask 白區，避免生成模型改動未授權區域。
- `MangaBubbleSegmentationCoreMLRuntime`：內建由 `manga109-segmentation-bubble` 匯出的 Core ML YOLO 分割模型。模型依 image constraint 進行方形 letterbox，優先採用 `cpuAndNeuralEngine`；輸出反算回原圖座標並經 NMS 產生 BBOX，若有 prototype 則同步解出 `bubbleMaskPolygons` 與 `bubbleLayoutBounds`。模型無法載入或推論失敗時，才由 `MangaBubbleCandidateDetector` 的封閉白色連通區演算法後備。
- `MangaBubbleMaskRegionDetector`：在步驟二將 Core ML BBOX 與氣泡形狀寫入 `DialogueRegion.bounds`、`bubbleBounds`、`bubbleMaskPolygons` 及 `bubbleLayoutBounds`，不載入或呼叫 VLM；`MangaTextMaskRefiner` 隨即依原圖像素將遮罩與文字 bounds 收斂到實際字形。
- `VLMRegionTranscriptionService`：保留為可複用的 VLM 轉錄 runtime，但目前預設 OCR 流程不持有、不呼叫它。內建 OCR 資源缺失時會明確失敗，不暗中切換模型。
- `PPOCRRecognitionRuntime`／`OCRRegionTextRecognitionService`：預設以 Medium Det 只在步驟二既有區域內切出文字行／直排欄，再以 repository 內建的 PP-OCRv6 Medium macOS 14 Core ML recognizer 逐行辨識；Medium 無法載入時回退至 Small。結果依閱讀順序合併，並將每個 OCR 模型的文字、信心、行框與方向寫入 `DialogueRegion.ocrResults`。當 `sourceText` 空白時，預設 OCR 文字會成為翻譯原文；已有 VLM、Agent 或人工原文不覆寫，也不改動定位、遮罩或冒用 `ocrTextRefined`。
- `PPOCRTextDetectionRuntime`／`PPOCRTextRegionDetector`：內建 PP-OCRv6 Medium Det 的原生 Swift／Core ML 文字行定位 runtime，固定輸入使用白底 letterbox，優先採用 `cpuAndNeuralEngine`。它與步驟二遮罩管線隔離，不建立或改寫 `DialogueRegion` 遮罩。
- `VLMBubbleTextRegionDetector`：只處理已確認對話框裁切並回傳 0...1000 文字座標；不轉錄、不翻譯，也不掃描框外畫面。這個 runtime 同樣不參與步驟二遮罩產生。
- `SoundEffectRegionDetecting`：預留給未來狀聲字流程的獨立契約，只能掃描既有對話區域之外的畫面；目前 `ComicTranslationPipeline` 不持有、不呼叫，也不把結果混入對話遮罩。
- 外部 MCP Agent：翻譯的 `prepare_agent_task` 只在 App 步驟二區域、遮罩與去字背景均完成時，一次傳送指定頁原圖與完整遮罩 JSON；Agent 依既有 `region_id` 抽取原文、翻譯及排版，再由 `submit_agent_result` 建立步驟三預覽。上色的 `prepare_colorization_task` 則一次傳送實際上色輸入與反對話框遮罩，`submit_colorization_result` 驗證尺寸、正規化 PNG 並重新套用保護遮罩。兩條流程都只有在使用者要求輸出時才呼叫各自的 render 工具。
- `MangaTextMaskRefiner`：先分析 Core ML BBOX 或 Agent 粗框；若已知 `bubbleMaskPolygons`，會先以氣泡形狀篩選元件。搜尋範圍不會直接成為遮罩，最後以 Otsu 閾值及八鄰域連通元件取得字形像素，並在像素層執行抗鋸齒遲滯與固定像素膨脹，再合併成二值遮罩矩形，避免向量描邊造成灰階毛邊；`bounds` 同步縮到未膨脹的字形外框。暗色背景上的亮字由系統覆蓋檢查回報，必要時由使用者在 App 內以畫筆修正。
- `VLMRegionTranslationService`：GUI 固定接多模態 `imageToText` runtime，將整頁已確認的來源文字與圖片語境依閱讀順序送入模型；若回覆遺漏 UUID，只執行一次有界補翻並保留已成功結果，避免 timeout／fallback 重複翻譯。`TextOnlyImageToTextAdapter` 僅保留底層相容用途，不是可選 GUI 路徑。二次整頁校稿為可選且預設關閉；啟用時先透過 `DraftRegionTranslating` 提交初稿，由 App 寫入 `.str`、專案快照與排版預覽，再以一次整頁請求校正既有譯文。校稿不得重新抽取 `sourceText` 或逐區重翻，取消時也不回滾已提交初稿。
- `TranslationQualityOptions`：專案級控制整頁語境、可選二次校稿、QA、直譯稿保存、忠實／平衡／精簡長度策略與 4,000 字元風格指南。結果保存 `literalTranslatedText`、`speakerID`、`tone`、`translationConfidence` 與 `translationQAFlags`，人工改寫顯示譯文時會清除已過期的信心與 QA。
- `CPUBubbleCleaner`／`MetalBubbleCleaner`：步驟二的傳統去字後端。`eraseColorHex == AUTO` 時由修補器估算底紙色；指定固定底紙色時由 CPU 精確填色，並清除遮罩外兩像素內的近底色 JPEG／掃描 halo。同一文字區域的斷開筆畫共用單一底色，避免紙紋取樣變成字形斑點。
- `HTMLDialogueTypesetter`：將步驟三保存的 `translationBounds`、`translationAnchor`、字型、固定／自動字級、粗細及橫排／直排設定交給 WebKit；自動方向優先採用字形排列偵測結果，氣泡排版優先使用完全位於 `bubbleMaskPolygons` 內的 `bubbleLayoutBounds`。使用與 WebUI 相同的 HTML/CSS 與自動縮字演算法渲染背景及文字層，再輸出原圖像素尺寸的 PNG。GUI、批次與 MCP 共用此排版器，不再存在另一套 Core Text 輸出規則。
- `ComicTranslationPipeline`：翻譯固定遵循「找氣泡 → 原圖像素遮罩 → OCR／VLM 原文 → 多模態／Agent 翻譯 → 排版預覽 → 輸出」；步驟二永遠使用氣泡 detector 與像素精修，步驟三才依專案選項使用逐欄 OCR 或 VLM 整區轉錄，翻譯器固定為 `imageToText`。上色另遵循「選擇翻譯輸出或原圖 → 反對話框遮罩 → DDColor／Agent 預覽 → 輸出」。後續階段不得隱式重做或改寫前一步。氣泡外狀聲字屬於另一條尚未接入的流程。`PageRegionProgress`、`PagePipelineProgress` 與 `ColorizationPageState` 分別回報區域、翻譯頁面與上色頁面進度。

### MangaKitchenApp

- `MangaKitchenRuntimeEnvironment`：程序內唯一的組合根。GUI 與 MCP 共用同一個 `MetalContext`、`ModelRuntimeHub`、內建 Core ML runtime、`HTMLDialogueTypesetter`、工作流程 Pipeline 與 `Artifacts` 根目錄；MCP 不得自行建立第二套推論環境。
- `AppStore`：協調多專案切換、作用中頁面、頁面複選及單一 GPU 批次工作佇列；翻譯與上色的步驟、預覽、輸出及清除重來狀態維持分離。偏好模型只保存路徑，實際推論前才延遲載入；大型模型載入前讀取 RAM 使用率，必要時釋放其他 capability。步驟二不因文字模型缺席而改用全黑遮罩。
- `AppEditingHistory`：獨立保存遮罩畫筆、上色遮罩與文字區域的 undo／redo 歷程，以及遮罩 revision。切換、清除或重設專案／頁面時由 `AppStore` 明確清除對應歷程，歷程物件不修改頁面、不執行推論也不負責持久化。
- `AppBatchWorkflowCoordinator`：擁有單一序列批次 Task、工作去重、queued／running／completed／cancelled 狀態轉移及逐頁失敗紀錄；實際 OCR、翻譯、上色與輸出動作由 `AppStore` 以閉包注入，因此佇列本身不依賴特定工作流程。
- `AppModelLifecycleCoordinator`：管理 capability 偏好路徑、延遲載入、模型身分重用、Think Mode runtime 更新與 unified-memory 壓力卸載；下載進度與專案模型路徑持久化仍由 `AppStore` 負責。
- `ApplicationLogStore`／`ModelReasoningStreamStore`：分開保存一般診斷與 transient reasoning。前者只存在記憶體且可清除；後者不進 LOG、不持久化，透過 `HybridBridgeController` 的 transient state 單獨更新 THINK 節點。
- `SystemMetricsReader`：週期讀取 GPU 與 unified-memory 使用率；和畫布解析度／倍率一起只更新狀態列節點，不觸發 `AppStore.objectWillChange` 或重建編輯器 DOM。
- `AppPreferencesController`：保存全域介面、色系、畫布框選顏色、資料位置、預設輸出根目錄、`imageToText`／`imageColorization`／`superResolution` 偏好模型與 MCP 網路設定；不寫入個別漫畫專案。
- `WorkspaceRepository`／`ProjectLibraryRepository`：分別保存專案快照與專案索引；以原子寫入更新並保留 `.bak`。
- `ManagedImportService`：把圖片、資料夾、ZIP／CBZ、RAR／CBR 與 PDF 正規化到受管理來源目錄；PDF 先點陣化，壓縮檔先解包，再交給同一掃描器建立頁面。
- `FontFamilyCatalog`：列出系統已安裝字型並提供 WebUI 預覽；專案預設字型變更時只同步仍使用舊預設值的區域，不覆蓋人工選字。
- `GitHubReleaseChecker`：啟動時與「關於」頁手動檢查共用同一個 GitHub latest stable release 查詢與版本比較。對外開啟只允許官方 repository 根路徑與 Releases 子路徑，不自動下載或安裝。
- `HTMLDialogueTypesetter`／`PSDExporter`：以相同 HTML/CSS 分別產生合併圖與透明文字 Raster Layer，再封裝為 PSD；SR 頁面依放大後實際尺寸渲染。
- `HybridBridgeController`：負責 WebKit 狀態推送、生命週期與以 `WebBridgeMethod` 白名單分派命令；未知字串不會進入業務處理。
- `WebBridgeCommandHandler`：擁有完整 `WebBridgeMethod` 白名單 switch，將命令分派至 `AppStore` 或控制器提供的原生能力；`HybridBridgeController` 不再同時負責 JSON-RPC transport 與業務命令路由。
- `WebBridgeParameterDecoder`／`WebBridgePanelService`：前者統一把 JavaScript 弱型別參數轉成領域型別並檢查正規化座標，後者集中建立原生檔案／目錄選擇器；兩者都不執行 AppStore 業務流程。
- `i18n.js`：管理 `AUTO`、`zh-Hant`、`en`、`ja`、`ko` 五種介面選項；WebUI local storage 作為啟動畫面快取，Swift 全域偏好是持久化來源，AUTO 依 WebKit/macOS 語言解析，未支援語言回退英文。
- `NativeLocalization`：接收 WebUI 已解析的介面語言，讓原生目錄面板與 MCP menu bar 使用相同語言；介面語言屬於 App 全域偏好，不寫入個別漫畫專案，也不改變翻譯的 `targetLanguageCode`。
- `TargetLanguageResolver`：AUTO 中文只有在語系明確含 `Hans`／`CN`／`SG` 時選簡體；`Hant`／`TW`／`HK`／`MO` 與資訊不足的 `zh` 均選繁體。翻譯寫入前另以 ICU 對 `zh-Hant`／`zh-Hans` 做 script 正規化，避免模型忽略 BCP-47 指示。
- `WebUISchemeHandler`：只提供 bundle 內的 HTML/CSS/JavaScript。
- `AssetSchemeHandler`：只提供已匯入頁面的 source/output 映射，不接受任意檔案路徑。
- 主 Swift Package、可執行產品與內部 modules 統一使用 `MangaKitchen` 命名。
- App 資料存於 `Application Support/MangaKitchen`。

### MangaKitchen MCP 模式

- 每次工具操作前由 App 的最新專案快照更新工作內容，完成後再回寫 App；模型、Metal 與 Artifacts 則直接使用共用 `MangaKitchenRuntimeEnvironment`，不透過快照複製。
- `MCPWorkflowService` 只協調目前作用中的工作區與頁面工作流；`MCPWorkspaceRegistry` 獨立保存多工作區快照索引、標準化來源路徑查找與名稱查詢，避免工作流服務直接操作字典儲存細節。
- `MCPPageContractPresenter`：集中建立 page task、inspection、mutation result、resource JSON／MIME 表示及 opaque revision；工作流 actor 不再複製契約呈現與 optimistic concurrency 雜湊規則。
- 使用官方 Swift MCP SDK 與標準 Streamable HTTP transport，監聽 `0.0.0.0`；預設 port 為 `12080`。
- 每個 HTTP request 都以 TCP socket 的實際來源 IP 檢查 IPv4／IPv6／CIDR 白名單，不採信可偽造的轉送標頭；空白名單拒絕所有連線。
- Tools 對應多工作區管理與單頁 Agent 工作包；翻譯以 `prepare_agent_task`／`submit_agent_result` 建立步驟三預覽，上色以 `prepare_colorization_task`／`submit_colorization_result` 建立獨立預覽，各自只有 `page.render`／`page.render_colorization` 才儲存步驟四輸出。Resources 提供工作區列表、目前工作區、頁面、原圖、系統遮罩、翻譯與上色產物供診斷；Agent 不需讀取 sidecar。
- 上色回寫只接受 PNG／JPEG／HEIC／TIFF／WebP，Base64 解碼後最多 20 MiB；結果像素尺寸必須與工作包輸入完全一致。App 會正規化為 PNG 並重新套用反對話框遮罩，黑色區域強制保留輸入像素。
- MCP 契約以 `mangakitchen.contract.describe` 與 `mangakitchen://contract/current` 公開；寫入使用 opaque page revision 做 optimistic concurrency，區域 partial patch 可透過 `region.batch_update` 先整批驗證再原子提交。
- 不建立第二個 executable；`MangaKitchen` 永遠啟動 GUI，MCP 開關、port 與白名單由全域設定管理，`--mcp=on|off` 與 `--mcp-port` 可覆寫本次啟動。
- MCP 開啟時建立 macOS menu bar 狀態項目。主視窗關閉後 process 與 MCP 繼續運作，並可從 menu bar 重新開啟視窗或完整結束 App。
- MCP JSON-RPC 僅存在 `MangaKitchenApp/MCP` adapter 目錄；模型 Runtime 與 Pipeline 不依賴 MCP。
- MCP tool 名稱由 `MCPToolName` 集中定義並統一使用 `mangakitchen.*`，router 與 tool schema 共用相同 raw value；resource URI 使用 `mangakitchen://`。
- 以標準 session header 管理 HTTP session；MCP process 可保留多個目錄工作區，工具參數仍顯式傳遞 `workspace_id`，避免操作依賴目前顯示中的專案。

完整方法、`.str` schema 與 MCP URI 請見 [WORKFLOW_API.md](WORKFLOW_API.md)。

## 模型擴充點

目前已實作：

```text
CoreMLModelRuntime : ImageToTextGenerating + ImageToImageGenerating
MLXVLMRuntime : ImageToTextGenerating
QwenExternalImageEditRuntime : ImageToImageGenerating
CoreMLDDColorRuntime : ImageColorizing
CoreMLSuperResolutionRuntime : ImageSuperResolving（原生 4×）
MLXRealESRGANSuperResolutionRuntime : ImageSuperResolving（獨立原生 2×）
```

`MLXTextRuntime : TextGenerating` 仍存在於底層作為相容擴充點，但 App 已移除文生文模型頁面，GUI 翻譯與公開 MCP 翻譯契約都要求能讀取頁面圖片的多模態路徑。

Qwen Image Edit 的主套件要求 macOS 26，因此以 `RuntimeSupport/QwenImageEditWorker` 隔離，不改變主 App 的 macOS 14 deployment target。`ModelRuntimeHub` 已使用 protocol existential 並依 manifest 的 `backend` 建立 Adapter，因此 `ComicTranslationPipeline`、AppStore 與 WebUI 不需因模型切換而更動。

## 後續 Layout 核心

UI 設計前建議依序完成：

1. 以 `SoundEffectRegionDetecting` 實作氣泡外狀聲字的獨立偵測、分類、遮罩與排版策略；不得回灌目前的 `DialogueRegion` 主流程。
2. 禁排規則、標點擠壓、直排旋轉字元、ruby 與 fallback font chain。
3. 依實際氣泡幾何與禁排規則強化翻譯長度預估，減少只靠縮小字級。
4. Project JSON 與原始檔 security-scoped bookmark，支援關閉後復原。
5. 批次輸出命名、格式、色彩描述檔與 metadata 保留。
