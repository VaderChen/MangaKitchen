import CoreGraphics
import Foundation
import MangaKitchenCore

/// 以白色封閉區域找出黑白漫畫中的對話泡泡、旁白框與標題框候選。
///
/// 這一層不讀文字、也不判斷語言，只提供穩定的像素級粗定位。語意模型會再把
/// 非文字白區標為 ignore；因此擬聲字不會因 VLM 座標漂移而誤進翻譯工作流。
struct MangaBubbleCandidateDetector {
    private struct PixelBounds {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int

        var width: Int { max(0, maxX - minX) }
        var height: Int { max(0, maxY - minY) }
    }

    private struct Component {
        var bounds: PixelBounds
        var area: Int
    }

    /// 補洞後的元件輪廓資訊。洞（框內被墨線圍住的暗區）本身就是分類依據：
    /// 對話框裡的洞是字，小而多；分鏡裡的洞是人物線稿，會出現單一大塊。
    private struct EnclosureMetrics {
        var bounds: PixelBounds
        var brightArea: Int
        var holeArea: Int
        var largestHoleArea: Int

        var solidArea: Int { brightArea + holeArea }
        var boundsArea: Int { bounds.width * bounds.height }
        /// 補洞後的形狀相對於外接矩形的填滿率；細長殘白會被擋掉。
        var fillRatio: Double { Double(solidArea) / Double(max(boundsArea, 1)) }
        /// 框內墨色佔比。對話框以留白為主，分鏡以線稿為主。
        var inkRatio: Double { Double(holeArea) / Double(max(solidArea, 1)) }
        /// 最大單一洞的佔比。字再多也只是一個個小洞，人物剪影則是一大塊。
        var largestHoleRatio: Double { Double(largestHoleArea) / Double(max(solidArea, 1)) }
    }

    private let maximumWhiteThreshold: UInt8
    private let minimumBoundsAreaRatio: Double
    private let maximumBoundsAreaRatio: Double
    private let minimumFillRatio: Double
    private let maximumInkRatio: Double
    private let maximumLargestHoleRatio: Double
    private let maximumCandidates: Int

    init(
        maximumWhiteThreshold: UInt8 = 245,
        minimumBoundsAreaRatio: Double = 0.004,
        maximumBoundsAreaRatio: Double = 0.25,
        minimumFillRatio: Double = 0.55,
        maximumInkRatio: Double = 0.45,
        maximumLargestHoleRatio: Double = 0.1,
        maximumCandidates: Int = 36
    ) {
        self.maximumWhiteThreshold = maximumWhiteThreshold
        self.minimumBoundsAreaRatio = minimumBoundsAreaRatio
        self.maximumBoundsAreaRatio = maximumBoundsAreaRatio
        self.minimumFillRatio = minimumFillRatio
        self.maximumInkRatio = maximumInkRatio
        self.maximumLargestHoleRatio = maximumLargestHoleRatio
        self.maximumCandidates = max(1, maximumCandidates)
    }

    func detect(in image: CGImage) throws -> [NormalizedRect] {
        let raster = try GrayscaleRaster(image: image)
        let width = raster.width
        let height = raster.height
        let imageArea = Double(max(width * height, 1))
        let bright = raster.brightMask(threshold: paperThreshold(in: raster))

        // 不可在全頁補洞後才切元件：對話框外框墨線被白色分鏡背景包住，
        // 補洞會把它填成亮區，於是分鏡背景與框內留白連成同一個元件，
        // 整格分鏡就被當成一個候選。改為先切元件，再逐一在自己的範圍內補洞。
        let labelled = labelComponents(in: bright, width: width, height: height)
        let sized = labelled.components.enumerated().filter { _, component in
            let boundsAreaRatio = Double(component.bounds.width * component.bounds.height) / imageArea
            return boundsAreaRatio >= minimumBoundsAreaRatio
                && boundsAreaRatio <= maximumBoundsAreaRatio
                && Double(component.bounds.width) / Double(width) >= 0.03
                && Double(component.bounds.height) / Double(height) >= 0.02
        }

        let shaped = sized.compactMap { index, component -> EnclosureMetrics? in
            let metrics = enclosureMetrics(
                label: Int32(index),
                component: component,
                labels: labelled.labels,
                width: width,
                height: height
            )
            guard metrics.fillRatio >= minimumFillRatio,
                  metrics.inkRatio <= maximumInkRatio,
                  metrics.largestHoleRatio <= maximumLargestHoleRatio else { return nil }
            return metrics
        }

        // 對話框不會包住另一個對話框，但白底分鏡會包住畫在它上面的對話框。
        // 因此凡是「包住另一個候選」的候選都是分鏡，取內不取外。
        var candidates = shaped.filter { candidate in
            !shaped.contains { encloses(candidate, $0) }
        }.map { metrics in
            NormalizedRect(
                x: Double(metrics.bounds.minX) / Double(width),
                y: Double(metrics.bounds.minY) / Double(height),
                width: Double(metrics.bounds.width) / Double(width),
                height: Double(metrics.bounds.height) / Double(height)
            ).clamped()
        }

        if candidates.count > maximumCandidates {
            candidates = Array(candidates.sorted {
                $0.width * $0.height > $1.width * $1.height
            }.prefix(maximumCandidates))
        }
        return candidates.sorted {
            let rowTolerance = max($0.height, $1.height) * 0.25
            if abs($0.minY - $1.minY) > rowTolerance { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
    }

    private func encloses(_ outer: EnclosureMetrics, _ inner: EnclosureMetrics) -> Bool {
        guard inner.boundsArea < outer.boundsArea else { return false }
        let overlapWidth = max(0, min(inner.bounds.maxX, outer.bounds.maxX)
            - max(inner.bounds.minX, outer.bounds.minX))
        let overlapHeight = max(0, min(inner.bounds.maxY, outer.bounds.maxY)
            - max(inner.bounds.minY, outer.bounds.minY))
        let overlap = Double(overlapWidth * overlapHeight)
        return overlap / Double(max(inner.boundsArea, 1)) >= 0.9
            && Double(inner.boundsArea) / Double(max(outer.boundsArea, 1)) <= 0.6
    }

    /// 紙面白並非固定值：JPEG 壓縮與網點會把泡泡內部壓到 240 以下，
    /// 固定 245 會把整頁切成數萬個雜訊碎片，一個候選都留不下來。
    /// 改以「200 以上最亮的主峰」當紙色，再往下讓出壓縮雜訊的餘裕。
    private func paperThreshold(in raster: GrayscaleRaster) -> UInt8 {
        let histogram = raster.histogram()
        var peak = Int(maximumWhiteThreshold)
        var peakCount = -1
        for level in 200...255 where histogram[level] > peakCount {
            peakCount = histogram[level]
            peak = level
        }
        let relaxed = peak - 10
        return UInt8(min(Int(maximumWhiteThreshold), max(225, relaxed)))
    }

    /// 4-連通標記亮區元件，並保留每個像素的元件編號，
    /// 後續才能逐元件在自己的範圍內補洞。
    private func labelComponents(
        in bright: [Bool],
        width: Int,
        height: Int
    ) -> (labels: [Int32], components: [Component]) {
        var labels = [Int32](repeating: -1, count: width * height)
        var components: [Component] = []
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let startIndex = y * width + x
                guard bright[startIndex], labels[startIndex] == -1 else { continue }
                let identifier = Int32(components.count)
                labels[startIndex] = identifier
                var queue = [startIndex]
                var cursor = 0
                var area = 0
                var minX = x
                var minY = y
                var maxX = x + 1
                var maxY = y + 1

                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    let currentX = current % width
                    let currentY = current / width
                    area += 1
                    minX = min(minX, currentX)
                    minY = min(minY, currentY)
                    maxX = max(maxX, currentX + 1)
                    maxY = max(maxY, currentY + 1)

                    for (offsetX, offsetY) in offsets {
                        let nextX = currentX + offsetX
                        let nextY = currentY + offsetY
                        guard nextX >= 0, nextX < width,
                              nextY >= 0, nextY < height else { continue }
                        let nextIndex = nextY * width + nextX
                        guard bright[nextIndex], labels[nextIndex] == -1 else { continue }
                        labels[nextIndex] = identifier
                        queue.append(nextIndex)
                    }
                }

                components.append(Component(
                    bounds: PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
                    area: area
                ))
            }
        }
        return (labels, components)
    }

    /// 在元件自己的外接矩形內補洞：從矩形邊界對「非本元件」像素做 flood fill，
    /// 邊界到不了的就是被本元件圍住的洞。這樣既能量到補洞後的真實形狀，
    /// 又不會像全頁補洞那樣把相鄰元件連在一起。
    private func enclosureMetrics(
        label: Int32,
        component: Component,
        labels: [Int32],
        width: Int,
        height: Int
    ) -> EnclosureMetrics {
        let localWidth = component.bounds.width + 2
        let localHeight = component.bounds.height + 2
        func belongsToComponent(_ localX: Int, _ localY: Int) -> Bool {
            let x = component.bounds.minX + localX - 1
            let y = component.bounds.minY + localY - 1
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return labels[y * width + x] == label
        }

        var outside = [Bool](repeating: false, count: localWidth * localHeight)
        var stack: [Int] = []
        func seed(_ localX: Int, _ localY: Int) {
            let index = localY * localWidth + localX
            guard !outside[index], !belongsToComponent(localX, localY) else { return }
            outside[index] = true
            stack.append(index)
        }
        for localX in 0..<localWidth {
            seed(localX, 0)
            seed(localX, localHeight - 1)
        }
        for localY in 0..<localHeight {
            seed(0, localY)
            seed(localWidth - 1, localY)
        }
        while let current = stack.popLast() {
            let currentX = current % localWidth
            let currentY = current / localWidth
            for (offsetX, offsetY) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nextX = currentX + offsetX
                let nextY = currentY + offsetY
                guard nextX >= 0, nextX < localWidth,
                      nextY >= 0, nextY < localHeight else { continue }
                let nextIndex = nextY * localWidth + nextX
                guard !outside[nextIndex], !belongsToComponent(nextX, nextY) else { continue }
                outside[nextIndex] = true
                stack.append(nextIndex)
            }
        }

        var visited = [Bool](repeating: false, count: localWidth * localHeight)
        var holeArea = 0
        var largestHoleArea = 0
        for localY in 0..<localHeight {
            for localX in 0..<localWidth {
                let index = localY * localWidth + localX
                guard !outside[index], !visited[index],
                      !belongsToComponent(localX, localY) else { continue }
                visited[index] = true
                var queue = [index]
                var cursor = 0
                var size = 0
                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    size += 1
                    let currentX = current % localWidth
                    let currentY = current / localWidth
                    for (offsetX, offsetY) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nextX = currentX + offsetX
                        let nextY = currentY + offsetY
                        guard nextX >= 0, nextX < localWidth,
                              nextY >= 0, nextY < localHeight else { continue }
                        let nextIndex = nextY * localWidth + nextX
                        guard !outside[nextIndex], !visited[nextIndex],
                              !belongsToComponent(nextX, nextY) else { continue }
                        visited[nextIndex] = true
                        queue.append(nextIndex)
                    }
                }
                holeArea += size
                largestHoleArea = max(largestHoleArea, size)
            }
        }

        return EnclosureMetrics(
            bounds: component.bounds,
            brightArea: component.area,
            holeArea: holeArea,
            largestHoleArea: largestHoleArea
        )
    }
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard rendered else { throw ImageProcessingError.cannotCreateBitmap }

        var grayscale = [UInt8](repeating: 255, count: imageWidth * imageHeight)
        for index in grayscale.indices {
            let offset = index * 4
            grayscale[index] = UInt8((
                Int(rgba[offset]) * 299
                    + Int(rgba[offset + 1]) * 587
                    + Int(rgba[offset + 2]) * 114
            ) / 1_000)
        }
        width = imageWidth
        height = imageHeight
        pixels = grayscale
    }

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    func histogram() -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        for value in pixels { result[Int(value)] += 1 }
        return result
    }

    func brightMask(threshold: UInt8) -> [Bool] {
        pixels.map { $0 >= threshold }
    }
}
