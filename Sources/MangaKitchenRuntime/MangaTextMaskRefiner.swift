import CoreGraphics
import Foundation
import MangaKitchenCore

/// 在 OCR 粗框內以亮度與連通元件尋找實際文字筆畫。
/// 這一層刻意不判讀語言，黑白、灰階及彩色漫畫可共用同一套流程。
public actor MangaTextMaskRefiner: DialogueMaskRefining {
    private let searchPaddingPixels: Int
    private let componentPaddingPixels: Int
    private let maximumComponentsPerRegion: Int

    public init(
        searchPaddingPixels: Int = 2,
        componentPaddingPixels: Int = 1,
        maximumComponentsPerRegion: Int = 256
    ) {
        self.searchPaddingPixels = max(0, searchPaddingPixels)
        self.componentPaddingPixels = max(0, componentPaddingPixels)
        self.maximumComponentsPerRegion = max(1, maximumComponentsPerRegion)
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
                refined.automaticMaskEnabled = false
                refined.maskRefinementApplied = false
                refined.maskCoverageRatio = nil
                refined.maskCoverageComplete = false
                return refined
            }
            refined.maskPolygons = result.polygons
            if let pixelBounds = Self.enclosingBounds(of: result.polygons) {
                let clippedBounds = region.bubbleBounds
                    .map { pixelBounds.intersection(with: $0) }
                    ?? pixelBounds
                if clippedBounds.width > 0, clippedBounds.height > 0 {
                    refined.bounds = clippedBounds
                }
            }
            refined.automaticMaskEnabled = true
            refined.maskRefinementApplied = true
            refined.maskCoverageRatio = result.coverageRatio
            refined.maskCoverageComplete = result.coverageComplete
            return refined
        }
    }

    /// 像素精修完成後，文字區域本身也必須同步收斂到字形多邊形外框。
    /// `bubbleBounds` 仍保留完整對話框內緣，供遮罩裁切與譯文安全範圍使用。
    private static func enclosingBounds(
        of polygons: [[NormalizedPoint]]
    ) -> NormalizedRect? {
        let points = polygons.flatMap { $0 }
        guard let first = points.first else { return nil }
        var minimumX = first.x
        var minimumY = first.y
        var maximumX = first.x
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumX = max(maximumX, point.x)
            maximumY = max(maximumY, point.y)
        }
        let bounds = NormalizedRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).clamped()
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
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
        let clippingBounds = bubbleBounds ?? coarseBounds
        let initialSearchBounds = coarseBounds.intersection(clippingBounds)
        let initial = refinement(
            in: initialSearchBounds,
            clippingBounds: clippingBounds,
            imageBounds: imageBounds,
            raster: raster,
            rejectsBoundaryComponents: bubbleBounds != nil
        )

        // 粗框只負責定位。若已知完整對話框內緣，另外在整個框內搜尋一次；
        // 發現粗框外仍有可信前景元件時，採用擴大搜尋後的字形多邊形，
        // 而不是把粗框或整個對話框直接當成遮罩。
        guard let bubbleBounds,
              bubbleBounds.width > initialSearchBounds.width
                || bubbleBounds.height > initialSearchBounds.height,
              let expanded = refinement(
                in: bubbleBounds,
                clippingBounds: bubbleBounds,
                imageBounds: imageBounds,
                raster: raster,
                rejectsBoundaryComponents: true
              ) else {
            return initial
        }
        guard let initial else { return expanded }
        let meaningfulIncrease = expanded.coveredForegroundCount
            > max(initial.coveredForegroundCount + 4, Int(Double(initial.coveredForegroundCount) * 1.04))
        return initial.touchesSearchBoundary || meaningfulIncrease ? expanded : initial
    }

    private func refinement(
        in searchBounds: PixelBounds,
        clippingBounds: PixelBounds,
        imageBounds: PixelBounds,
        raster: GrayscaleRaster,
        rejectsBoundaryComponents: Bool
    ) -> PixelMaskRefinement? {
        guard searchBounds.width > 0, searchBounds.height > 0 else { return nil }

        let histogram = raster.histogram(in: searchBounds)
        let threshold = min(210, max(48, otsuThreshold(histogram) + 18))
        let sampleCount = max(searchBounds.width * searchBounds.height, 1)
        let foregroundCount = histogram.prefix(threshold + 1).reduce(0, +)
        let foregroundRatio = Double(foregroundCount) / Double(sampleCount)

        // OCR 框若大部分都是暗色，通常落在插畫或實心擬聲字上；
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
        let contentComponents = candidates.filter { !structuralIDs.contains($0.id) }
        // 擴張到整個對話框內緣時，接觸安全邊界的元件通常是泡泡框線、
        // 人物輪廓或分鏡線，而不是位於留白中的文字。它們可參與「邊界太窄」
        // 的診斷，但不可直接成為遮罩，否則會把泡泡外框一併抹除。
        let boundaryTolerance = max(1, componentPaddingPixels)
        let boundaryComponents = rejectsBoundaryComponents
            ? contentComponents.filter { $0.bounds.touches(searchBounds, tolerance: boundaryTolerance) }
            : []
        let boundaryIDs = Set(boundaryComponents.map(\.id))
        let filtered = rejectsBoundaryComponents
            ? contentComponents.filter { !boundaryIDs.contains($0.id) }
            : contentComponents
        guard !filtered.isEmpty, filtered.count <= maximumComponentsPerRegion else { return nil }

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
        let polygons = filtered
            .sorted {
                if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
                return $0.bounds.minX < $1.bounds.minX
            }
            .flatMap { component in
                component.pixelRectangles.map { pixelRectangle in
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
            }
        return PixelMaskRefinement(
            polygons: polygons,
            coverageRatio: coverageRatio,
            coverageComplete: coverageRatio >= 0.9 && !touchesSearchBoundary,
            coveredForegroundCount: coveredForegroundCount,
            touchesSearchBoundary: touchesSearchBoundary
        )
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
