# MangaKitchen 1.26.0825（build 1850）

## 主要更新

- 二次校稿現在會在第一階段翻譯結果完成保存與預覽後才開始；取消校稿不再失去已完成的翻譯。
- 校稿改為一次整頁譯文校正，統一稱謂、詞表、數字、否定、語氣與長度，不重新執行 OCR、文字抽取或逐區翻譯。
- 新增獨立的 Application 業務層與程序級 runtime 組合根，讓 GUI 與 MCP 共用相同的工作流程規則與推論資源。
- 拆解 AppStore、WebKit Bridge 與 MCP 的大型協調責任，降低狀態分歧與重複契約組裝。

## 翻譯與二次校稿

- 啟用二次校稿時，第一階段初稿會先寫入 `.str`、專案快照並產生排版預覽，第二階段才開始整頁校正。
- 校稿把既有 `sourceText` 視為正式原文，只調整整體譯文的一致性與品質。
- 使用者取消校稿或校稿失敗時，已提交的初稿與預覽仍會保留。
- 單區重新辨識不啟動二次校稿，避免把局部 OCR 流程誤當成整體譯文校正。

## 主系統與 MCP

- 新增 `MangaKitchenApplication` target，集中 artifact 完整性、頁面進度與輸出目錄安全規則。
- 新增 `MangaKitchenRuntimeEnvironment`，讓 GUI 與 MCP 共用 Metal、模型 runtime、排版器、pipeline 與 artifact 根目錄。
- 將編輯歷程、批次工作與模型生命週期分別拆至獨立協調器。
- 將 WebKit 命令路由、參數解碼與原生面板操作自 `HybridBridgeController` 拆出，並以完整命令白名單分派。
- 將 MCP 工具名稱、工作區索引及頁面契約呈現拆為獨立元件，工作流程 actor 不再同時承擔 transport、儲存及 JSON 契約組裝。

## OCR 獨立驗證

- OCR PoC 已統一整理至 `Experiments/OCRPoC/`。
- 保留 PP-OCRv6 品質檢查、Core ML 轉換及 Auto／ANE／GPU／CPU benchmark。
- Apple Vision 不在這套驗證流程內。

## 相容性

- 需要 macOS 14 或以上版本。
- 僅支援 Apple Silicon `arm64`。
- Bundle identifier：`person.vader.mangakitchen`。
- 既有專案與 `.str` 格式維持相容；本版沒有要求資料遷移。

## 封裝成品

- DMG：`MangaKitchen-1.26.0825-build-1850.dmg`
- 大小：90,906,835 bytes
- SHA-256：`fc9da785314a18b0b8c3eb3df24fad4fe2d47944efac4bb8ea0a745b6084f989`
- App 版本：`1.26.0825`（`CFBundleVersion` `1850`）
- App 與 DMG 均使用 `Developer ID Application: CHUN CHUAN CHEN (8QB2QM35YM)` 簽章。
- App 與 DMG 均已 stapled Apple notarization ticket；Gatekeeper 回報 `accepted`，來源為 `Notarized Developer ID`。

## 驗證

- `swift build` 成功。
- `git diff --check` 成功。
- App 的 `codesign --verify --deep --strict` 成功。
- DMG 的 `codesign --verify --strict` 成功。
- Gatekeeper 接受 App 與 DMG。
- App 與 DMG 的 `xcrun stapler validate` 成功。
