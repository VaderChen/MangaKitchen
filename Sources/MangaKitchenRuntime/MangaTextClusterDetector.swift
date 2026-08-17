import CoreGraphics
import Foundation
import MangaKitchenCore

/// 以字形筆畫直接在整頁上找出文字塊。
///
/// 封閉白區偵測有個原理上的死角：白底頁面上，開口氣泡與無框台詞的內部會直接
/// 連到整頁背景（實測 flood fill 得到 100% 頁面積，任何門檻都一樣），因此
/// 「封閉白區」永遠看不見它們，文字在進入 VLM 之前就消失了。
///
/// 這一層改以墨色連通元件為主訊號：不論有沒有外框，字都在。封閉白區降級為
/// 加分項，只在存在時提供 `bubbleBounds`。
struct MangaTextClusterDetector {
    struct TextCluster {
        var bounds: NormalizedRect
        var glyphCount: Int
        /// 群集內字形的中位尺寸（像素），供聚類距離與後續診斷使用。
        var medianGlyphSize: Int
    }

    private struct PixelBounds {
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

        func intersects(_ other: PixelBounds) -> Bool {
            minX < other.maxX && other.minX < maxX
                && minY < other.maxY && other.minY < maxY
        }

        mutating func formUnion(_ other: PixelBounds) {
            minX = min(minX, other.minX)
            minY = min(minY, other.minY)
            maxX = max(maxX, other.maxX)
            maxY = max(maxY, other.maxY)
        }
    }

    private struct Glyph {
        var bounds: PixelBounds
        var area: Int
        var size: Int { max(bounds.width, bounds.height) }
    }

    /// 單一字形允許的高度範圍，相對於頁面短邊。
    private let minimumGlyphRatio: Double
    private let maximumGlyphRatio: Double
    /// 字形筆畫在自己外接框內的最低佔比；濾掉稀疏的線稿與網點紋理。
    private let minimumGlyphFill: Double
    /// 字形周圍一圈的最低平均亮度。這是分開「字」與「線稿」最有效的一刀：
    /// 字一定寫在留白上（框內或紙上），而石頭、網點、人物線條的周圍是暗的。
    private let minimumSurroundBrightness: Int
    /// 聚類時往外找鄰居的距離，相對於字形尺寸。
    private let clusterGapRatio: Double
    /// 一個文字塊至少要有幾個字形，避免單顆雜點成塊。
    private let minimumGlyphsPerCluster: Int
    private let maximumClusters: Int

    init(
        minimumGlyphRatio: Double = 0.006,
        maximumGlyphRatio: Double = 0.055,
        minimumGlyphFill: Double = 0.12,
        minimumSurroundBrightness: Int = 205,
        clusterGapRatio: Double = 1.3,
        minimumGlyphsPerCluster: Int = 5,
        maximumClusters: Int = 40
    ) {
        self.minimumGlyphRatio = minimumGlyphRatio
        self.maximumGlyphRatio = maximumGlyphRatio
        self.minimumGlyphFill = minimumGlyphFill
        self.minimumSurroundBrightness = minimumSurroundBrightness
        self.clusterGapRatio = clusterGapRatio
        self.minimumGlyphsPerCluster = max(1, minimumGlyphsPerCluster)
        self.maximumClusters = max(1, maximumClusters)
    }

    func detect(in image: CGImage) throws -> [TextCluster] {
        let raster = try TextGrayscaleRaster(image: image)
        let width = raster.width
        let height = raster.height
        let shortSide = Double(min(width, height))
        let minimumGlyph = Int(shortSide * minimumGlyphRatio)
        let maximumGlyph = Int(shortSide * maximumGlyphRatio)
        let threshold = raster.otsuThreshold()

        let glyphs = inkComponents(
            raster: raster,
            threshold: threshold,
            minimumGlyph: max(2, minimumGlyph),
            maximumGlyph: max(4, maximumGlyph)
        )
        guard !glyphs.isEmpty else { return [] }

        return cluster(glyphs: glyphs, width: width, height: height)
    }

    /// 墨色連通元件，只保留「像字」的那些。
    private func inkComponents(
        raster: TextGrayscaleRaster,
        threshold: UInt8,
        minimumGlyph: Int,
        maximumGlyph: Int
    ) -> [Glyph] {
        let width = raster.width
        let height = raster.height
        var visited = [Bool](repeating: false, count: width * height)
        var glyphs: [Glyph] = []
        let offsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0), (1, 0),
            (-1, 1), (0, 1), (1, 1)
        ]
        // 面積上限用「最大字形的外接方塊」推算，超過就是線稿或網點連成一片。
        let maximumArea = maximumGlyph * maximumGlyph

        for startY in 0..<height {
            for startX in 0..<width {
                let start = startY * width + startX
                guard !visited[start] else { continue }
                visited[start] = true
                guard raster[startX, startY] <= threshold else { continue }

                var queue = [start]
                var cursor = 0
                var area = 0
                var minX = startX, minY = startY
                var maxX = startX + 1, maxY = startY + 1
                var overflowed = false

                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    let x = current % width
                    let y = current / width
                    area += 1
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x + 1); maxY = max(maxY, y + 1)
                    // 一旦長成線稿規模就停止追蹤，避免整片背景線條吃掉時間。
                    if !overflowed,
                       maxX - minX > maximumGlyph * 2 || maxY - minY > maximumGlyph * 2 {
                        overflowed = true
                    }

                    for (offsetX, offsetY) in offsets {
                        let nextX = x + offsetX
                        let nextY = y + offsetY
                        guard nextX >= 0, nextX < width,
                              nextY >= 0, nextY < height else { continue }
                        let next = nextY * width + nextX
                        guard !visited[next] else { continue }
                        visited[next] = true
                        if raster[nextX, nextY] <= threshold { queue.append(next) }
                    }
                }

                guard !overflowed else { continue }
                let boundsWidth = maxX - minX
                let boundsHeight = maxY - minY
                let longSide = max(boundsWidth, boundsHeight)
                let shortSide = min(boundsWidth, boundsHeight)
                guard longSide >= minimumGlyph, longSide <= maximumGlyph,
                      area <= maximumArea else { continue }
                // 極細長的元件是框線、格線或效果線，不是字。
                guard shortSide * 8 >= longSide else { continue }
                let fill = Double(area) / Double(max(boundsWidth * boundsHeight, 1))
                guard fill >= minimumGlyphFill else { continue }
                let bounds = PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
                guard raster.surroundBrightness(
                    minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                    margin: max(2, longSide / 2)
                ) >= minimumSurroundBrightness else { continue }

                glyphs.append(Glyph(bounds: bounds, area: area))
            }
        }
        return glyphs
    }

    /// 以字形尺寸為尺度做鄰近聚類：直排欄、橫排行都能自然連起來。
    private func cluster(glyphs: [Glyph], width: Int, height: Int) -> [TextCluster] {
        var parent = Array(glyphs.indices)
        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let a = root(lhs), b = root(rhs)
            if a != b { parent[b] = a }
        }

        // 依 y 排序後只比較附近的字形，避免 O(n²) 全比。
        let order = glyphs.indices.sorted { glyphs[$0].bounds.minY < glyphs[$1].bounds.minY }
        for cursor in order.indices {
            let index = order[cursor]
            let glyph = glyphs[index]
            let reach = max(2, Int(Double(glyph.size) * clusterGapRatio))
            let probe = glyph.bounds.expanded(by: reach)
            var other = cursor + 1
            while other < order.count {
                let candidateIndex = order[other]
                let candidate = glyphs[candidateIndex]
                // y 已排序，超出探測範圍就不必再往下找。
                if candidate.bounds.minY > probe.maxY { break }
                // 尺寸差太多的通常不是同一段文字。
                let ratio = Double(max(glyph.size, candidate.size))
                    / Double(max(1, min(glyph.size, candidate.size)))
                if ratio <= 2.6, probe.intersects(candidate.bounds.expanded(by: reach / 2)) {
                    union(index, candidateIndex)
                }
                other += 1
            }
        }

        var grouped: [Int: (bounds: PixelBounds, sizes: [Int])] = [:]
        for index in glyphs.indices {
            let key = root(index)
            let glyph = glyphs[index]
            if var existing = grouped[key] {
                existing.bounds.formUnion(glyph.bounds)
                existing.sizes.append(glyph.size)
                grouped[key] = existing
            } else {
                grouped[key] = (glyph.bounds, [glyph.size])
            }
        }

        var clusters = grouped.values.compactMap { entry -> TextCluster? in
            guard entry.sizes.count >= minimumGlyphsPerCluster else { return nil }
            let sorted = entry.sizes.sorted()
            let median = sorted[sorted.count / 2]
            // 往外留一點邊，讓後續像素精修有搜尋餘裕。
            let padding = max(2, median / 3)
            let bounds = entry.bounds.expanded(by: padding)
            let minX = Double(max(0, bounds.minX)) / Double(width)
            let minY = Double(max(0, bounds.minY)) / Double(height)
            let maxX = Double(min(width, bounds.maxX)) / Double(width)
            let maxY = Double(min(height, bounds.maxY)) / Double(height)
            guard maxX > minX, maxY > minY else { return nil }
            return TextCluster(
                bounds: NormalizedRect(
                    x: minX, y: minY, width: maxX - minX, height: maxY - minY
                ).clamped(),
                glyphCount: entry.sizes.count,
                medianGlyphSize: median
            )
        }

        if clusters.count > maximumClusters {
            clusters = Array(clusters.sorted { $0.glyphCount > $1.glyphCount }
                .prefix(maximumClusters))
        }
        return clusters.sorted {
            let tolerance = max($0.bounds.height, $1.bounds.height) * 0.25
            if abs($0.bounds.minY - $1.bounds.minY) > tolerance {
                return $0.bounds.minY < $1.bounds.minY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
    }
}

private struct TextGrayscaleRaster {
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
            let weightedRed = red * 299
            let weightedGreen = green * 587
            let weightedBlue = blue * 114
            let luminance = (weightedRed + weightedGreen + weightedBlue) / 1_000
            grayscale[index] = UInt8(luminance)
        }
        width = imageWidth
        height = imageHeight
        pixels = grayscale
    }

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// 元件外圍一圈（外接框外擴 margin，扣掉框內本身）的平均亮度。
    /// 暗色鄰域必須納入平均，否則人物線稿周圍的暗像素全被排除後，也會被誤判
    /// 為「寫在留白上的文字」。
    func surroundBrightness(
        minX bMinX: Int,
        minY bMinY: Int,
        maxX bMaxX: Int,
        maxY bMaxY: Int,
        margin: Int
    ) -> Int {
        let minX = max(0, bMinX - margin)
        let minY = max(0, bMinY - margin)
        let maxX = min(width, bMaxX + margin)
        let maxY = min(height, bMaxY + margin)
        var total = 0
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                if x >= bMinX, x < bMaxX, y >= bMinY, y < bMaxY { continue }
                let value = pixels[y * width + x]
                total += Int(value)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return total / count
    }

    func otsuThreshold() -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let total = pixels.count
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
        return UInt8(min(200, max(60, selected)))
    }
}
