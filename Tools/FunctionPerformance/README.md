# 函式效能與輸出相容性量測

從專案根目錄執行：

```sh
/usr/bin/python3 Tools/FunctionPerformance/run.py \
  --baseline 519ebc2 --output Artifacts/function-performance --runs 3
```

需要 Xcode 的 Swift／Core ML 工具鏈與 repository 內的氣泡分割模型及 `Samples/Gemini_Image_001.jpeg`。不需下載模型或安裝 Python 套件。腳本只寫入指定的輸出目錄，不變更 App 設定。

腳本從指定 Git revision 取出原版 CPU 去字、遮罩精修、氣泡分割與批次狀態程式，以相同 `swiftc -O -swift-version 6` 編譯原版與工作目錄版。兩者共用目前 Core 型別、ImageIO、MaskDilation 與字向判斷。WebBatchJob 從實際 WebState 宣告擷取，不另寫一套替代演算法。比較基準必須仍包含這些 API。

五個測例依序執行，每輪各開一個原版與新版程序，不平行量測：

| mode | 工作與計時範圍 |
| --- | --- |
| `clean-auto` | 2048×3072、3,150 個分離筆畫，整區估算底色並輸出 PNG；不含建立輸入圖 |
| `clean-fixed` | 相同筆畫，以固定白色去字並輸出 PNG |
| `refine` | 2048×3072、3,150 個較大字形，完成像素精修；不含最終 JSON 序列化 |
| `bubbles` | 內建 Core ML 模型處理 repository 漫畫圖；先暖機，再取 5 次偵測平均，不含載入／編譯 |
| `jobs` | 5,000 頁、200 個工作，重建批次狀態 10 次取平均；不含 JSON 序列化與 WebKit 呈現 |

每個 mode 的原版／新版輸出都以 SHA-256 核對；PNG 比對整份檔案，JSON 比對全部欄位、數值與陣列順序。任一不一致或程序失敗即停止，不產生成功結論。密集合成頁與大型工作佇列用於放大函式成本，不能代表一般漫畫的平均負載。

`results.json` 保存秒數、程序 peak RSS bytes 與 SHA-256；每輪完整 `/usr/bin/time -l` 輸出另存 log。RSS 包含輸入圖建立、模型暖機及輸出序列化等整個程序的高水位，與計時區間不同。沒有清除作業系統快取，也不量測整個 GUI 的 RAM 或 LLM token/s。

本輪數據及覆核範圍見 [函式最佳化報告](../../Documentation/FUNCTION_OPTIMIZATION_2026-10-03.md)。
