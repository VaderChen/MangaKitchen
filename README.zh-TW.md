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
- 全域設定 DLG 分為一般、進階、模型、MCP、關於；可設定介面語言、UI 色系、CPU／GPU 圖像合成、資料位置、多模態／文字定位／OCR／上色／超高解析度模型、MCP 連接埠與 IP／CIDR 白名單。
- 全域設定也可保存畫布框選顏色與預設輸出根目錄；新專案會在根目錄下建立經過清理的專案名稱子目錄，已有明確輸出位置的專案不會被覆寫。
- 每個來源目錄建立為獨立專案，可保存多個專案並由工具列快速切換。
- 選取來源目錄後遞迴掃描，保留子目錄相對路徑、自然排序並避免同名頁面衝突。
- 頁面列表支援 Command／Shift 複選、搜尋與狀態篩選；遮罩、翻譯、合成都可針對選取頁面批次執行。
- 批次工作使用單一循序佇列，顯示目前頁面、成功／失敗數量，並支援取消、清除紀錄與重試失敗頁面；逐區翻譯時同步顯示目前區域／總區域與實際進度。
- 每個專案擁有獨立的多語專有名詞表；一個原詞可保存多個 BCP-47 譯詞，翻譯時依目前目標語言自動套用。
- 四階段工作流：掃描、文字／遮罩、翻譯／排版設定、背景修補／合成；同時保留一鍵完整頁與全部頁面。
- 每張圖片對應版本化 `.str` JSON，保存文字、位置、字型、固定／自動字級與遮罩筆劃。
- 遮罩以原圖像素層膨脹收進抗鋸齒邊緣，再由正規化畫筆支援添加、擦除、復原與重做，最後輸出二值 PNG；不再對逐條向量矩形描邊，避免灰階毛邊。步驟二完成後立即顯示已清除原文字的 CPU／GPU 遮罩校對圖，不提前啟動圖生圖模型；Metal 修補會累積完整方向樣本並採亮度第 90 百分位背景色階，降低字緣或框線被填回遮罩的零碎殘留。
- 內建由 [huyvux3005/manga109-segmentation-bubble](https://huggingface.co/huyvux3005/manga109-segmentation-bubble)（Apache-2.0）匯出的 manga109 氣泡分割 Core ML 模型，優先使用 Apple Neural Engine 在本機推論產生對話框 BBOX 與氣泡形狀；形狀會裁切遮罩搜尋範圍，並計算供 HTML 排版使用的氣泡內接矩形。步驟二固定以原圖像素將這些氣泡內縮成字形遮罩；切換 OCR／VLM 偏好不會取代或改變這條遮罩流程。不使用 Apple Vision OCR，主流程也排除擬聲字、頁碼、頁尾資訊、人物與空白區。
- 步驟二不需要 PP-OCR 文字偵測或 `imageToText` VLM。Medium Det 與 VLM 定位 runtime 與遮罩產生隔離，避免切換模型導致既有氣泡與像素遮罩功能退化。
- 翻譯步驟預設使用原生 Swift／Core ML PP-OCRv6 Medium OCR，並保留已驗證的 Small recognizer 作為 fallback。各 OCR 模型的原文、信心、行框與方向仍分開保存。當 `sourceText` 空白時會採用預設 OCR 結果作為翻譯原文，但不改動座標或遮罩，也不覆寫已由 VLM、Agent 或人工確認的原文。
- GUI 翻譯固定使用已下載的多模態模型，確保可利用整頁畫面語境；原文仍可由 PP-OCR 逐區抽取或由 VLM 整區轉錄。舊專案的文生文設定會自動遷移為 `imageToText`。
- 翻譯步驟提供整頁「重新抽字」與「重新翻譯」，也可在單一文字區域旁重新抽取並翻譯；這些操作不會重建步驟二遮罩或去字背景。所有等待 DLG 都會顯示累計讀秒（`MM:SS`）。
- VLM 接受的對話框 BBOX 會以原圖像素連通元件收斂成字形遮罩，同步把文字定位框縮到未膨脹的實際字形外框；自動排版方向優先採用字形實際排列偵測結果。每個候選會獨立處理，單一候選的分類、轉錄或翻譯失敗時保留原區域並繼續其他區域；只有取消工作才會停止整體流程。
- 多模態模型的翻譯 Prompt 與嚴格 JSON 回傳解析。
- 可直接載入本機 Hugging Face MLX 多模態模型目錄，由 `mlx-swift-lm` 在 Apple Silicon／Metal 執行。
- 啟動時只登記模型路徑，實際用到對應能力時才載入。系統會比對模型 ID、能力與正規化／symlink 路徑以避免重複載入，同一能力的並行載入會序列化；載入大型模型前若 unified memory 壓力過高，會先釋放其他 runtime。
- **Think Mode (Beta)** 預設關閉。開啟後會在計算 DLG 以安全 Markdown 即時顯示短暫思考；思考內容只存在記憶體、不寫入 LOG。若第一段沒有完整 JSON，會沿用同一個已載入模型，以關閉思考、固定參數的第二段補出最終 JSON。
- 以 model manifest 載入 `.mlmodelc`、`.mlmodel` 或 `.mlpackage`，Core ML 指定 Metal GPU。
- 超高解析度提供兩個互不共用權重的模型：推薦的 `Real-ESRGAN x2plus` 原生 MLX 2×，以及可選的 `Real-ESRGAN Anime 512` 原生 Core ML 4×；2× 不會由 4× 結果降採樣冒充。完成後立即切換中央畫布、重繪既有翻譯預覽，尺寸旁以 `*` 標示 SR 產物，後續 HTML 合成與 PSD 也沿用實際 SR 尺寸。
- 獨立的四步驟上色流程使用反對話框遮罩與可下載的 DDColor Tiny Core ML；輸入優先採用已輸出的翻譯頁，沒有才回退原圖，上色狀態、預覽與輸出不覆寫翻譯流程。DDColor Tiny 不接受色彩範圍與上色模式參數，因此這兩張設定卡目前停用。
- 對話文字遮罩可由一個或多個像素級形狀覆蓋原字、裁切於對話框邊界，再疊加畫筆增刪；沒有圖生圖模型時可選 CPU 或 Metal GPU 修補。
- HTML/CSS 是翻譯排版的唯一標準，支援橫排／直排、固定或自動字級、拖曳與八方向尺寸調整；最終 PNG 由 WebKit 直接渲染同一套文字層，步驟三預覽不會在輸出時改成另一套排版。
- 編輯器支援區域新增、複製、移除、排序及每頁最多 50 份 undo／redo；畫布可水平與垂直平移，滾輪縮放以可視畫布中心為錨點，並提供適合視窗與 `1:1` 檢視。文字圖層支援顯示、透明度、旋轉、對齊、文字顏色、描邊及已安裝字型即時預覽。
- PSD 的合併預覽、逐文字 Raster Layer、乾淨背景與隱藏原圖均由 HTML/CSS 渲染結果封裝，不另做一套排版；如果已套用超高解析度，所有可用圖層會保持相同放大後尺寸。
- 專案可匯入或追加圖片、資料夾、ZIP／CBZ、RAR／CBR 與 PDF，並可重新命名、排序或從專案移除頁面；來源會複製、解包或點陣化到受管理目錄，移除不刪來源，重掃也不會自動加回。
- 原圖／輸出圖安全地透過自訂 URL Scheme 提供給 WebUI，不直接暴露任意檔案。
- 專案索引與各專案狀態自動儲存為版本化 JSON；寫入前保留上一版 `.bak`，重新啟動會驗證來源與輸出檔後復原。
- 「設定 → 進階」可保存預設輸出位置；新建且尚未指定輸出目錄的專案會在此位置下自動建立專案名稱子目錄，已有明確輸出設定的專案不會被覆寫。
- 可選的 macOS 26 Swift/MLX Qwen Image Edit worker；mask 同時作為模型條件圖與最終合成限制。
- 可選的標準 MCP Streamable HTTP server，提供翻譯／上色 tools、工作區／圖片 resources、取消與進度通知。多模態 Agent 可一次取得上色輸入與反對話框遮罩，使用自身 Provider 完成上色，再把經尺寸驗證與遮罩保護的完整頁面結果寫回 App 預覽。
- MCP 是外部 Provider 的主要擴充邊界；Agent 可使用自身支援的 Provider，再回寫完整文字與 HTML 圖層樣式，App 不維護重複的雲端 Provider 清單。
- 本機翻譯支援整頁語境草稿、整頁二次校稿、直譯稿／顯示譯文分離、角色與語氣標記、信心分數及 deterministic QA；專案可獨立調整語境、校稿、QA、直譯稿、長度策略與風格指南。
- MCP 啟用時常駐 macOS menu bar；主視窗關閉後可由 menu bar 重新開啟。
- 工具列可開啟只存在記憶體的程式 LOG 並隨時清除；下方狀態列以不重建編輯器 DOM 的 transient 更新顯示 GPU、MEMORY、解析度與畫布倍率，因此不會每秒打斷選單、文字選取或拖曳操作。
- 啟動時會檢查 GitHub 最新穩定版；「設定 → 關於」會顯示官方 GitHub 與 Releases 完整網址，並可手動「檢查新版本」。App 只允許開啟官方路徑，不會自動下載或安裝。

## 翻譯的兩種使用方式與獨立上色流程

MangaKitchen 的翻譯可由本機 GUI 或 MCP 多模態 Agent 校稿。兩者只改變「誰負責翻譯推論與編排」，共用相同專案資料與翻譯產物。每次工作都必須先建立來源目錄專案；頁面、遮罩、譯文、排版設定、專有名詞與輸出狀態都保存在該專案範圍內。上色則是狀態與輸出獨立的另一套流程。

兩種翻譯方式共同的四個步驟為：

1. **專案與頁面**：選取來源目錄、遞迴掃描圖片，建立可複選與批次處理的頁面列表。
2. **文字、遮罩與去字背景**：以內建 Core ML 氣泡分割模型定位對話框 BBOX 與形狀，再依原圖像素精修成字形遮罩並建立去字背景；此步驟不呼叫 VLM，也不允許 MCP Agent 重建區域或遮罩。使用者可在 App 添加、擦除與修正遮罩。
3. **翻譯與排版**：GUI 以內建 OCR 或所選 VLM 路徑抽取原文，再固定由多模態模型執行翻譯；可選二次校稿與語意 QA 沿用同一翻譯路徑。MCP 則由多模態 Agent 依 App 提供的工作包完成原文、翻譯與排版，結果由 App 回寫專案狀態。
4. **儲存輸出**：只把已確認的步驟三完整預覽寫入專案指定目錄，不重新執行遮罩、去字、翻譯、超高解析度或排版。

四步驟是可續作的狀態與產物契約，不是每次都要從步驟一重新執行的固定清單。GUI 與 MCP 都應先讀取 App 提供的頁面狀態與工作包，再從目前需要的任意步驟開始：已有遮罩可直接翻譯，已有譯文可直接調整排版或合成，只有某個區域需要修改時也只需更新該區域。除非使用者或 Agent 明確要求重做，已完成的區域辨識、遮罩、譯文與人工編修不應被覆蓋。

從任意步驟開始前，必須按頁面檢查實際資料，而不能只相信狀態名稱。若目標步驟缺少前置產物，就逐級回到最近一個需要補做的步驟：

- 要執行步驟四時，先檢查有效的 `.str` 譯文／排版資料與遮罩；缺少譯文則回到步驟三，缺少文字區域或遮罩則再回到步驟二。
- 要執行步驟三時，先檢查來源頁、文字區域與遮罩；原文尚為空白時會在此步驟由內建 OCR 抽取，資料不完整才回到步驟二。
- 要執行步驟二時，先檢查來源圖片仍存在且專案頁面索引有效；缺少時回到步驟一重新掃描。
- 回溯只補齊缺少或失效的資料，不重新產生仍有效的前置產物。不同頁面可以從不同步驟開始。

### 獨立的上色四步驟

上色依序為：選取頁面並優先採用既有翻譯輸出、建立與編修反對話框遮罩、以下載式 DDColor Tiny 或外部多模態 Agent 建立預覽、最後儲存既有預覽。遮罩白色區域允許上色，黑色區域保護對話框與人工擦除區。上色前仍需由 App 完成對話區域與遮罩資料，但上色的進度、預覽、清除重來與輸出不會覆寫翻譯狀態。

### 用法 A：下載模型，在本機離線運作

在「設定 → 模型」下載純文字或多模態翻譯模型，並在需要本機上色時下載 DDColor Tiny。區域辨識、原文抽取、翻譯、背景修補、合成與本機上色都在 Mac 執行；模型完成下載後，工作流不需要把漫畫內容送到外部 AI 服務。

- 翻譯模型可在純文字 `textToText` 與多模態 `imageToText` 之間選擇；前者接收 OCR／已確認的原文，後者會同時使用頁面語境。PP-OCR「重新抽字」本身不需要 VLM，擬聲字仍不進入目前的翻譯主流程。
- 「重新抽字」會更新原文並清除依賴它的譯文；「重新翻譯」沿用現有原文；單區按鈕只更新選取區域，完成後重新產生整頁預覽。
- `imageToImage` 模型負責步驟二的背景修補，屬於選用；未設定時依「設定 → 進階」使用 Metal GPU 鄰域修補或 CPU 對話框主色修補，GPU 失敗時會自動退回 CPU。
- `superResolution` 模型屬於選用；可在步驟二產生乾淨背景後手動執行，也可啟用完整流程自動放大。SR 改變實際像素尺寸，不改變畫布檢視倍率的標準計算。
- GUI 可分步執行，也可使用「完整處理選取頁／全部頁面」。一鍵功能仍只是依序執行步驟二至四，不會跳過中間資料。
- 本機上色只在上色步驟三延遲載入 `imageColorization` 模型並立即建立預覽；步驟四只儲存該預覽。
- 所有結果都回寫專案與 `.str`，可在任何步驟人工修正後重新執行後續階段。

### 用法 B：由 AI Agent 透過 MCP 校稿（推薦）

> **推薦流程：先在 App 完成翻譯步驟二，再使用 MCP 校稿。** 公開 MCP 不會代跑區域、像素遮罩或去字背景；Agent 只校對 App 工作包內既有的原文、譯文與排版，並保留已完成的遮罩與區域。

在「設定 → MCP」啟用服務，設定 port 與 IP／CIDR 用戶端白名單，再讓支援 Streamable HTTP 的 AI Agent 連線。MCP 只提供單頁工作包，不要求 Agent 自行拆解、清除或重建四個步驟。

1. 先在 GUI 開啟專案，至少完成指定頁面的步驟二區域、像素遮罩與去字背景。
2. 在「設定 → MCP」啟用服務，讓支援 Streamable HTTP 的 AI Agent 連線。
3. Agent 呼叫 `mangakitchen.workspace.open` 取得 `workspace_id`，再對指定頁面呼叫 `mangakitchen.page.prepare_agent_task`。此工具只封裝已完成的步驟二資料；若遮罩或去字背景缺少，會停止並要求使用者回 App 完成。
4. Agent 依工作包逐區處理：既有 `sourceText`／`translatedText` 視為待校稿草稿，對照原圖修正原文與翻譯，並調整 HTML 排版的尺寸、位置、字重與直橫排方向；空白欄位則重新抽取或翻譯。不得新增、刪除、合併或修改區域與遮罩。
5. Agent 以 `mangakitchen.page.submit_agent_result` 一次回傳全部區域的校稿原文、譯文與排版；App 保留步驟二遮罩、更新內部專案資料並建立步驟三預覽。只有使用者要求輸出時才呼叫 `mangakitchen.page.render`。

上色也可在 App 完成反對話框遮罩後交給 Agent：呼叫 `mangakitchen.page.prepare_colorization_task` 一次取得實際輸入與遮罩，再以 `mangakitchen.page.submit_colorization_result` 回寫完整頁面。App 會限制解碼後結果最多 20 MiB、驗證完全一致的像素尺寸、正規化 PNG 並再次套用保護遮罩；只有使用者要求輸出時才呼叫 `mangakitchen.page.render_colorization`。

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

GUI 無論 MCP 開關都會啟動；省略 `--mcp` 時使用設定 DLG 中保存的開關，`--mcp=on|off` 可覆寫本次啟動。MCP listener 綁定 `0.0.0.0`，預設連接埠為 `12080`，只接受白名單中的實際來源 IP／CIDR；預設白名單只有 `127.0.0.1`。本機 MCP 網址為 `http://127.0.0.1:12080/mcp`，也可用 `--mcp-port=<port>` 覆寫本次啟動。關閉主視窗不會結束 App，可從 menu bar 重新顯示漫畫廚房。

資料儲存位置在重新啟動後生效；`imageToText`、`imageColorization` 與 `superResolution` 模型位置選取後立即切換。MCP 開關、連接埠與白名單變更時會重新啟動 listener。

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

Core ML 與外部 Runtime 模型目錄使用 `mangakitchen-model.json`。若 Hugging Face MLX 目錄已包含完整的 `config.json`、Tokenizer 與 Safetensors，則可不放 manifest 直接推斷；只有需要明確顯示名稱或生成參數時才以 manifest 覆寫。範例位於：

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

manifest 的 feature 名稱必須與實際 Core ML 模型一致。現有 Core ML Adapter 支援：

- 圖生文：圖片 feature、可選的字串 prompt feature、字串輸出 feature。
- 圖生圖：圖片 feature、可選的 mask／prompt feature、圖片輸出 feature。
- 超解析：`TheMurusTeam/coreml-upscaler-realesrganAnime512` 的原生 4× Core ML 輸出。

上色不使用通用圖生圖契約，而是由專用 `ImageColorizing` Adapter 處理。模型下載器會取得 Apache-2.0 的 [`mlboydaisuke/DDColor-Tiny-CoreML`](https://huggingface.co/mlboydaisuke/DDColor-Tiny-CoreML)，為 `DDColor_Tiny.mlpackage` 建立 `imageColorization` manifest，並使用 `image` 輸入與 `ab_channels` 輸出。

原生 2× 超解析使用獨立的 [mlx-community/Real-ESRGAN-x2plus](https://huggingface.co/mlx-community/Real-ESRGAN-x2plus) FP16 Safetensors（BSD-3-Clause）。下載器會為它建立 `backend: mlxSwift`、`capability: superResolution`、`superResolutionScale: 2` 的 manifest，再由專用 RRDBNet runtime 執行；它與 4× Anime Core ML 模型沒有共用權重或降採樣路徑。

Core ML manifest 是對「已封裝成單次 prediction 的模型」提供的通用 Adapter。Qwen-VL 這類需要 tokenizer 與逐 token 解碼的模型會改走專用 MLX Adapter；需要 sampler loop 的擴散模型也必須使用專用 `ImageToImageGenerating` Adapter，不能只更改 Core ML feature 名稱。核心 pipeline 不需要跟著修改。

App 以 `MLXTextRuntime` 提供純文字翻譯，並以 `MLXVLMRuntime` 提供 `model_type` 受 `mlx-swift-lm` 支援的本機多模態翻譯模型。管理下載清單目前推薦純文字翻譯使用 `mlx-community/Qwen3-4B-4bit`，另提供較大的 `Qwen3-8B-4bit`；GPT-OSS 仍保留為可選模型，但因多語言翻譯品質不穩定，不再作為預設翻譯模型。完整的 Hugging Face MLX 目錄若包含 `config.json`、Tokenizer 與 Safetensors 權重，App 會依影像／視覺欄位判定能力，不強制要求 `mangakitchen-model.json`。若需要自訂顯示名稱或生成參數，仍可放置 manifest 覆寫自動設定。

多模態建議先使用約 3GB 的 `lmstudio-community/Qwen3.5-4B-MLX-4bit`：

1. 將 Hugging Face 模型完整下載到本機資料夾。
2. 在 App 選擇該資料夾；路徑會立即登記，模型則在第一次使用時載入並跨頁重用，直到記憶體壓力需要釋放。

`mlx-swift-lm` 的 factory 依模型目錄內的 `config.json` 選擇架構，因此不能只下載單一 safetensors 檔案；tokenizer、chat template 與 config 必須保留。一般多模態模型仍應保留 processor 設定；若 Qwen3.5 模型含 `vision_config` 但缺少 `processor_config.json`／`preprocessor_config.json`，factory 會從 `config.json` 推導 Qwen3VLProcessor 設定。

純文字翻譯請在「設定 → 模型 → 翻譯」選擇 Qwen3 4B 或 8B。這條流程只會把 OCR 抽出的原文交給模型，不會讀取頁面圖片；需要整頁語境時再改用多模態翻譯模型。

### DFlash 推測解碼

「設定 → 模型 → 翻譯」或「多模態」可開啟相容 Qwen3／Qwen3.5 的 DFlash。App 會從所選主模型同一個模型根目錄自動尋找 Draft，讓文字與多模態模型在相同的 Metal runtime 上執行原生 Swift／MLX DFlash 1／2 推測解碼；不需要額外選取或保存 Draft 路徑。Qwen3-VL 與 Qwen3.5-VL 會先完成視覺 prefill，再進入相同的 speculative decoding；其他 VLM 架構會安全回退標準生成。這不會取代既有 Safetensors／MLX checkpoint 或 GGUF 載入。Draft 遺失、不相容、格式錯誤、生成設定不支援或初始化失敗時，App 會記錄原因並安全回退標準生成。Draft 權重不隨 App 內建發佈。

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
  氣泡 BBOX、OCR／VLM 轉錄、Core ML／MLX 翻譯、上色、SR、遮罩、背景修補

MangaKitchenApp
  SwiftUI 視窗、WKWebView、自訂 URL Scheme、JSON Bridge、HTML/JavaScript 排版與 PNG 輸出

MangaKitchenApp/MCP
  同一 GUI process 內可開關的 MCP Streamable HTTP adapter 與服務生命週期
```

詳細決策與資料流請見 [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md)。
版本化的翻譯／上色 Swift、JavaScript 與 MCP 契約請見 [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)。
已封裝版本的英文更新紀錄請見 [MangaKitchen 1.26.0829 build 0052 Release Notes](Documentation/RELEASE_NOTES_1.26.0829-build-0052.md)；封裝後的新變更請見 [Development Release Notes](Documentation/RELEASE_NOTES_UNRELEASED.md)。

## 已知邊界

- 內建氣泡 BBOX、PP-OCRv6 Medium 預設 OCR 與 Small fallback OCR Core ML 模型，均由 Apache-2.0 上游模型轉換而來；圖生文、下載式 DDColor Tiny、超解析與實驗性圖生圖權重不隨 App 內建。DDColor Tiny 同樣採 Apache-2.0，OCR `.mlpackage`、字元表與相鄰授權聲明已納入 repository。
- 目前的自動候選偵測使用 `manga109-segmentation-bubble` Core ML 模型；暗色／彩色對話框、非封閉旁白框可能需要在 App 人工修正遮罩。標準 Agent 工作包不能修改區域或遮罩；擬聲字目前刻意不納入翻譯主流程，未來若支援會採獨立偵測與排版策略。
- Metal 鄰域修補已避免以少量近距離深色樣本填回字緣，但仍是沒有圖生圖模型時的保底方案；複雜網點、漸層或跨越線稿的文字仍建議使用 inpainting 模型。
- Qwen Image Edit INT4 仍需要約 25GB 級推論記憶體，且一次頁面修補要執行完整 diffusion；低記憶體 Mac 應停用圖生圖修補。
- Swift Package 直接執行尚未加入 App Sandbox security-scoped bookmark、簽章、notarization 與正式 `.app` 封裝流程。
- 尚未加入 App Sandbox security-scoped bookmark；移動原圖或模型資料夾後，復原流程會略過失效路徑並提示。
