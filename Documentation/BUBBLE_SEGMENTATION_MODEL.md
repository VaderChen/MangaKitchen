# 氣泡分割模型

MangaKitchen 內建 `manga109-segmentation-bubble` 的 Core ML 版本，作為本機對話框候選來源。模型原始權重來自 Hugging Face 的 `huyvux3005/manga109-segmentation-bubble`，授權為 Apache-2.0。

執行時優先設定為 `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`，讓支援的層使用 Apple Neural Engine；若系統無法以此組態載入，才回退至 Core ML 預設裝置配置。

模型固定以 `1600 × 1600`、填充值 `RGB(114, 114, 114)` 的 letterbox 方式輸入。輸出的 YOLO BBOX 會反算為原圖正規化座標，並經過 NMS 後填入 `DialogueRegion.bubbleBounds`。模型的 instance segmentation mask 目前不直接輸出為遮罩；`MangaTextMaskRefiner` 仍在 BBOX 內依原始像素尋找文字筆畫，因此不會以整個對話框覆蓋人物或框線。

## 重新產生模型

先下載原始 `best.pt`，並安裝相容的 `ultralytics` 與 `coremltools`。接著於專案根目錄執行：

```bash
python3 Scripts/export-manga-bubble-coreml.py --weights /path/to/best.pt
```

指令會產生 `Sources/MangaKitchenApp/Resources/Models/MangaBubbleSegmentation.mlpackage`。這個檔案會被 Swift Package Manager 複製到 App bundle，首次使用時再由 Core ML 編譯與載入。
