import CoreGraphics
import Foundation
import MangaKitchenCore

/// 在封閉區域或 Agent 粗框內以亮度與連通元件尋找實際文字筆畫。
/// 這一層刻意不判讀語言，黑白、灰階及彩色漫畫可共用同一套流程。
public actor MangaTextMaskRefiner: DialogueMaskRefining {
    /// 字形遮罩外框相對於整頁的最大面積。過度寬鬆時，分鏡底線只要和幾個
    /// 黑色元件相連，就可能形成橫跨多格的帶狀遮罩。
    private static let maximumMaskAreaPerTextCharacter = 0.003
    private static let inkThresholdOffset = 6
    private static let maximumInkThreshold = 192
    /// 抗鋸齒過渡帶的亮度上限。掃描與 JPEG 會在筆畫外緣留下一圈比留白稍暗的像素，
    /// 硬門檻永遠切在這圈中間，塗白後就成為肉眼看得到的灰色毛邊。
    private static let softEdgeThreshold = 216
    /// 遲滯擴張的最大輪數，等於過渡帶最多往外吃幾個像素。
    private static let softEdgeGrowthLimit = 3
    private let searchPaddingPixels: Int
    private let componentPaddingPixels: Int
    private let maximumComponentsPerRegion: Int
    private let maskDilationPixels: Int

    public init(
        searchPaddingPixels: Int = 2,
        componentPaddingPixels: Int = 0,
        maximumComponentsPerRegion: Int = 256,
        maskDilationPixels: Int = 2
    ) {
        self.searchPaddingPixels = max(0, searchPaddingPixels)
        self.componentPaddingPixels = max(0, componentPaddingPixels)
        self.maximumComponentsPerRegion = max(1, maximumComponentsPerRegion)
        self.maskDilationPixels = max(0, maskDilationPixels)
    }

    public func refineMasks(
        sourceURL: URL,
        regions: [DialogueRegion]
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else { return [] }
        let image = try CGImageIO.load(from: sourceURL)
        let raster = try GrayscaleRaster(image: image)

        return regions.map { region in
            var refined = region
            guard let result = refinement(for: region, raster: raster),
                  !result.polygons.isEmpty else {
                refined.maskPolygons = []
                // 像素精修失敗只代表無法縮到筆畫級，不代表 VLM／封閉框粗遮罩
                // 無效。保留原本 automaticMaskEnabled，讓生成器回退到 region.bounds；
                // 舊邏輯直接設 false，翻譯重建遮罩時會整區漏掉。
                refined.maskRefinementApplied = false
                refined.maskCoverageRatio = nil
                refined.maskCoverageComplete = false
                return refined
            }
            // 合理性判斷與文字區域都必須用未膨脹的字形外框。改用膨脹後的遮罩外框，
            // 等於把安全餘裕算進「每字面積」，長句子的遮罩會因此被整個丟掉。
            guard let pixelBounds = result.glyphBounds,
                  Self.isPlausibleMaskBounds(pixelBounds, for: region.sourceText) else {
                refined.maskPolygons = []
                // 不採用不合理的精修結果，但仍保留原始粗遮罩作安全回退。
                refined.maskRefinementApplied = false
                refined.maskCoverageRatio = nil
                refined.maskCoverageComplete = false
                return refined
            }
            refined.maskPolygons = result.polygons
            let clippedBounds = region.bubbleBounds
                .map { pixelBounds.intersection(with: $0) }
                ?? pixelBounds
            if clippedBounds.width > 0, clippedBounds.height > 0 {
                refined.bounds = clippedBounds
            }
            // coverageComplete 是「粗框是否完整包住所有前景」的診斷，不是
            // 字形多邊形的安全開關。大型誤判已由 isPlausibleMaskBounds
            // 排除；通過該檢查的部分字形仍應顯示與輸出，否則只要
            // 有小筆畫接觸搜尋邊界，整頁遮罩就會變成全黑。
            refined.automaticMaskEnabled = true
            refined.maskRefinementApplied = true
            refined.maskCoverageRatio = result.coverageRatio
            refined.maskCoverageComplete = result.coverageComplete
            refined.detectedWritingDirection = result.writingDirection
            return refined
        }
    }

    private static func normalizedBounds(
        of boundsList: [PixelBounds],
        width: Int,
        height: Int
    ) -> NormalizedRect? {
        guard let first = boundsList.first else { return nil }
        let union = boundsList.dropFirst().reduce(first) {
            PixelBounds(
                minX: min($0.minX, $1.minX),
                minY: min($0.minY, $1.minY),
                maxX: max($0.maxX, $1.maxX),
                maxY: max($0.maxY, $1.maxY)
            )
        }
        let rect = NormalizedRect(
            x: Double(union.minX) / Double(width),
            y: Double(union.minY) / Double(height),
            width: Double(union.width) / Double(width),
            height: Double(union.height) / Double(height)
        ).clamped()
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private static func isPlausibleMaskBounds(
        _ bounds: NormalizedRect,
        for text: String
    ) -> Bool {
        let visibleCharacterCount = text.reduce(into: 0) { count, character in
            guard !character.isWhitespace, !character.isNewline else { return }
            count += 1
        }
        guard visibleCharacterCount > 0 else {
            return bounds.width > 0 && bounds.height > 0 && bounds.width * bounds.height <= 0.15
        }
        let areaPerCharacter = bounds.width * bounds.height / Double(visibleCharacterCount)
        return areaPerCharacter <= maximumMaskAreaPerTextCharacter
    }

    private func refinement(
        for region: DialogueRegion,
        raster: GrayscaleRaster
    ) -> PixelMaskRefinement? {
        let imageBounds = PixelBounds(minX: 0, minY: 0, maxX: raster.width, maxY: raster.height)
        let coarseBounds = pixelBounds(
            for: region.bounds,
            width: raster.width,
            height: raster.height
        ).expanded(by: searchPaddingPixels).intersection(imageBounds)
        let bubbleBounds = region.bubbleBounds.map {
            pixelBounds(for: $0, width: raster.width, height: raster.height)
                .intersection(imageBounds)
        }
        // 有氣泡時不得越界；無框文字只靠下方的兩輪局部擴張控制範圍。
        let clippingBounds = bubbleBounds ?? imageBounds
        let bubbleMask = BubbleMask(
            polygons: region.bubbleMaskPolygons,
            imageWidth: raster.width,
            imageHeight: raster.height
        )
        let initialSearchBounds = coarseBounds.intersection(clippingBounds)
        var searchBounds = initialSearchBounds
        var best = refinement(
            in: searchBounds,
            clippingBounds: clippingBounds,
            imageBounds: imageBounds,
            raster: raster,
            bubbleMask: bubbleMask,
            // VLM 粗框可能貼著字形，先保留碰界元件供擴張判斷。
            rejectsBoundaryComponents: false
        )

        // grounding 粗框只在必要時小幅擴張，最多兩輪。過去一碰界就搜尋
        // 整個 bubbleBounds，會把臉、頭髮與速度線一併當成字形。
        for _ in 0..<2 where best == nil || best?.touchesSearchBoundary == true {
            // 擴張量必須依短邊計算。橫排大字可能很寬但只有數十像素高；若使用
            // 長邊，會一次向上下擴張近半個字高並吃到人物、速度線與分鏡內容。
            let shortSide = min(searchBounds.width, searchBounds.height)
            let padding = max(4, min(32, Int((Double(shortSide) * 0.08).rounded(.up))))
            let expandedBounds = searchBounds
                .expanded(by: padding)
                .intersection(clippingBounds)
                .intersection(imageBounds)
            guard expandedBounds != searchBounds else { break }
            searchBounds = expandedBounds
            if let expanded = refinement(
                in: searchBounds,
                clippingBounds: clippingBounds,
                imageBounds: imageBounds,
                raster: raster,
                bubbleMask: bubbleMask,
                // 擴張後真正的字形應已離開搜尋邊界；仍碰邊的通常是框線、
                // 分鏡線或延伸到插畫內的輪廓，不可納入遮罩。
                rejectsBoundaryComponents: true
            ) {
                best = expanded
            }
        }
        return best
    }

    private func refinement(
        in searchBounds: PixelBounds,
        clippingBounds: PixelBounds,
        imageBounds: PixelBounds,
        raster: GrayscaleRaster,
        bubbleMask: BubbleMask?,
        rejectsBoundaryComponents: Bool
    ) -> PixelMaskRefinement? {
        guard searchBounds.width > 0, searchBounds.height > 0 else { return nil }

        let histogram = raster.histogram(in: searchBounds)
        let threshold = min(
            Self.maximumInkThreshold,
            max(48, otsuThreshold(histogram) + Self.inkThresholdOffset)
        )
        let sampleCount = max(searchBounds.width * searchBounds.height, 1)
        let foregroundCount = histogram.prefix(threshold + 1).reduce(0, +)
        let foregroundRatio = Double(foregroundCount) / Double(sampleCount)

        // 候選區若大部分都是暗色，通常落在插畫或實心擬聲字上；
        // 傳統二值化無法安全區分筆畫與背景，此時保留原始粗框供模型或人工修訂。
        guard foregroundRatio > 0.001, foregroundRatio < 0.55 else { return nil }

        let components = connectedComponents(
            raster: raster,
            bounds: searchBounds,
            threshold: threshold
        )
        let minimumArea = max(2, Int(Double(sampleCount) * 0.00006))
        let candidates = components.filter { $0.area >= minimumArea }
        let structuralComponents = candidates.filter { component in
            let spansWidth = Double(component.bounds.width) / Double(searchBounds.width) >= 0.72
            let spansHeight = Double(component.bounds.height) / Double(searchBounds.height) >= 0.72
            let fillRatio = Double(component.area)
                / Double(max(component.bounds.width * component.bounds.height, 1))
            return (spansWidth || spansHeight) && fillRatio < 0.45
        }
        let structuralIDs = Set(structuralComponents.map(\.id))
        var contentComponents = candidates.filter { !structuralIDs.contains($0.id) }
        // 矩形框的四角落在氣泡外，那裡的頭髮、網點與分鏡線都不是台詞。
        if let bubbleMask {
            contentComponents = contentComponents.filter { bubbleMask.coverage(of: $0) >= 0.6 }
        }
        // 擴張到整個對話框內緣時，接觸安全邊界的元件通常是泡泡框線、
        // 人物輪廓或分鏡線，而不是位於留白中的文字。它們可參與「邊界太窄」
        // 的診斷，但不可直接成為遮罩，否則會把泡泡外框一併抹除。
        let boundaryTolerance = max(1, componentPaddingPixels)
        let boundaryComponents = rejectsBoundaryComponents
            ? contentComponents.filter { $0.bounds.touches(searchBounds, tolerance: boundaryTolerance) }
            : []
        let boundaryIDs = Set(boundaryComponents.map(\.id))
        var filtered = rejectsBoundaryComponents
            ? contentComponents.filter { !boundaryIDs.contains($0.id) }
            : contentComponents
        guard !filtered.isEmpty else { return nil }
        // 元件數超過上限時，只取面積最大的前 N 個，不要整個放棄。
        // 原本超過就 return nil，等於「字愈多愈沒有遮罩」—— 字數最多的氣泡
        // 最需要遮罩，卻正好最容易觸發上限，實測就是這樣整顆漏掉的。
        if filtered.count > maximumComponentsPerRegion {
            filtered = Array(
                filtered.sorted { $0.area > $1.area }.prefix(maximumComponentsPerRegion)
            )
        }

        let coveredForegroundCount = filtered.reduce(0) { $0 + $1.area }
        let ignoredStructuralForegroundCount = structuralComponents.reduce(0) { $0 + $1.area }
        let ignoredBoundaryForegroundCount = boundaryComponents.reduce(0) { $0 + $1.area }
        let relevantForegroundCount = max(
            foregroundCount
                - ignoredStructuralForegroundCount
                - ignoredBoundaryForegroundCount,
            1
        )
        let coverageRatio = min(
            1,
            Double(coveredForegroundCount) / Double(relevantForegroundCount)
        )
        // 已知對話框內緣時，接觸邊界的元件視為泡泡框線並保留；真正要清除的
        // 文字元件仍不得接觸搜尋邊界，避免粗框截斷字形。
        let touchesSearchBoundary = filtered.contains {
            $0.bounds.touches(searchBounds, tolerance: boundaryTolerance)
        }
        // 膨脹必須在像素層做。過去是把每一條 run rectangle 各自向量描邊再聯集，
        // 斜筆畫拆出的一堆 1px 高矩形分別鼓起來，遮罩邊界就變成扇貝狀毛邊。
        let maskPixels = grownMaskPixels(
            components: filtered,
            raster: raster,
            bounds: searchBounds,
            bubbleMask: bubbleMask
        )
        let polygons = mergedPixelRectangles(for: maskPixels).map { pixelRectangle -> [NormalizedPoint] in
            let bounds = pixelRectangle
                .expanded(by: componentPaddingPixels)
                .intersection(clippingBounds)
                .intersection(imageBounds)
            let minX = Double(bounds.minX) / Double(raster.width)
            let minY = Double(bounds.minY) / Double(raster.height)
            let maxX = Double(bounds.maxX) / Double(raster.width)
            let maxY = Double(bounds.maxY) / Double(raster.height)
            return [
                NormalizedPoint(x: minX, y: minY),
                NormalizedPoint(x: maxX, y: minY),
                NormalizedPoint(x: maxX, y: maxY),
                NormalizedPoint(x: minX, y: maxY)
            ]
        }
        return PixelMaskRefinement(
            polygons: polygons,
            writingDirection: MangaTextDirectionDetector.direction(
                forGlyphBoxes: filtered.map {
                    CGRect(
                        x: Double($0.bounds.minX),
                        y: Double($0.bounds.minY),
                        width: Double($0.bounds.width),
                        height: Double($0.bounds.height)
                    )
                }
            ),
            glyphBounds: Self.normalizedBounds(
                of: filtered.map(\.bounds),
                width: raster.width,
                height: raster.height
            ),
            coverageRatio: coverageRatio,
            coverageComplete: coverageRatio >= 0.9 && !touchesSearchBoundary,
            coveredForegroundCount: coveredForegroundCount,
            touchesSearchBoundary: touchesSearchBoundary
        )
    }

    /// 以字形像素為種子，向外長出實際要塗掉的遮罩。
    ///
    /// 先做遲滯擴張：只吃仍然偏暗的鄰接像素，把抗鋸齒過渡帶整圈收進遮罩，
    /// 網點與留白因為夠亮不會被捲進來。再無條件外擴固定像素，覆蓋 JPEG 在
    /// 高對比邊緣留下的 ringing —— 那圈殘留常常已經亮過遲滯門檻。
    private func grownMaskPixels(
        components: [PixelComponent],
        raster: GrayscaleRaster,
        bounds: PixelBounds,
        bubbleMask: BubbleMask?
    ) -> [PixelCoordinate] {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return [] }

        var marked = [Bool](repeating: false, count: width * height)
        for component in components {
            for rectangle in component.pixelRectangles {
                for y in rectangle.minY..<rectangle.maxY {
                    let localY = y - bounds.minY
                    guard localY >= 0, localY < height else { continue }
                    for x in rectangle.minX..<rectangle.maxX {
                        let localX = x - bounds.minX
                        guard localX >= 0, localX < width else { continue }
                        marked[localY * width + localX] = true
                    }
                }
            }
        }

        for round in 0..<(Self.softEdgeGrowthLimit + maskDilationPixels) {
            // 前幾輪看亮度，之後幾輪無條件外擴。
            let requiresDarkPixel = round < Self.softEdgeGrowthLimit
            var next = marked
            var grew = false
            for localY in 0..<height {
                for localX in 0..<width {
                    let index = localY * width + localX
                    if marked[index] { continue }
                    if requiresDarkPixel {
                        let value = Int(raster[bounds.minX + localX, bounds.minY + localY])
                        guard value <= Self.softEdgeThreshold else { continue }
                    }
                    guard hasMarkedNeighbour(
                        marked,
                        localX: localX,
                        localY: localY,
                        width: width,
                        height: height
                    ) else { continue }
                    next[index] = true
                    grew = true
                }
            }
            marked = next
            // 遲滯階段長不動就直接進入無條件外擴，不要空轉。
            if !grew, requiresDarkPixel { continue }
            if !grew { break }
        }

        var pixels: [PixelCoordinate] = []
        pixels.reserveCapacity(marked.lazy.filter { $0 }.count)
        for localY in 0..<height {
            for localX in 0..<width where marked[localY * width + localX] {
                let x = bounds.minX + localX
                let y = bounds.minY + localY
                // 膨脹餘裕同樣不得越過氣泡形狀，否則邊緣的字又會把外框吃進來。
                if let bubbleMask, !bubbleMask.contains(x: x, y: y) { continue }
                pixels.append(PixelCoordinate(x: x, y: y))
            }
        }
        return pixels
    }

    private func hasMarkedNeighbour(
        _ marked: [Bool],
        localX: Int,
        localY: Int,
        width: Int,
        height: Int
    ) -> Bool {
        for offsetY in -1...1 {
            let neighbourY = localY + offsetY
            guard neighbourY >= 0, neighbourY < height else { continue }
            for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                let neighbourX = localX + offsetX
                guard neighbourX >= 0, neighbourX < width else { continue }
                if marked[neighbourY * width + neighbourX] { return true }
            }
        }
        return false
    }

    private func connectedComponents(
        raster: GrayscaleRaster,
        bounds: PixelBounds,
        threshold: Int
    ) -> [PixelComponent] {
        let localWidth = bounds.width
        let localHeight = bounds.height
        var visited = [Bool](repeating: false, count: localWidth * localHeight)
        var components: [PixelComponent] = []
        let neighbours = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),            (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        for localY in 0..<localHeight {
            for localX in 0..<localWidth {
                let localIndex = localY * localWidth + localX
                if visited[localIndex] { continue }
                visited[localIndex] = true
                let imageX = bounds.minX + localX
                let imageY = bounds.minY + localY
                guard Int(raster[imageX, imageY]) <= threshold else { continue }

                var queue = [localIndex]
                var cursor = 0
                var pixels: [PixelCoordinate] = []
                var minX = imageX
                var minY = imageY
                var maxX = imageX + 1
                var maxY = imageY + 1

                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    let currentLocalX = current % localWidth
                    let currentLocalY = current / localWidth
                    let currentX = bounds.minX + currentLocalX
                    let currentY = bounds.minY + currentLocalY
                    pixels.append(PixelCoordinate(x: currentX, y: currentY))
                    minX = min(minX, currentX)
                    minY = min(minY, currentY)
                    maxX = max(maxX, currentX + 1)
                    maxY = max(maxY, currentY + 1)

                    for (offsetX, offsetY) in neighbours {
                        let nextX = currentLocalX + offsetX
                        let nextY = currentLocalY + offsetY
                        guard nextX >= 0, nextX < localWidth,
                              nextY >= 0, nextY < localHeight else { continue }
                        let nextIndex = nextY * localWidth + nextX
                        guard !visited[nextIndex] else { continue }
                        visited[nextIndex] = true
                        let value = raster[bounds.minX + nextX, bounds.minY + nextY]
                        if Int(value) <= threshold { queue.append(nextIndex) }
                    }
                }

                components.append(PixelComponent(
                    id: components.count,
                    bounds: PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
                    area: pixels.count,
                    pixelRectangles: mergedPixelRectangles(for: pixels)
                ))
            }
        }
        return components
    }

    private func mergedPixelRectangles(for pixels: [PixelCoordinate]) -> [PixelBounds] {
        var columnsByRow: [Int: [Int]] = [:]
        for pixel in pixels {
            columnsByRow[pixel.y, default: []].append(pixel.x)
        }

        var rectangles: [PixelBounds] = []
        var activeRectangles: [PixelSpan: Int] = [:]
        for row in columnsByRow.keys.sorted() {
            let columns = (columnsByRow[row] ?? []).sorted()
            var spans: [PixelSpan] = []
            for column in columns {
                if let last = spans.indices.last, column <= spans[last].maxX {
                    spans[last].maxX = max(spans[last].maxX, column + 1)
                } else {
                    spans.append(PixelSpan(minX: column, maxX: column + 1))
                }
            }

            var nextActiveRectangles: [PixelSpan: Int] = [:]
            for span in spans {
                if let index = activeRectangles[span], rectangles[index].maxY == row {
                    rectangles[index].maxY = row + 1
                    nextActiveRectangles[span] = index
                } else {
                    rectangles.append(PixelBounds(
                        minX: span.minX,
                        minY: row,
                        maxX: span.maxX,
                        maxY: row + 1
                    ))
                    nextActiveRectangles[span] = rectangles.count - 1
                }
            }
            activeRectangles = nextActiveRectangles
        }
        return rectangles
    }

    private func pixelBounds(for rect: NormalizedRect, width: Int, height: Int) -> PixelBounds {
        let value = rect.clamped()
        return PixelBounds(
            minX: Int(floor(value.minX * Double(width))),
            minY: Int(floor(value.minY * Double(height))),
            maxX: Int(ceil(value.maxX * Double(width))),
            maxY: Int(ceil(value.maxY * Double(height)))
        )
    }

    private func otsuThreshold(_ histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 128 }
        let weightedTotal = histogram.enumerated().reduce(0.0) {
            $0 + Double($1.offset * $1.element)
        }
        var backgroundWeight = 0
        var backgroundSum = 0.0
        var maximumVariance = -Double.infinity
        var selected = 128

        for level in histogram.indices {
            backgroundWeight += histogram[level]
            if backgroundWeight == 0 { continue }
            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }
            backgroundSum += Double(level * histogram[level])
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (weightedTotal - backgroundSum) / Double(foregroundWeight)
            let difference = backgroundMean - foregroundMean
            let variance = Double(backgroundWeight * foregroundWeight) * difference * difference
            if variance > maximumVariance {
                maximumVariance = variance
                selected = level
            }
        }
        return selected
    }
}

/// 對話框的實際形狀，光柵化成布林表供逐像素查詢。
///
/// 圓形對話框的矩形框四角其實是畫面內容。只用矩形裁切，人物頭髮與網點會被
/// 當成文字元件擦掉 —— 那就是遮罩溢出到臉上的來源。
private struct BubbleMask {
    let bounds: PixelBounds
    private let inside: [Bool]

    init?(polygons: [[NormalizedPoint]], imageWidth: Int, imageHeight: Int) {
        var rectangles: [PixelBounds] = []
        for polygon in polygons where polygon.count >= 4 {
            let xValues = polygon.map(\.x)
            let yValues = polygon.map(\.y)
            guard let minimumX = xValues.min(), let maximumX = xValues.max(),
                  let minimumY = yValues.min(), let maximumY = yValues.max() else { continue }
            let rectangle = PixelBounds(
                minX: Int(floor(minimumX * Double(imageWidth))),
                minY: Int(floor(minimumY * Double(imageHeight))),
                maxX: Int(ceil(maximumX * Double(imageWidth))),
                maxY: Int(ceil(maximumY * Double(imageHeight)))
            )
            guard rectangle.width > 0, rectangle.height > 0 else { continue }
            rectangles.append(rectangle)
        }
        guard let first = rectangles.first else { return nil }
        let union = rectangles.dropFirst().reduce(first) {
            PixelBounds(
                minX: min($0.minX, $1.minX),
                minY: min($0.minY, $1.minY),
                maxX: max($0.maxX, $1.maxX),
                maxY: max($0.maxY, $1.maxY)
            )
        }
        guard union.width > 0, union.height > 0 else { return nil }
        var buffer = [Bool](repeating: false, count: union.width * union.height)
        for rectangle in rectangles {
            for y in rectangle.minY..<rectangle.maxY {
                let localY = y - union.minY
                guard localY >= 0, localY < union.height else { continue }
                for x in rectangle.minX..<rectangle.maxX {
                    let localX = x - union.minX
                    guard localX >= 0, localX < union.width else { continue }
                    buffer[localY * union.width + localX] = true
                }
            }
        }
        bounds = union
        inside = buffer
    }

    func contains(x: Int, y: Int) -> Bool {
        let localX = x - bounds.minX
        let localY = y - bounds.minY
        guard localX >= 0, localX < bounds.width,
              localY >= 0, localY < bounds.height else { return false }
        return inside[localY * bounds.width + localX]
    }

    func coverage(of component: PixelComponent) -> Double {
        var insideCount = 0
        for rectangle in component.pixelRectangles {
            for y in rectangle.minY..<rectangle.maxY {
                for x in rectangle.minX..<rectangle.maxX where contains(x: x, y: y) {
                    insideCount += 1
                }
            }
        }
        return Double(insideCount) / Double(max(component.area, 1))
    }
}

private struct PixelBounds: Equatable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { max(0, maxX - minX) }
    var height: Int { max(0, maxY - minY) }

    func expanded(by amount: Int) -> PixelBounds {
        PixelBounds(
            minX: minX - amount,
            minY: minY - amount,
            maxX: maxX + amount,
            maxY: maxY + amount
        )
    }

    func intersection(_ other: PixelBounds) -> PixelBounds {
        PixelBounds(
            minX: max(minX, other.minX),
            minY: max(minY, other.minY),
            maxX: min(maxX, other.maxX),
            maxY: min(maxY, other.maxY)
        )
    }

    func touches(_ other: PixelBounds, tolerance: Int) -> Bool {
        let margin = max(0, tolerance)
        return minX <= other.minX + margin
            || minY <= other.minY + margin
            || maxX >= other.maxX - margin
            || maxY >= other.maxY - margin
    }
}

private struct PixelComponent {
    var id: Int
    var bounds: PixelBounds
    var area: Int
    var pixelRectangles: [PixelBounds]
}

private struct PixelCoordinate {
    var x: Int
    var y: Int
}

private struct PixelSpan: Hashable {
    var minX: Int
    var maxX: Int
}

private struct PixelMaskRefinement {
    var polygons: [[NormalizedPoint]]
    /// 由字形排列量出的書寫方向。字太少或排列模稜兩可時為 `automatic`。
    var writingDirection: WritingDirection
    /// 膨脹前的字形外框。遮罩可以帶餘裕，文字區域與合理性判斷不行。
    var glyphBounds: NormalizedRect?
    var coverageRatio: Double
    var coverageComplete: Bool
    var coveredForegroundCount: Int
    var touchesSearchBoundary: Bool
}

private struct GrayscaleRaster {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init(image: CGImage) throws {
        let imageWidth = image.width
        let imageHeight = image.height
        var rgba = [UInt8](repeating: 255, count: imageWidth * imageHeight * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            // CGBitmapContext 的緩衝區第一列即影像頂端，因此直接繪製就是左上原點；
            // 額外翻轉會讓像素索引與 NormalizedRect 的座標系上下顛倒。
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard rendered else { throw ImageProcessingError.cannotCreateBitmap }

        var grayscale = [UInt8](repeating: 255, count: imageWidth * imageHeight)
        for index in grayscale.indices {
            let offset = index * 4
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            grayscale[index] = UInt8((red * 299 + green * 587 + blue * 114) / 1000)
        }
        width = imageWidth
        height = imageHeight
        pixels = grayscale
    }

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    func histogram(in bounds: PixelBounds) -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX {
                result[Int(self[x, y])] += 1
            }
        }
        return result
    }
}
