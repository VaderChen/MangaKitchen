# 漫畫廚房（MangaKitchen）

繁體中文 | [English](README.en.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

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
- 全域設定 DLG 分為一般、進階、模型、MCP、關於；可設定介面語言、UI 色系、CPU／GPU 圖像合成、資料位置、兩類模型、MCP 連接埠與 IP／CIDR 白名單。
- 每個來源目錄建立為獨立專案，可保存多個專案並由工具列快速切換。
- 選取來源目錄後遞迴掃描，保留子目錄相對路徑、自然排序並避免同名頁面衝突。
- 頁面列表支援 Command／Shift 複選、搜尋與狀態篩選；遮罩、翻譯、合成都可針對選取頁面批次執行。
- 批次工作使用單一循序佇列，顯示目前頁面、成功／失敗數量，並支援取消、清除紀錄與重試失敗頁面。
- 每個專案擁有獨立的多語專有名詞表；一個原詞可保存多個 BCP-47 譯詞，翻譯時依目前目標語言自動套用。
- 四階段工作流：掃描、文字／遮罩、翻譯／排版設定、背景修補／合成；同時保留一鍵完整頁與全部頁面。
- 每張圖片對應版本化 `.str` JSON，保存文字、位置、字型、固定／自動字級與遮罩筆劃。
- 遮罩以正規化向量畫筆支援添加、擦除與逐區復原，再輸出二值 PNG；步驟二完成後立即顯示已清除原文字的 CPU／GPU 遮罩校對圖，不提前啟動圖生圖模型。
- 黑白漫畫會分別執行系統 Vision OCR 與封閉白區偵測；OCR 粗框歸屬最佳封閉候選，未歸屬者保留為無框文字。所有封閉候選即使沒有 OCR 命中仍交給圖生文模型分類、轉錄，再將 OCR、VLM 與封閉框幾何合併、去重；目前主流程刻意排除擬聲字、頁碼、頁尾資訊、人物與空白區。
- 候選文字會以像素連通元件收斂成字形多邊形，再依整頁語境分批校正 OCR；原始值與校正值都保存，缺任何區域就不會誤標為完成。
- 圖生文模型的頁面語境翻譯 Prompt 與嚴格 JSON 回傳解析。
- 可直接載入本機 Hugging Face MLX VLM 目錄，由 `mlx-swift-lm` 在 Apple Silicon／Metal 執行。
- 以 model manifest 載入 `.mlmodelc`、`.mlmodel` 或 `.mlpackage`，Core ML 指定 Metal GPU。
- 對話文字遮罩可由一個或多個多邊形覆蓋原字、裁切於對話框邊界，再疊加畫筆增刪；沒有圖生圖模型時可選 CPU 或 Metal GPU 修補。
- Core Text 依原文字形位置與大小自動配適，支援橫排／直排、超長譯文優先縮字、同泡泡多區域防重疊分欄及泡泡內緣硬裁切，人工修改後可重新排版。
- 原圖／輸出圖安全地透過自訂 URL Scheme 提供給 WebUI，不直接暴露任意檔案。
- 專案索引與各專案狀態自動儲存為版本化 JSON；寫入前保留上一版 `.bak`，重新啟動會驗證來源與輸出檔後復原。
- 可選的 macOS 26 Swift/MLX Qwen Image Edit worker；mask 同時作為模型條件圖與最終合成限制。
- 可選的標準 MCP Streamable HTTP server，提供四階段 tools、工作區／圖片 resources、取消與進度通知。
- MCP 啟用時常駐 macOS menu bar；主視窗關閉後可由 menu bar 重新開啟。

## 兩種使用方式，共用同一套專案與四步驟

MangaKitchen 有兩種操作方式。它們只改變「誰負責推論與編排」，不會形成兩套資料格式或處理流程。每次工作都必須先建立來源目錄專案；頁面、遮罩、譯文、排版設定、專有名詞與輸出狀態都保存在該專案範圍內。

共同的四個步驟為：

1. **專案與頁面**：選取來源目錄、遞迴掃描圖片，建立可複選與批次處理的頁面列表。
2. **文字與遮罩**：偵測對話區域與原文、將粗框精修成字形遮罩，並由本機 LLM、Agent 或人工校正一次 OCR；使用者或 Agent 可添加、擦除與修正遮罩。
3. **翻譯與排版**：將每個區域的原文、譯文、位置、字型與字級寫入該圖片對應的 `.str`。
4. **修補與合成**：移除原字、修補背景、排入譯文，輸出到專案指定目錄。

四步驟是可續作的狀態與產物契約，不是每次都要從步驟一重新執行的固定清單。GUI 與 MCP 都應先讀取頁面狀態與 `.str`，再從目前需要的任意步驟開始：已有遮罩可直接翻譯，已有譯文可直接調整排版或合成，只有某個區域需要修改時也只需更新該區域。除非使用者或 Agent 明確要求重做，已完成的 OCR、遮罩、譯文與人工編修不應被覆蓋。

從任意步驟開始前，必須按頁面檢查實際資料，而不能只相信狀態名稱。若目標步驟缺少前置產物，就逐級回到最近一個需要補做的步驟：

- 要執行步驟四時，先檢查有效的 `.str` 譯文／排版資料與遮罩；缺少譯文則回到步驟三，缺少文字區域或遮罩則再回到步驟二。
- 要執行步驟三時，先檢查來源頁、文字區域、已完成單次校正的 OCR 原文與遮罩；資料不完整就回到步驟二。
- 要執行步驟二時，先檢查來源圖片仍存在且專案頁面索引有效；缺少時回到步驟一重新掃描。
- 回溯只補齊缺少或失效的資料，不重新產生仍有效的前置產物。不同頁面可以從不同步驟開始。

### 用法 A：下載模型，在本機離線運作

在「設定 → 模型」指定圖生文模型，以及選用的圖生圖模型。OCR、翻譯、背景修補與合成都在 Mac 本機執行；模型完成下載後，工作流不需要把漫畫內容送到外部 AI 服務。

- `imageToText` 模型負責步驟二候選聯絡表的標題／對話語意分類、無 OCR 封閉區域補完、完整 OCR 校正，以及步驟三的頁面語境翻譯；系統 OCR、VLM 與封閉框會先合併去重。未載入模型時系統 OCR 仍可獨立建立遮罩；擬聲字不進入目前的翻譯主流程，校正與翻譯會分批並驗證每個區域都有結果。
- `imageToImage` 模型負責步驟四的背景修補，屬於選用；未設定時依「設定 → 進階」使用 Metal GPU 鄰域修補或 CPU 對話框主色修補，GPU 失敗時會自動退回 CPU。
- GUI 可分步執行，也可使用「完整處理選取頁／全部頁面」。一鍵功能仍只是依序執行步驟二至四，不會跳過中間資料。
- 所有結果都回寫專案與 `.str`，可在任何步驟人工修正後重新執行後續階段。

### 用法 B：由 AI Agent 透過 MCP 完成

在「設定 → MCP」啟用服務，設定 port 與 IP／CIDR 用戶端白名單，再讓支援 Streamable HTTP 的 AI Agent 連線。Agent 仍必須以 MCP 的 workspace／project 與四階段狀態操作，不能繞過專案資料直接產生不受管理的輸出；但可以依既有產物從任意步驟續作，不必重跑已完成階段。

對全新、尚未處理的專案，不下載本機圖生文模型時，Agent 可依下列方式完成翻譯：

1. 呼叫 `mangakitchen.workspace.open` 建立工作區並取得 `workspace_id`。
2. 呼叫 `mangakitchen.page.detect_masks` 完成 OCR 與遮罩。
3. 讀取頁面與原圖 resource，比對目前區域；發現漏字或漏框時，以 `mangakitchen.page.supplement_regions` 批次送入遺漏文字粗框與原文。後端會自動精修字形遮罩、去除重複區域並同步 `.str`；Agent 也可直接提供精確多邊形。
4. 對既有區域，若 `ocrTextRefined` 為 false，Agent 必須先校正 `rawSourceText`，再翻譯，並以 `mangakitchen.region.update` 同時寫回每區的 `source_text`、譯文與排版設定。
5. 呼叫 `mangakitchen.page.compose` 完成背景修補與輸出。

若本機也已載入 `imageToText` 模型，Agent 可以改呼叫 `mangakitchen.page.translate`，或使用 `mangakitchen.page.run_full` 編排步驟二至四。`page.run_full` 需要本機圖生文模型；純 Agent 翻譯模式應採用 `detect_masks → supplement_regions → region.update → compose`，沒有遺漏區域時可略過 `supplement_regions`。

對既有專案，Agent 應先讀取 workspace、page 與 `.str` resource 判斷目前進度及實際產物，再只呼叫需要的 tool。例如 `maskReady` 且遮罩檔有效時可直接從翻譯或 `region.update` 開始，`translationReady` 且譯文完整時可直接 `compose`，已輸出的頁面也能只修改單一區域後重新合成。若檢查發現資料缺失，Agent 必須依上述規則逐級回溯；純 Agent 模式回溯到步驟三時，由 Agent 補譯並呼叫 `region.update`，不強制改用本機模型。

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
  Vision OCR、閱讀順序、Core ML/Metal、遮罩、背景修補、Core Text 排版

MangaKitchenApp
  SwiftUI 視窗、WKWebView、自訂 URL Scheme、JSON Bridge、HTML/JavaScript

MangaKitchenApp/MCP
  同一 GUI process 內可開關的 MCP Streamable HTTP adapter 與服務生命週期
```

詳細決策與資料流請見 [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md)。
四階段 Swift／JavaScript／MCP 契約請見 [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)。

## 已知邊界

- 專案沒有內附模型權重；模型大小、授權與下載策略應在選定正式模型後加入。
- 目前的自動候選偵測以黑白漫畫的封閉亮色區域為主；暗色／彩色對話框、非封閉旁白框仍適合再接 segmentation 模型。擬聲字目前刻意不納入翻譯主流程，未來若支援會採獨立偵測與排版策略。
- Metal 鄰域修補是沒有圖生圖模型時的保底方案，複雜網點或跨越線稿的文字仍建議使用 inpainting 模型。
- Qwen Image Edit INT4 仍需要約 25GB 級推論記憶體，且一次頁面修補要執行完整 diffusion；低記憶體 Mac 應停用圖生圖修補。
- Swift Package 直接執行尚未加入 App Sandbox security-scoped bookmark、簽章、notarization 與正式 `.app` 封裝流程。
- 尚未加入 App Sandbox security-scoped bookmark；移動原圖或模型資料夾後，復原流程會略過失效路徑並提示。
