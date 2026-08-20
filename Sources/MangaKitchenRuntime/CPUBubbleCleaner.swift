import CoreGraphics
import Foundation
import MangaKitchenCore

/// CPU 合成後端：以每個文字區域外圍最常見的顏色填補遮罩像素。
/// 對漫畫對話框通常會選中紙張的底色，避免 GPU 鄰域取樣把線稿拖入框內。
public actor CPUBubbleCleaner {
    /// 取樣環與遮罩之間要留的安全距離（像素）。
    ///
    /// 緊貼遮罩的那一圈正好是抗鋸齒殘留：門檻切不掉、又比紙白暗。拿它當樣本，
    /// 每個字會依自己的筆畫量取到不同深淺的底色，填完之後就浮出一層字形鬼影。
    /// 往外退幾個像素才取得到乾淨的紙面。
    private static let sampleInset = 3
    /// 取樣環的厚度。太薄會在小字周圍取不到足夠樣本。
    private static let sampleThickness = 3
    /// 指定固定底色時，額外清掉遮罩外圍的掃描／JPEG 淡色 halo。
    /// 只接受與底色相近的像素，因此不會把黑色泡泡框線或線稿一起吃掉。
    private static let fixedFillHaloRadius = 2
    // JPEG 與掃描抗鋸齒會把黑字邊緣混到約 160/255；白底差值 95
    // 仍屬於要清掉的字形 halo。門檻 96 能包住這層，但不會接近黑色框線。
    private static let fixedFillMaximumChannelDistance = 96

    public init() {}

    public func clean(
        sourceURL: URL,
        maskURL: URL,
        regions: [DialogueRegion] = [],
        fillColorHex: String? = nil,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        try Task.checkCancellation()
        let sourceImage = try CGImageIO.load(from: sourceURL)
        let maskImage = try CGImageIO.load(from: maskURL)
        let width = sourceImage.width
        let height = sourceImage.height
        guard width == maskImage.width, height == maskImage.height else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        var source = try rgbaPixels(from: sourceImage)
        let mask = try rgbaPixels(from: maskImage)
        let originalMask = stride(from: 0, to: mask.count, by: 4).map { mask[$0] > 0 }
        let configuredFill = fillColorHex.flatMap(Self.color(from:))
        let masked = configuredFill.map {
            fixedFillMask(
                originalMask,
                source: source,
                fill: $0,
                width: width,
                height: height
            )
        } ?? originalMask
        // 取樣時要避開的範圍：遮罩本身再往外幾像素。緊貼遮罩那一圈是抗鋸齒殘留，
        // 比紙面暗，取到它就會依每個字的筆畫量得到不同深淺的底色。
        let excluded = MaskDilation.dilated(
            masked,
            width: width,
            height: height,
            radius: Self.sampleInset
        )
        let components = groupedComponents(
            try connectedComponents(masked: masked, width: width, height: height),
            regions: regions,
            width: width,
            height: height
        )
        progress(0.2)

        for (offset, component) in components.enumerated() {
            try Task.checkCancellation()
            let fill = configuredFill ?? dominantBoundaryColor(
                    for: component,
                    masked: excluded,
                    source: source,
                    width: width,
                    height: height
                )
            for pixelIndex in component.pixels {
                let byteIndex = pixelIndex * 4
                source[byteIndex] = fill.red
                source[byteIndex + 1] = fill.green
                source[byteIndex + 2] = fill.blue
                source[byteIndex + 3] = fill.alpha
            }
            let completed = Double(offset + 1) / Double(max(components.count, 1))
            progress(0.2 + completed * 0.65)
        }

        try Task.checkCancellation()
        try writePNG(pixels: source, width: width, height: height, to: outputURL)
        progress(1)
    }

    private struct Component {
        var pixels: [Int]
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    private struct RGBAColor {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private func fixedFillMask(
        _ mask: [Bool],
        source: [UInt8],
        fill: RGBAColor,
        width: Int,
        height: Int
    ) -> [Bool] {
        let expanded = MaskDilation.dilated(
            mask,
            width: width,
            height: height,
            radius: Self.fixedFillHaloRadius
        )
        var result = mask
        for pixelIndex in result.indices where !result[pixelIndex] && expanded[pixelIndex] {
            let byteIndex = pixelIndex * 4
            let channelDistance = max(
                abs(Int(source[byteIndex]) - Int(fill.red)),
                abs(Int(source[byteIndex + 1]) - Int(fill.green)),
                abs(Int(source[byteIndex + 2]) - Int(fill.blue))
            )
            if channelDistance <= Self.fixedFillMaximumChannelDistance {
                result[pixelIndex] = true
            }
        }
        return result
    }

    private static func color(from hex: String) -> RGBAColor? {
        let normalized = DialogueStyle.normalizedHexColor(hex, fallback: "")
        guard normalized.count == 7 else { return nil }
        let digits = normalized.dropFirst()
        guard let red = UInt8(digits.prefix(2), radix: 16),
              let green = UInt8(digits.dropFirst(2).prefix(2), radix: 16),
              let blue = UInt8(digits.dropFirst(4).prefix(2), radix: 16) else {
            return nil
        }
        return RGBAColor(red: red, green: green, blue: blue, alpha: 255)
    }

    private func connectedComponents(
        masked: [Bool],
        width: Int,
        height: Int
    ) throws -> [Component] {
        var visited = [Bool](repeating: false, count: masked.count)
        var result: [Component] = []

        for start in masked.indices where masked[start] && !visited[start] {
            if result.count.isMultiple(of: 8) { try Task.checkCancellation() }
            var queue = [start]
            var cursor = 0
            var pixels: [Int] = []
            var minX = start % width
            var maxX = minX
            var minY = start / width
            var maxY = minY
            visited[start] = true

            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                pixels.append(current)
                let x = current % width
                let y = current / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                if x > 0 { enqueue(current - 1, masked: masked, visited: &visited, queue: &queue) }
                if x + 1 < width { enqueue(current + 1, masked: masked, visited: &visited, queue: &queue) }
                if y > 0 { enqueue(current - width, masked: masked, visited: &visited, queue: &queue) }
                if y + 1 < height { enqueue(current + width, masked: masked, visited: &visited, queue: &queue) }
            }
            result.append(Component(
                pixels: pixels,
                minX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY
            ))
        }
        return result
    }

    private func enqueue(
        _ index: Int,
        masked: [Bool],
        visited: inout [Bool],
        queue: inout [Int]
    ) {
        guard masked[index], !visited[index] else { return }
        visited[index] = true
        queue.append(index)
    }

    /// 同一區域的字通常會被二值遮罩拆成許多互不相連的筆畫。若逐筆畫取色，
    /// 掃描紙紋的些微亮度差就會被填成文字形狀的斑點；先依 region.bounds 合併，
    /// 整段文字只會使用一個穩定底色。無法歸屬區域的人工遮罩仍逐元件處理。
    private func groupedComponents(
        _ components: [Component],
        regions: [DialogueRegion],
        width: Int,
        height: Int
    ) -> [Component] {
        guard !components.isEmpty, !regions.isEmpty else { return components }
        let margin = max(0.005, 4 / Double(max(1, min(width, height))))
        let regionBounds = regions.map { region in
            (region.id, pixelBounds(
                for: region.bounds.expanded(by: margin),
                width: width,
                height: height
            ))
        }
        var grouped: [UUID: [Component]] = [:]
        var unassigned: [Component] = []
        for component in components {
            let match = regionBounds.compactMap { id, bounds -> (UUID, Int)? in
                let overlapWidth = max(
                    0,
                    min(component.maxX, bounds.maxX) - max(component.minX, bounds.minX) + 1
                )
                let overlapHeight = max(
                    0,
                    min(component.maxY, bounds.maxY) - max(component.minY, bounds.minY) + 1
                )
                let overlap = overlapWidth * overlapHeight
                return overlap > 0 ? (id, overlap) : nil
            }.max { $0.1 < $1.1 }
            if let match {
                grouped[match.0, default: []].append(component)
            } else {
                unassigned.append(component)
            }
        }
        let merged = regions.compactMap { region -> Component? in
            guard let values = grouped[region.id], let first = values.first else { return nil }
            return values.dropFirst().reduce(first) { partial, component in
                Component(
                    pixels: partial.pixels + component.pixels,
                    minX: min(partial.minX, component.minX),
                    minY: min(partial.minY, component.minY),
                    maxX: max(partial.maxX, component.maxX),
                    maxY: max(partial.maxY, component.maxY)
                )
            }
        }
        return merged + unassigned
    }

    private func pixelBounds(
        for bounds: NormalizedRect,
        width: Int,
        height: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let clamped = bounds.clamped()
        return (
            minX: max(0, min(width - 1, Int(floor(clamped.x * Double(width))))),
            minY: max(0, min(height - 1, Int(floor(clamped.y * Double(height))))),
            maxX: max(0, min(width - 1, Int(ceil(clamped.maxX * Double(width))) - 1)),
            maxY: max(0, min(height - 1, Int(ceil(clamped.maxY * Double(height))) - 1))
        )
    }

    private func dominantBoundaryColor(
        for component: Component,
        masked: [Bool],
        source: [UInt8],
        width: Int,
        height: Int
    ) -> RGBAColor {
        // `masked` 傳進來的是「膨脹後的排除範圍」，所以貼著元件往外找即可。
        let boundaryPixels = ringPixels(
            around: component,
            masked: masked,
            width: width,
            height: height,
            inset: Self.sampleInset
        )

        guard !boundaryPixels.isEmpty else {
            return RGBAColor(red: 255, green: 255, blue: 255, alpha: 255)
        }
        var bins = [ColorAccumulator](repeating: ColorAccumulator(), count: 16)
        for pixelIndex in boundaryPixels {
            let byteIndex = pixelIndex * 4
            let red = source[byteIndex]
            let green = source[byteIndex + 1]
            let blue = source[byteIndex + 2]
            let alpha = source[byteIndex + 3]
            let luminance = (
                299 * Int(red)
                    + 587 * Int(green)
                    + 114 * Int(blue)
            ) / 1_000
            let binIndex = min(15, luminance * 16 / 256)
            bins[binIndex].append(red: red, green: green, blue: blue, alpha: alpha)
        }
        guard let selectedEntry = bins.enumerated().max(by: { lhs, rhs in
            if lhs.element.count != rhs.element.count {
                return lhs.element.count < rhs.element.count
            }
            return lhs.offset < rhs.offset
        }), selectedEntry.element.count > 0 else {
            return RGBAColor(red: 255, green: 255, blue: 255, alpha: 255)
        }
        let selected = selectedEntry.element
        let red = selected.red / selected.count
        let green = selected.green / selected.count
        let blue = selected.blue / selected.count
        let averageLuminance = (299 * red + 587 * green + 114 * blue) / 1_000
        let channelSpread = max(red, green, blue) - min(red, green, blue)
        // 黑白漫畫的紙面若已落在最高亮度色階，繼續取平均會把少量掃描灰塵
        // 混成淡灰底塊。只有近白且低色偏時才正規化為純白；灰底與彩色底保留。
        if selectedEntry.offset == 15, averageLuminance >= 244, channelSpread <= 12 {
            return RGBAColor(red: 255, green: 255, blue: 255, alpha: 255)
        }
        return RGBAColor(
            red: UInt8(red),
            green: UInt8(green),
            blue: UInt8(blue),
            alpha: UInt8(selected.alpha / selected.count)
        )
    }

    /// 收集離元件 `inset`...`inset + thickness` 像素、且不在遮罩內的取樣點。
    private func ringPixels(
        around component: Component,
        masked: [Bool],
        width: Int,
        height: Int,
        inset: Int
    ) -> Set<Int> {
        let outer = inset + Self.sampleThickness
        var result: Set<Int> = []
        result.reserveCapacity(component.pixels.count)
        for pixelIndex in component.pixels {
            let x = pixelIndex % width
            let y = pixelIndex / width
            for offsetY in -outer...outer {
                let sampleY = y + offsetY
                guard sampleY >= 0, sampleY < height else { continue }
                for offsetX in -outer...outer {
                    // 用 Chebyshev 距離判斷屬於哪一圈。
                    let distance = max(abs(offsetX), abs(offsetY))
                    guard distance >= inset, distance <= outer else { continue }
                    let sampleX = x + offsetX
                    guard sampleX >= 0, sampleX < width else { continue }
                    let sampleIndex = sampleY * width + sampleX
                    if !masked[sampleIndex] { result.insert(sampleIndex) }
                }
            }
        }
        return result
    }

    private struct ColorAccumulator {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0

        mutating func append(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            count += 1
            self.red += Int(red)
            self.green += Int(green)
            self.blue += Int(blue)
            self.alpha += Int(alpha)
        }
    }

    private func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }

    private func writePNG(pixels: [UInt8], width: Int, height: Int, to outputURL: URL) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(image, to: outputURL)
    }
}
