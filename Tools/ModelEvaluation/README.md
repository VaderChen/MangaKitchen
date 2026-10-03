# 本機模型評估

`LocalModelEvaluationTests` 使用 App 的 `ModelRuntimeHub`、影像前處理與 `VLMRegionTranslationService`，記錄載入、每組輸入的耗時與原始回覆、翻譯結果、MLX 記憶體、程序 peak RSS、取消、卸載及重新載入。

未指定環境變數時測試會跳過，不下載模型、不變更下載清單或使用者偏好。

從專案根目錄執行已完成下載的本機模型：

```sh
MANGAKITCHEN_EVALUATION_MODEL="/absolute/path/to/model" \
MANGAKITCHEN_EVALUATION_CASES="$PWD/Tools/ModelEvaluation/text-cases.json" \
MANGAKITCHEN_EVALUATION_REPORT="$PWD/Artifacts/model-evaluation/result.json" \
  /usr/bin/swift test --build-system native --skip-update \
  --disable-automatic-resolution -j 6 --filter LocalModelEvaluationTests
```

需沿用專案可執行 MLX 的 Metal 測試環境；本次 native SwiftPM 使用既有 `Artifacts/MLXMetal/debug/mlx.metallib`，放在 `.build/arm64-apple-macosx/debug/MangaKitchenPackageTests.xctest/Contents/MacOS/` 內。此資源屬於本機建置產物，不包含在模型權重中。

案例 JSON 的 `sourceTexts` 非空、`prompt` 為 null 時，測試會透過正式翻譯服務產生繁體中文；使用固定 UUID，關閉額外校稿，保留原有的單次批次補翻行為。範例中的 `imagePath` 留空，純文字模型不讀取影像。測試 VLM 時，請改成對應漫畫頁的絕對路徑。

若要直接評估 OCR，可另外提供 JSON 案例：

```json
[
  {
    "id": "vertical-ocr",
    "imagePath": "/absolute/path/to/bubble.png",
    "sourceTexts": [],
    "prompt": "Transcribe the Japanese text. Return only a JSON array of strings. Do not translate."
  }
]
```

每次只測一個模型，避免 GPU 競爭。每個案例完成後立即保存報告；載入或生成失敗也會保存錯誤。翻譯測試檢查區域 UUID、原文保留、非空譯文與非原文照抄；OCR 只檢查非空回覆，應另外比對標準答案與回覆格式。測試通過不代表翻譯語意正確。

報告中的 `error` 是案例拋出的錯誤，XCTest 的結構斷言結果另見測試 log。`peakActiveBytes` 是 MLX 活躍配置峰值，不含閒置 cache；`peakRSSBytes` 是程序高水位，不能直接相加當作整台電腦的記憶體需求。取消後最多等待 5 秒讓背景生成程序釋放權重，`unloadSeconds` 記錄這段時間。

本次模型選擇及結果見 `Documentation/MODEL_EVALUATION_2026-10-03.md`。
