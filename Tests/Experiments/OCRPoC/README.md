# MangaKitchen OCR 獨立 PoC

此目錄只驗證 PP-OCRv6 Small 的辨識品質與 Apple Silicon 硬體分派，不會連結或修改 MangaKitchen 的任何 target。Apple Vision 不在驗證範圍內。

## 環境

- Apple Silicon Mac
- macOS 14 以上
- Python 3.12
- `uv`

```bash
cd Experiments/OCRPoC
uv sync
```

依序執行：

```bash
uv run python quality_check.py
uv run python convert_coreml.py
uv run python verify_coreml.py
uv run python benchmark_coreml.py
```

模型與結果會寫入 `.artifacts/`，不納入版本控制。Hugging Face 與 PaddleX 仍會使用各自的模型快取。

## 驗證內容

- `quality_check.py`：以官方 PaddleOCR pipeline 跑三張現有漫畫樣本，並對第二、三張人工校對的直排對話計算嚴格 CER。
- `convert_coreml.py`：從官方 safetensors 直接轉成 macOS 14 MLProgram。辨識輸入固定為 `1×3×48×320`；偵測輸入固定為 `1×3×640×416`。
- `verify_coreml.py`：用 ANE 執行實際漫畫裁切，驗證文字結果與偵測覆蓋率。
- `benchmark_coreml.py`：分別鎖定 Auto、ANE、GPU/Metal 與 CPU，輸出 warm latency 和 Core ML Compute Plan。

完整結果請見 [REPORT.md](REPORT.md)。
