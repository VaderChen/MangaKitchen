# 漫畫廚房（MangaKitchen）

繁體中文 | [English](README.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

漫畫廚房（MangaKitchen）是一個 macOS 原生漫畫翻譯工作台。前端保留為 HTML + JavaScript，後端以 Swift Package 分成領域核心、Metal/Core ML Runtime 與 WKWebView App 三層。核心聚焦於模型邊界、逐頁工作流、對話區域、遮罩與排版，不綁定特定前端版面。

<p align="center">
  <img src="AppPic/screen01.jpg" alt="MangaKitchen 應用程式畫面" width="800">
</p>

## 著作權與合法使用

所有匯入 MangaKitchen 的漫畫原稿、角色、文字、美術、商標及其他內容，其著作權與相關權利均屬原作者、出版社、授權平台或各自的合法權利人。使用本工具不會移轉這些權利，也不代表使用者取得重製、翻譯、公開傳輸、散布或販售作品的授權。

MangaKitchen 的目的，是輔助已取得授權的翻譯人員、在地化團隊及其他合法使用者整理頁面、遮罩、譯文、專有名詞與排版流程，減少重複作業，讓讀者更快看到品質更高的合法翻譯。翻譯成果可能構成衍生著作；在公開、分享或散布原稿與翻譯成果前，請先取得必要授權，並遵守所在地法律、內容授權條款及所使用模型或 AI 服務的規範。

請勿使用 MangaKitchen 製作或散布盜版、未授權翻譯、破解內容，或規避 DRM、浮水印及其他權利保護措施。開發者不鼓勵也不支持任何侵害著作權的用途。請透過合法平台購買正版單行本、電子書、訂閱或授權商品，以實際行動支持作者、譯者、出版社及整個創作產業。

## 軟體授權

MangaKitchen 採雙軌授權。此 repository 中由 MangaKitchen 著作權人擁有且未另行標示的程式碼，預設依 [GNU General Public License version 3 only](LICENSE)（`GPL-3.0-only`）提供；需要閉源整合、專有散布或其他條款者，可另行洽談[商業授權](COMMERCIAL-LICENSE.md)。

GPLv3 本身允許商業使用及收費散布，但必須履行其原始碼與 copyleft 義務。商業授權是另一個可選方案，不會限制已依 GPLv3 取得的權利。第三方套件、模型與權重、字型及漫畫內容不包含在 MangaKitchen 的雙軌授權內，仍適用各自的授權條款。

## 目前完成

- macOS 14+ SwiftUI / WKWebView 應用程式殼。
- HTML/JavaScript 與 Swift 的非同步 JSON Bridge。
- WebUI 支援 `AUTO`、繁體中文、英文、日文與韓文；AUTO 跟隨 macOS 語言，手動選擇會跨啟動保存，原生目錄面板與 MCP menu bar 同步套用。
- 全域設定 DLG 分為一般、進階、模型、MCP、關於；可設定介面語言、UI 色系、CPU／GPU 圖像合成、資料位置、圖生文／圖生圖／超高解析度模型、MCP 連接埠與 IP／CIDR 白名單。
- 全域設定也可保存畫布框選顏色與預設輸出根目錄；新專案會在根目錄下建立經過清理的專案名稱子目錄，已有明確輸出位置的專案不會被覆寫。
- 每個來源目錄建立為獨立專案，可保存多個專案並由工具列快速切換。
- 選取來源目錄後遞迴掃描，保留子目錄相對路徑、自然排序並避免同名頁面衝突。
- 頁面列表支援 Command／Shift 複選、搜尋與狀態篩選；遮罩、翻譯、合成都可針對選取頁面批次執行。
- 批次工作使用單一循序佇列，顯示目前頁面、成功／失敗數量，並支援取消、清除紀錄與重試失敗頁面；逐區翻譯時同步顯示目前區域／總區域與實際進度。
- 每個專案擁有獨立的多語專有名詞表；一個原詞可保存多個 BCP-47 譯詞，翻譯時依目前目標語言自動套用。
- 四階段工作流：掃描、文字／遮罩、翻譯／排版設定、背景修補／合成；同時保留一鍵完整頁與全部頁面。
- 每張圖片對應版本化 `.str` JSON，保存文字、位置、字型、固定／自動字級與遮罩筆劃。
- 遮罩以原圖像素層膨脹收進抗鋸齒邊緣，再由正規化畫筆支援添加、擦除、復原與重做，最後輸出二值 PNG；不再對逐條向量矩形描邊，避免灰階毛邊。步驟二完成後立即顯示已清除原文字的 CPU／GPU 遮罩校對圖，不提前啟動圖生圖模型；Metal 修補會累積完整方向樣本並採亮度第 90 百分位背景色階，降低字緣或框線被填回遮罩的零碎殘留。
- 內建由 [huyvux3005/manga109-segmentation-bubble](https://huggingface.co/huyvux3005/manga109-segmentation-bubble)（Apache-2.0）匯出的 manga109 氣泡分割 Core ML 模型，優先使用 Apple Neural Engine 在本機推論產生對話框 BBOX 與氣泡形狀；形狀會裁切遮罩搜尋範圍，並計算供 HTML 排版使用的氣泡內接矩形。之後才把每個候選交給圖生文模型分類與轉錄；不再使用系統 OCR 辨識或定位文字。主流程刻意排除擬聲字、頁碼、頁尾資訊、人物與空白區。
- 若進入步驟二時沒有載入 `imageToText` 圖生文模型，App 會先提示將切換為手動模式，建立與原圖同尺寸的全黑遮罩，讓使用者用畫筆自行標示要處理的範圍；需要模型的偵測、重新計算與翻譯按鈕會保持停用。
- 翻譯步驟已內建原生 Swift／Core ML PP-OCRv6 Small OCR。VLM 仍負責文字定位與區域分類；OCR 只在逐區或整頁翻譯前產生候選原文，並以模型 ID 分開保存，不覆寫 VLM 原文、文字座標或遮罩。複合 OCR 與二次校稿融合保留給後續流程，低信心結果不會自動取代目前原文。
- 翻譯步驟提供整頁「重新抽字」與「重新翻譯」，也可在單一文字區域旁重新抽取並翻譯；這些操作不會重建步驟二遮罩或去字背景。所有等待 DLG 都會顯示累計讀秒（`MM:SS`）。
- VLM 接受的對話框 BBOX 會以原圖像素連通元件收斂成字形遮罩，同步把文字定位框縮到未膨脹的實際字形外框；自動排版方向優先採用字形實際排列偵測結果。每個候選會獨立處理，單一候選的分類、轉錄或翻譯失敗時保留原區域並繼續其他區域；只有取消工作才會停止整體流程。
- 圖生文模型的頁面語境翻譯 Prompt 與嚴格 JSON 回傳解析。
- 可直接載入本機 Hugging Face MLX VLM 目錄，由 `mlx-swift-lm` 在 Apple Silicon／Metal 執行。
- 以 model manifest 載入 `.mlmodelc`、`.mlmodel` 或 `.mlpackage`，Core ML 指定 Metal GPU。
- 超高解析度提供兩個互不共用權重的模型：推薦的 `Real-ESRGAN x2plus` 原生 MLX 2×，以及可選的 `Real-ESRGAN Anime 512` 原生 Core ML 4×；2× 不會由 4× 結果降採樣冒充。完成後立即切換中央畫布、重繪既有翻譯預覽，尺寸旁以 `*` 標示 SR 產物，後續 HTML 合成與 PSD 也沿用實際 SR 尺寸。
- 對話文字遮罩可由一個或多個像素級形狀覆蓋原字、裁切於對話框邊界，再疊加畫筆增刪；沒有圖生圖模型時可選 CPU 或 Metal GPU 修補。
- HTML/CSS 是翻譯排版的唯一標準，支援橫排／直排、固定或自動字級、拖曳與八方向尺寸調整；最終 PNG 由 WebKit 直接渲染同一套文字層，步驟三預覽不會在輸出時改成另一套排版。
- 編輯器支援區域新增、複製、移除、排序及每頁最多 50 份 undo／redo；畫布可水平與垂直平移，滾輪縮放以可視畫布中心為錨點，並提供適合視窗與 `1:1` 檢視。文字圖層支援顯示、透明度、旋轉、對齊、文字顏色、描邊及已安裝字型即時預覽。
- PSD 的合併預覽、逐文字 Raster Layer、乾淨背景與隱藏原圖均由 HTML/CSS 渲染結果封裝，不另做一套排版；如果已套用超高解析度，所有可用圖層會保持相同放大後尺寸。
- 專案可匯入或追加圖片、資料夾、ZIP／CBZ、RAR／CBR 與 PDF，並可重新命名、排序或從專案移除頁面；來源會複製、解包或點陣化到受管理目錄，移除不刪來源，重掃也不會自動加回。
- 原圖／輸出圖安全地透過自訂 URL Scheme 提供給 WebUI，不直接暴露任意檔案。
- 專案索引與各專案狀態自動儲存為版本化 JSON；寫入前保留上一版 `.bak`，重新啟動會驗證來源與輸出檔後復原。
- 「設定 → 進階」可保存預設輸出位置；新建且尚未指定輸出目錄的專案會在此位置下自動建立專案名稱子目錄，已有明確輸出設定的專案不會被覆寫。
- 可選的 macOS 26 Swift/MLX Qwen Image Edit worker；mask 同時作為模型條件圖與最終合成限制。
- 可選的標準 MCP Streamable HTTP server，提供四階段 tools、工作區／圖片 resources、取消與進度通知。
- MCP 是外部 Provider 的主要擴充邊界；Agent 可使用自身支援的 Provider，再回寫完整文字與 HTML 圖層樣式，App 不維護重複的雲端 Provider 清單。
- 本機翻譯支援整頁語境草稿、整頁二次校稿、直譯稿／顯示譯文分離、角色與語氣標記、信心分數及 deterministic QA；專案可獨立調整語境、校稿、QA、直譯稿、長度策略與風格指南。
- MCP 啟用時常駐 macOS menu bar；主視窗關閉後可由 menu bar 重新開啟。

## 兩種使用方式，共用同一套專案與四步驟

MangaKitchen 有兩種操作方式。它們只改變「誰負責推論與編排」，不會形成兩套資料格式或處理流程。每次工作都必須先建立來源目錄專案；頁面、遮罩、譯文、排版設定、專有名詞與輸出狀態都保存在該專案範圍內。

共同的四個步驟為：

1. **專案與頁面**：選取來源目錄、遞迴掃描圖片，建立可複選與批次處理的頁面列表。
2. **文字與遮罩**：以內建 Core ML 氣泡分割模型定位對話框 BBOX 與形狀，再依原圖像素精修成字形遮罩；此步驟不呼叫 VLM。MCP Agent 也可直接提供區域與原文，使用者可添加、擦除與修正遮罩。
3. **翻譯與排版**：GUI 由 VLM 在既有 BBOX 中定位、分類與轉錄原文；若已安裝本機 Core ML OCR，逐區／整頁翻譯前會另外保存 OCR 候選，但不取代 VLM 原文。MCP 則由 Agent 依 App 提供的工作包完成原文、翻譯與排版，結果由 App 回寫專案狀態。
4. **修補與合成**：移除原字、修補背景、排入譯文，輸出到專案指定目錄。

四步驟是可續作的狀態與產物契約，不是每次都要從步驟一重新執行的固定清單。GUI 與 MCP 都應先讀取 App 提供的頁面狀態與工作包，再從目前需要的任意步驟開始：已有遮罩可直接翻譯，已有譯文可直接調整排版或合成，只有某個區域需要修改時也只需更新該區域。除非使用者或 Agent 明確要求重做，已完成的區域辨識、遮罩、譯文與人工編修不應被覆蓋。

從任意步驟開始前，必須按頁面檢查實際資料，而不能只相信狀態名稱。若目標步驟缺少前置產物，就逐級回到最近一個需要補做的步驟：

- 要執行步驟四時，先檢查有效的 `.str` 譯文／排版資料與遮罩；缺少譯文則回到步驟三，缺少文字區域或遮罩則再回到步驟二。
- 要執行步驟三時，先檢查來源頁、文字區域與遮罩；原文尚未確認時會在此步驟由 VLM 轉錄，資料不完整才回到步驟二。
- 要執行步驟二時，先檢查來源圖片仍存在且專案頁面索引有效；缺少時回到步驟一重新掃描。
- 回溯只補齊缺少或失效的資料，不重新產生仍有效的前置產物。不同頁面可以從不同步驟開始。

### 用法 A：下載模型，在本機離線運作

在「設定 → 模型」指定圖生文模型，以及選用的圖生圖模型。區域辨識、翻譯、背景修補與合成都在 Mac 本機執行；模型完成下載後，工作流不需要把漫畫內容送到外部 AI 服務。

- `imageToText` 模型是 GUI 本機步驟三與自動步驟二偵測的必要條件。未載入時進入步驟二會建立全黑遮罩並切換手動畫筆模式；重新計算、重新抽字、重新翻譯與翻譯按鈕都會停用。載入模型後才會在既有 BBOX 中分類、轉錄並依頁面語境翻譯；App 不會改走系統 OCR。擬聲字不進入目前的翻譯主流程，分類、轉錄與翻譯會逐區處理並隔離例外；單區失敗不會讓整頁失敗。
- 「重新抽字」會更新原文並清除依賴它的譯文；「重新翻譯」沿用現有原文；單區按鈕只更新選取區域，完成後重新產生整頁預覽。
- `imageToImage` 模型負責步驟四的背景修補，屬於選用；未設定時依「設定 → 進階」使用 Metal GPU 鄰域修補或 CPU 對話框主色修補，GPU 失敗時會自動退回 CPU。
- `superResolution` 模型屬於選用；可在步驟二產生乾淨背景後手動執行，也可啟用完整流程自動放大。SR 改變實際像素尺寸，不改變畫布檢視倍率的標準計算。
- GUI 可分步執行，也可使用「完整處理選取頁／全部頁面」。一鍵功能仍只是依序執行步驟二至四，不會跳過中間資料。
- 所有結果都回寫專案與 `.str`，可在任何步驟人工修正後重新執行後續階段。

### 用法 B：由 AI Agent 透過 MCP 校稿（推薦）

> **更推薦的流程：先跑本機流程，再使用 MCP 校稿。** 空白專案也可以直接交給 MCP；但若先由 App 本機批次完成四步驟初稿，Agent 就能直接檢查既有原文、譯文與排版，通常能得到更穩定的結果。MCP 會保留 App 已完成的遮罩與區域，不會重新建立或覆蓋它們。

在「設定 → MCP」啟用服務，設定 port 與 IP／CIDR 用戶端白名單，再讓支援 Streamable HTTP 的 AI Agent 連線。MCP 只提供單頁工作包，不要求 Agent 自行拆解、清除或重建四個步驟。

1. （推薦）先在 GUI 開啟專案，載入本機模型，使用「完整處理選取頁／全部頁面」批次完成四步驟初稿；也可以略過此步驟，從空白流程開始。
2. 在「設定 → MCP」啟用服務，讓支援 Streamable HTTP 的 AI Agent 連線。
3. Agent 呼叫 `mangakitchen.workspace.open` 取得 `workspace_id`，再對指定頁面呼叫 `mangakitchen.page.prepare_agent_task`。若步驟二尚未完成，App 會先建立氣泡區域與像素遮罩，再於同一個 tool result 回傳原圖 image content 及內嵌 `regionData` JSON。
4. Agent 依工作包逐區處理：既有 `sourceText`／`translatedText` 視為待校稿草稿，對照原圖修正原文與翻譯，並調整 HTML 排版的尺寸、位置、字重與直橫排方向；空白欄位則重新抽取或翻譯。不得新增、刪除、合併或修改區域與遮罩。
5. Agent 以 `mangakitchen.page.submit_agent_result` 一次回傳全部區域的校稿原文、譯文與排版；App 保留步驟二遮罩、更新內部專案資料，並直接執行步驟四輸出。

`region_source` 與舊的逐區工具僅保留相容性，不是預設 MCP 流程。MCP 步驟三完全由 Agent 接手，App 不會執行內建 VLM 轉錄或翻譯；Agent 不得搜尋、讀取或建立 `.str`，也不需自行讀取多個 page resource 或呼叫 `region.update`。

對既有專案，Agent 不應自行清除、重新掃描或重跑已完成的步驟；只對使用者指定的頁面建立工作包。`workspace.pages` 只作狀態查詢，不是要求 Agent 自行迴圈執行的命令清單。

MCP 模式同樣支援多工作區、明確的 `workspace_id`、多頁批次、專案專有名詞表、取消與進度通知。AI Agent 是工作流操作者，不是另一套儲存後端。

## 執行

```bash
swift build
swift run MangaKitchen
```

在 GUI 之外一併啟動 MCP server：

```bash
swift run MangaKitchen --mcp=on
```

GUI 無論 MCP 開關都會啟動；省略 `--mcp` 時使用設定 DLG 中保存的開關，`--mcp=on|off` 可覆寫本次啟動。MCP listener 綁定 `0.0.0.0`，預設連接埠為 `12080`，只接受白名單中的實際來源 IP／CIDR；預設白名單只有 `127.0.0.1`。本機 endpoint 為 `http://127.0.0.1:12080/mcp`，也可用 `--mcp-port=<port>` 覆寫本次啟動。關閉主視窗不會結束 App，可從 menu bar 重新顯示漫畫廚房。

資料儲存位置在重新啟動後生效；圖生文與圖生圖模型位置選取後立即切換。MCP 開關、連接埠與白名單變更時會重新啟動 listener。

專案索引、個別專案狀態與中間檔預設放在：

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Imported/<import-uuid>/
  Artifacts/<page-uuid>/
```

每張 `.str` 直接放在原圖旁，例如 `ComicTest/001.webp` 對應 `ComicTest/001.str`；指定的輸出目錄只保存最終 PNG。舊位置的 `.str` 會複製到原圖旁，舊檔仍保留。

舊版 `Workspace/workspace.json` 會在首次啟動時自動遷移成第一個專案；原檔保留，不會刪除。

## 模型格式

Core ML 與外部 Runtime 模型目錄必須包含 `mangakitchen-model.json`。範例位於：

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

manifest 的 feature 名稱必須與實際 Core ML 模型一致。現有 Core ML Adapter 支援：

- 圖生文：圖片 feature、可選的字串 prompt feature、字串輸出 feature。
- 圖生圖：圖片 feature、可選的 mask／prompt feature、圖片輸出 feature。
- 超解析：`TheMurusTeam/coreml-upscaler-realesrganAnime512` 的原生 4× Core ML 輸出。

原生 2× 超解析使用獨立的 [mlx-community/Real-ESRGAN-x2plus](https://huggingface.co/mlx-community/Real-ESRGAN-x2plus) FP16 Safetensors（BSD-3-Clause）。下載器會為它建立 `backend: mlxSwift`、`capability: superResolution`、`superResolutionScale: 2` 的 manifest，再由專用 RRDBNet runtime 執行；它與 4× Anime Core ML 模型沒有共用權重或降採樣路徑。

Core ML manifest 是對「已封裝成單次 prediction 的模型」提供的通用 Adapter。Qwen-VL 這類需要 tokenizer 與逐 token 解碼的模型會改走專用 MLX Adapter；需要 sampler loop 的擴散模型也必須使用專用 `ImageToImageGenerating` Adapter，不能只更改 Core ML feature 名稱。核心 pipeline 不需要跟著修改。

其中圖生文已提供 `MLXVLMRuntime`，可載入 `model_type` 受 `mlx-swift-lm` 支援的本機 VLM。完整的 Hugging Face MLX VLM 目錄若包含 `config.json`、Tokenizer、Safetensors 權重，且模型設定具有影像／視覺欄位，App 會自動辨識，不強制要求 `mangakitchen-model.json`。若需要自訂顯示名稱或生成參數，仍可放置 manifest 覆寫自動設定。

建議先使用約 3GB 的 `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`：

1. 將 Hugging Face 模型完整下載到本機資料夾。
2. 在 App 選擇該資料夾；第一次載入會將模型常駐記憶體，後續頁面重用同一個 container。

`mlx-swift-lm` 的 factory 依模型目錄內的 `config.json` 選擇架構，因此不能只下載單一 safetensors 檔案；tokenizer、processor、chat template 與 config 都必須保留。

## Qwen Image Edit Worker

圖生圖使用獨立 Swift Package，避免提高主 App 的最低系統版本，也能在工作完成或取消後完整釋放大型模型記憶體。套件目前需要 macOS 26：

```bash
Scripts/build-qwen-image-edit-worker.sh
```

開發環境會自動尋找：

```text
RuntimeSupport/QwenImageEditWorker/.build/release/MangaKitchenQwenImageEditWorker
```

正式 `.app` 應將它複製到 `Contents/Helpers/`。也能用 `MANGAKITCHEN_QWEN_WORKER` 指定完整路徑。

INT4 模型目錄格式：

```text
QwenImageEditModel/
  mangakitchen-model.json
  snapshot/
    vae/
    text_encoder/
    processor/
    transformer/       # INT8／FP16 必要；INT4 可保留
  quantized/
    qie-2511-dit-int4-mod8.safetensors
    qie-2511-vl7b-int4.safetensors
```

`snapshot` 來自 Qwen Image Edit 2511 基礎模型；兩個 INT4 檔來自 Swift Runtime 專用的預量化模型。這不是通用 `mlx_lm` 格式。Worker 將原圖與二值 mask 一起交給模型，生成後主 App 再以 mask 將結果合成回原圖，因此 mask 外像素不採用生成結果。

## 專案分層

```text
MangaKitchenCore
  領域資料、幾何座標、處理選項、模型與工作流協定

MangaKitchenRuntime
  氣泡 BBOX、步驟三 VLM 轉錄、閱讀順序、Core ML/Metal、遮罩、背景修補

MangaKitchenApp
  SwiftUI 視窗、WKWebView、自訂 URL Scheme、JSON Bridge、HTML/JavaScript 排版與 PNG 輸出

MangaKitchenApp/MCP
  同一 GUI process 內可開關的 MCP Streamable HTTP adapter 與服務生命週期
```

詳細決策與資料流請見 [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md)。
四階段 Swift／JavaScript／MCP 契約請見 [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)。
本次工作樹變更請見 [目前開發版更新紀錄](Documentation/RELEASE_NOTES_UNRELEASED.md)。

## 已知邊界

- 內建氣泡 BBOX 與 PP-OCRv6 Small OCR Core ML 模型，兩者均由 Apache-2.0 上游模型轉換而來；原始圖生文權重、超解析與圖生圖模型仍需由使用者另行下載與設定。OCR `.mlpackage`、字元表與相鄰的 Apache-2.0 授權聲明已納入 repository。
- 目前的自動候選偵測使用 `manga109-segmentation-bubble` Core ML 模型；暗色／彩色對話框、非封閉旁白框仍可能需要 Agent 提供精確區域。擬聲字目前刻意不納入翻譯主流程，未來若支援會採獨立偵測與排版策略。
- Metal 鄰域修補已避免以少量近距離深色樣本填回字緣，但仍是沒有圖生圖模型時的保底方案；複雜網點、漸層或跨越線稿的文字仍建議使用 inpainting 模型。
- Qwen Image Edit INT4 仍需要約 25GB 級推論記憶體，且一次頁面修補要執行完整 diffusion；低記憶體 Mac 應停用圖生圖修補。
- Swift Package 直接執行尚未加入 App Sandbox security-scoped bookmark、簽章、notarization 與正式 `.app` 封裝流程。
- 尚未加入 App Sandbox security-scoped bookmark；移動原圖或模型資料夾後，復原流程會略過失效路徑並提示。
