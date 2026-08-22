# MangaKitchen 開發版更新紀錄

> 本文件對應目前工作樹，尚未產生正式 `.app`、DMG、簽章或建置編號。請在本機完成建置與驗證後，再建立正式版本標籤與下載檔案。

## 主要更新

- 新增原生 Swift／Core ML PP-OCRv6 Small OCR runtime。OCR 在既有 VLM 區域內產生候選原文、信心、文字行與閱讀方向，依模型 ID 保存於 `ocrResults`，不覆寫 VLM 的 `sourceText`、座標、氣泡形狀或遮罩。
- 新增整頁「重新抽字」與「重新翻譯」，以及單一文字區域重新抽取／翻譯。重新抽字會清除依賴原文的舊譯文；重新翻譯沿用現有原文；單區操作不重建步驟二產物。
- 沒有可用 `imageToText` 模型時，進入遮罩步驟會提示手動模式，建立與原圖同尺寸的全黑遮罩，並讓使用者使用畫筆編輯；需要模型的重新計算、抽字與翻譯操作會停用。
- 等待 DLG 顯示累計讀秒（`MM:SS`），逐區工作仍顯示目前區域／總區域與頁面進度。
- 抹除底色新增 `AUTO` 自動估算模式，同時保留純白、冷白、暖白、象牙與新聞紙等固定底紙顏色，以及步驟一滴管取色。
- 全域設定新增畫布框選顏色與預設輸出根目錄。新專案會在根目錄下建立安全化的專案名稱子目錄；既有專案已明確指定的輸出位置不會被覆寫。
- MCP／`.str` 資料模型新增 `mcpExtractedSourceText`，清楚區分 MCP Agent 的原文抽取與本機 VLM／OCR 候選。
- 翻譯品質警告、模型設定分頁、下一步／下一頁導覽與相關介面文字同步更新繁中、英文、日文與韓文。

## OCR 模型與 PoC

- `Tests/Experiments/OCRPoC/` 保存 PP-OCRv6 Small 的品質、Core ML 轉換與 ANE／GPU／CPU 基準驗證腳本；`.artifacts/`、原始模型權重與 Python 快取不納入版本控制。
- OCR 字元表與轉換後的 `Sources/MangaKitchenApp/Resources/Models/OCR/ppocrv6-small-rec-macos14.mlpackage` 已隨原始碼保存；模型目錄內附 Apache-2.0 授權副本與轉換說明。

## 相容性與建置

- 最低系統版本維持 macOS 14。
- 既有 `.str` 與專案快照可缺省新增欄位，讀取時會採用相容預設值；`AUTO` 只作為抹除底色 sentinel，不會與明確的 `#FFFFFF` 混淆。
- 本次尚未執行完整建置或簽章；請依 [README 的執行說明](../README.md#running) 在本機建置並執行測試。
