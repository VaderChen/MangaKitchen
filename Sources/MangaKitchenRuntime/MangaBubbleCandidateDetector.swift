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

    private let inkThreshold: UInt8
    private let minimumWhiteAreaRatio: Double
    private let minimumBoundsAreaRatio: Double
    private let maximumBoundsAreaRatio: Double
    private let minimumFillRatio: Double
    private let maximumCandidates: Int

    init(
        // 判準是「非墨色」而不是「夠白」：網點面板上的氣泡內部只有 200 出頭，
        // 用 245 會整片看不見。實測從氣泡內部 flood fill，>200 這個判準下
        // 氣泡都是封閉的（0.5～2.2% 頁面積），不會漏進分鏡背景。
        //
        // 面積下限也放寬：實測「ふふ…」只佔 0.6% 頁面積，舊的 0.01（1%）
        // 會把這類小氣泡整個刷掉 —— 那才是它一直被漏掉的原因，不是拓樸問題。
        // 放寬帶進來的誤判交給 VLM 判 ignore，那一段已驗證可靠。
        inkThreshold: UInt8 = 200,
        minimumWhiteAreaRatio: Double = 0.002,
        minimumBoundsAreaRatio: Double = 0.004,
        maximumBoundsAreaRatio: Double = 0.2,
        minimumFillRatio: Double = 0.45,
        maximumCandidates: Int = 36
    ) {
        self.inkThreshold = inkThreshold
        self.minimumWhiteAreaRatio = minimumWhiteAreaRatio
        self.minimumBoundsAreaRatio = minimumBoundsAreaRatio
        self.maximumBoundsAreaRatio = maximumBoundsAreaRatio
        self.minimumFillRatio = minimumFillRatio
        self.maximumCandidates = max(1, maximumCandidates)
    }

    func detect(in image: CGImage) throws -> [NormalizedRect] {
        let raster = try GrayscaleRaster(image: image)
        let imageArea = Double(max(raster.width * raster.height, 1))
        var candidates = connectedWhiteComponents(in: raster).compactMap { component -> NormalizedRect? in
            let boundsArea = component.bounds.width * component.bounds.height
            guard boundsArea > 0 else { return nil }
            let whiteAreaRatio = Double(component.area) / imageArea
            let boundsAreaRatio = Double(boundsArea) / imageArea
            let fillRatio = Double(component.area) / Double(boundsArea)
            let widthRatio = Double(component.bounds.width) / Double(raster.width)
            let heightRatio = Double(component.bounds.height) / Double(raster.height)
            guard whiteAreaRatio >= minimumWhiteAreaRatio,
                  boundsAreaRatio >= minimumBoundsAreaRatio,
                  boundsAreaRatio <= maximumBoundsAreaRatio,
                  fillRatio >= minimumFillRatio,
                  widthRatio >= 0.04,
                  heightRatio >= 0.02,
                  !(boundsAreaRatio >= 0.04
                    && isFrameLike(component.bounds, in: raster)) else {
                return nil
            }
            return NormalizedRect(
                x: Double(component.bounds.minX) / Double(raster.width),
                y: Double(component.bounds.minY) / Double(raster.height),
                width: widthRatio,
                height: heightRatio
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

    private func connectedWhiteComponents(in raster: GrayscaleRaster) -> [Component] {
        let width = raster.width
        let height = raster.height
        var visited = [UInt8](repeating: 0, count: width * height)
        var components: [Component] = []
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let startIndex = y * width + x
                guard visited[startIndex] == 0 else { continue }
                visited[startIndex] = 1
                guard raster[x, y] > inkThreshold else { continue }

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
                        guard visited[nextIndex] == 0 else { continue }
                        visited[nextIndex] = 1
                        if raster[nextX, nextY] > inkThreshold {
                            queue.append(nextIndex)
                        }
                    }
                }

                components.append(Component(
                    bounds: PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
                    area: area
                ))
            }
        }
        return components
    }

    /// 大型白底分鏡會被四條近乎筆直的框線包住，僅靠白區面積與填充率會被誤認
    /// 成巨大對話框。檢查元件外接框四邊附近的墨色覆蓋率，把完整分鏡排除；小型
    /// 矩形旁白框不套用這個規則，仍可由文字群集補充進工作流。
    private func isFrameLike(_ bounds: PixelBounds, in raster: GrayscaleRaster) -> Bool {
        guard bounds.width > 8, bounds.height > 8 else { return false }
        let thickness = 3

        func horizontalInteriorCoverage(from minimumY: Int, to maximumY: Int) -> Double {
            guard minimumY < maximumY else { return 0 }
            var whiteColumns = 0
            for x in max(0, bounds.minX)..<min(raster.width, bounds.maxX) {
                var isWhite = false
                for sampleY in minimumY..<maximumY where raster[x, sampleY] > inkThreshold {
                    isWhite = true
                    break
                }
                if isWhite { whiteColumns += 1 }
            }
            return Double(whiteColumns) / Double(max(bounds.width, 1))
        }

        func verticalInteriorCoverage(from minimumX: Int, to maximumX: Int) -> Double {
            guard minimumX < maximumX else { return 0 }
            var whiteRows = 0
            for y in max(0, bounds.minY)..<min(raster.height, bounds.maxY) {
                var isWhite = false
                for sampleX in minimumX..<maximumX where raster[sampleX, y] > inkThreshold {
                    isWhite = true
                    break
                }
                if isWhite { whiteRows += 1 }
            }
            return Double(whiteRows) / Double(max(bounds.height, 1))
        }

        let top = horizontalInteriorCoverage(
            from: bounds.minY,
            to: min(bounds.maxY, bounds.minY + thickness)
        )
        let bottom = horizontalInteriorCoverage(
            from: max(bounds.minY, bounds.maxY - thickness),
            to: bounds.maxY
        )
        let left = verticalInteriorCoverage(
            from: bounds.minX,
            to: min(bounds.maxX, bounds.minX + thickness)
        )
        let right = verticalInteriorCoverage(
            from: max(bounds.minX, bounds.maxX - thickness),
            to: bounds.maxX
        )
        return top >= 0.72 && bottom >= 0.72 && left >= 0.72 && right >= 0.72
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
}
