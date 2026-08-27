# GGUF Backend POC

這個 POC 用 llama.cpp 的 `gguf.cpp`／`ggml` parser 驗證 GGUF 結構，並與正式 runtime 的 MLX 原生 parser 對照。它不取代既有 Safetensors／MLX checkpoint 載入方式，也不會被 App 當作未打包的外部 runtime。

目前邊界只到 GGUF 權重解析與材料化驗證：

- 正式 MLX 能力表包含 `F32`、`F16`、`I8`、`I16`、`I32`、`Q1_0`、`Q2_0`、`Q2_K`、`Q3_K`、`Q4_0`、`Q4_1`、`Q4_K`、`Q5_K`、`Q6_K`、`Q8_0`；Swift 的 `GGUFStoragePolicy` 是唯一事實來源。
- `Q4_0`、`Q4_1` 保留為原生 `INT4`，`Q8_0` 保留為原生 `INT8`；不要把它們與 `Q4_K`、`Q8_K` 混用。正式 Swift loader 會依 `Q1_0`、`Q2_0`、`Q2_K`、`Q3_K`、`Q4_K` 來源 block 直接建立 MLX affine `INT4`，並依 `Q5_K`、`Q6_K` 來源 block 直接建立 `INT8`，不配置整顆反量化的 `Float16` tensor。
- 原生 `I8`、`I16`、`I32`、`F16`、`F32` 保留原型別；`Q8_K`、IQ、TQ 與其他未列入能力表的型別會在 inspect、manifest 推斷與 runtime 選檔時拒絕。
- `F16`／`F32` 不會降級；跨格式策略對可辨識的 `FP8`（`F8_E4M3`／`F8_E5M2`）採 `INT8` 重新量化。llama.cpp 標準 GGUF 目前沒有獨立的 FP8 tensor type，因此 POC 不會把未知 enum 當成 FP8，實際解碼要等 parser 提供明確 encoding。
- `storageType` 是材料化計畫，不是把所有 tensor 轉成同一 dtype；`preservesSourceQuantization` 可確認是否直接沿用 GGUF 的量化 block。
- POC 尚不負責建立 `ModelContainer`。正式 App 只走 MLX 原生 GGUF loader；llama.cpp bridge 僅供本目錄的 parser 對照與診斷。

## 建置

需要已建置的 llama.cpp checkout 與 CMake：

```bash
cmake -S Tools/GGUFBackendPOC -B /tmp/mangakitchen-gguf-backend-build \
  -DLLAMA_CPP_ROOT=/tmp/mangakitchen-llama-cpp-poc \
  -DLLAMA_CPP_BUILD=/tmp/mangakitchen-llama-cpp-build
cmake --build /tmp/mangakitchen-gguf-backend-build --config Release
```

若 llama.cpp 使用不同 build 目錄，請調整 `LLAMA_CPP_BUILD`。輸出檔為：

```text
/tmp/mangakitchen-gguf-backend-build/gguf-backend-poc
```

## 使用

```bash
/tmp/mangakitchen-gguf-backend-build/gguf-backend-poc \
  --mode inspect --file /path/to/model.gguf

/tmp/mangakitchen-gguf-backend-build/gguf-backend-poc \
  --mode probe --file /path/to/model.gguf --tensor blk.0.ssm_out.weight

/tmp/mangakitchen-gguf-backend-build/gguf-backend-poc \
  --mode probe --file /path/to/model.gguf --tensor blk.0.ssm_out.weight --stats
```

`inspect` 會輸出 version、alignment、data offset、metadata／tensor 數量、正規化後的 shape、offset、byte size、建議 storage type 與能力表中的可否材料化。`probe` 預設只驗證來源 tensor 與材料化計畫，不建立 F32 緩衝區；加上 `--stats` 才會額外以 F32 解碼少量統計資料。`--storage` 可指定 `INT4`、`INT8`、`INT16`、`INT32`、`FP16` 或 `FP32`；POC 不執行重新量化，正式 Swift loader 會依上述計畫交給 MLX 量化算子。

## 正式模型資產契約

GGUF loader 會優先使用主 `.gguf` 內嵌的 model metadata、vocabulary、merges 與 special tokens，外部 `config.json`、`tokenizer.json`、`tokenizer_config.json` 僅作 fallback。完整 metadata 的純文字模型可以只用單一 `.gguf` 建立 `ModelContainer`；外部 tokenizer fallback 至少需要 `tokenizer.json`。多模態模型還需要配對的 `mmproj`，processor 設定缺少時會由 `mmproj` metadata 建立基本設定。下載器仍會把可用的 Hugging Face runtime 資產列為模型的一部分。

## Swift smoke CLI

`GGUFSmoke` 的 `--file` 或 `--directory` 必須明確指定，不再含個人電腦預設路徑：

```bash
swift run GGUFSmoke --file /path/to/model.gguf
swift run GGUFSmoke --file /path/to/model.gguf --mmproj /path/to/mmproj.gguf --load
swift run GGUFSmoke --file /path/to/model.gguf --mmproj /path/to/mmproj.gguf \
  --load --benchmark --image /path/to/image.png --tokens 128
```

若要量測既有 Safetensors／MLX checkpoint，改用 `--directory`，不會經過 GGUF inspect：

```bash
swift run GGUFSmoke --directory /path/to/mlx-model --load
```

## Qwen3.8 27B 實測

以下是同一台 Apple Silicon Mac、同一張 `Samples/Gemini_Image_001.jpeg`、同一個 prompt 與 128 token 上限下，`GGUFSmoke` 的實測結果。RSS 是 CLI 在載入完成當下取得的 process peak RSS；首 token 與速度由 MLX runtime 的 `Generation Metrics` 提供。

| 路徑 | 載入時間 | 峰值 RSS | 首 token | Prompt | Generation |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Qwen3.8-27B-GGUF` | 11.02 s | 18.41 GiB | 1.04 s | 65.20 tok/s | 6.19 tok/s |
| `Qwen3.8-27B-MLX-4bit` | 4.24 s | 15.15 GiB | 1.01 s | 73.81 tok/s | 10.27 tok/s |

兩者實際停止 token 數不同，速度欄位採 runtime 回報值，不以整體 benchmark wall time 直接替代。GGUF 的重新量化會增加首次載入成本與峰值記憶體；若設備記憶體不足，應優先使用既有 MLX checkpoint。數據會隨硬體、OS、MLX 版本與記憶體壓力變動。

合成 fixture 的數值驗證結果如下：

| 型別 | MLX 目標 | max abs error | relative error |
| --- | --- | ---: | ---: |
| `Q2_K` | `INT4` | 0.1992 | 0.0332 |
| `Q3_K` | `INT4` | 0.1992 | 0.0332 |
| `Q4_K` | `INT4` | 0 | 0 |
| `Q5_K` | `INT8` | 0.0039 | 0.00026 |
| `Q6_K` | `INT8` | 0.09375 | 0.00293 |

`--benchmark` 會輸出兩組 measurement：`load` 包含載入秒數與當下 process peak RSS，`generation` 包含首 token 延遲、prompt tokens/sec 與 generation tokens/sec。MLX runtime 的量化與生成由 Metal GPU 執行；CPU 只負責檔案 I/O、metadata 解析與模型結構建立。請用相同 prompt、圖片與 token 上限，分別對 GGUF 與既有 Safetensors／MLX checkpoint 執行：

```bash
swift run GGUFSmoke --directory /path/to/gguf-model \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128
swift run GGUFSmoke --directory /path/to/mlx-model \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128
```

要比較 GGUF 量化群組大小，可在 `GGUFSmoke` 加上 `--gguf-group-size 64`。這是開發診斷用的載入設定；`group64` 會由 Metal 直接從 GGUF raw block 解碼並量化，不會先建立 `group32` 再轉換。正式 App 預設使用 `group64`，Smoke 工具仍可用 `--gguf-group-size 32` 作為相容性基準。

若要保留作業系統級的獨立核對，可另外使用 macOS `/usr/bin/time -l`；CLI 自身的 `peakRSSBytes` 已足以在同一個 process 中回報載入當下的峰值。
