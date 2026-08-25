# MangaKitchen Development Release Notes

The current packaged build is documented in [MangaKitchen 1.26.0824 (build 1739)](RELEASE_NOTES_1.26.0824-build-1739.md).

Use this file for changes made after build 1739 and before the next release artifact is produced.

## 主系統結構

- 新增 `MangaKitchenApplication` target，集中 GUI、MCP 與未來 CLI 可共用的業務規則；檔案狀態、工作流程進度及輸出目錄安全邊界不再由入口層各自判斷。
- 新增程序內唯一的 `MangaKitchenRuntimeEnvironment` 組合根，讓 GUI 與 MCP 共用 Metal、模型 runtime、排版器、工作流程 pipeline 與 artifact 根目錄。
- 將 `AppStore` 的編輯歷程、批次工作與模型生命週期分別拆至 `AppEditingHistory`、`AppBatchWorkflowCoordinator` 及 `AppModelLifecycleCoordinator`。
- 將 WebKit 命令路由、參數解碼與原生面板操作自 `HybridBridgeController` 拆出，並以完整命令白名單分派至 App 業務能力。
- 將 MCP 的工具名稱、工作區索引及頁面契約呈現拆為獨立元件，避免工作流程 actor 同時承擔 transport、儲存及 JSON 契約組裝責任。

## 翻譯與二次校稿

- 啟用二次校稿時，第一階段翻譯初稿會先寫入 `.str`、專案快照並產生排版預覽，之後才進入校稿。
- 二次校稿改為一次整頁譯文校正；既有 `sourceText` 是正式原文，不重新執行 OCR、文字抽取或逐區翻譯。
- 使用者取消校稿，或校稿本身失敗時，已提交的第一階段翻譯與預覽仍會保留。
- 單區重新辨識不啟動二次校稿，避免把單區處理誤當成整體翻譯校正。

## 獨立驗證專案

- 將兩份分歧的 OCR PoC 整理至單一 `Experiments/OCRPoC/`，保留 PP-OCRv6 品質檢查、Core ML 轉換及 ANE／GPU／CPU benchmark；Apple Vision 不在驗證範圍內。

## 驗證

- 主專案已通過 `swift build`；既有 MLX bundle creator 警告不影響建置完成。
