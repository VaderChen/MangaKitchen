# 氣泡分割模型

MangaKitchen 內建 `manga109-segmentation-bubble` 的 Core ML 版本，作為本機對話框候選來源。模型原始權重來自 Hugging Face 的 `huyvux3005/manga109-segmentation-bubble`，授權為 Apache-2.0。

執行時優先設定為 `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`，讓支援的層使用 Apple Neural Engine；若系統無法以此組態載入，才回退至 Core ML 預設裝置配置。

模型依 Core ML image constraint 以方形、填充值 `RGB(114, 114, 114)` 的 letterbox 方式輸入。輸出的 YOLO BBOX 會反算為原圖正規化座標，並經過 NMS 後填入 `DialogueRegion.bubbleBounds`。若模型同時輸出 YOLO-seg prototype，Runtime 會以候選框的 mask coefficient 解出 instance mask，裁切並轉成 `bubbleMaskPolygons`；這些形狀同時用於遮罩裁切與文字元件篩選，避免外接矩形四角把人物、網點或框線納入處理。

每個氣泡形狀另外計算一個完全位於分割結果內的最大軸對齊矩形，保存為 `bubbleLayoutBounds`，供 HTML 譯文排版使用。`bubbleBounds` 仍保留完整外接範圍，負責遮罩搜尋邊界，兩者不可混用。模型遮罩的框線餘裕會在 prototype 解析度執行內縮；若模型沒有 prototype，則安全退回只有 BBOX 的行為。

`MangaTextMaskRefiner` 仍在 BBOX 內依原始像素尋找文字筆畫，但遮罩外擴改在像素層進行：先以亮度遲滯收進抗鋸齒邊緣，再作固定像素膨脹，最後合併成二值矩形集合。這取代逐一多邊形的向量描邊，避免斜筆畫產生灰階或扇貝狀毛邊。文字排列方向也由實際字形 BBOX 的相鄰位置判定，HTML 排版在自動模式下優先採用該結果。

## 重新產生模型

先下載原始 `best.pt`，並安裝相容的 `ultralytics` 與 `coremltools`。接著於專案根目錄執行：

```bash
python3 Scripts/export-manga-bubble-coreml.py --weights /path/to/best.pt
```

指令會產生 `Sources/MangaKitchenApp/Resources/Models/MangaBubbleSegmentation.mlpackage`。這個檔案會被 Swift Package Manager 複製到 App bundle，首次使用時再由 Core ML 編譯與載入。
