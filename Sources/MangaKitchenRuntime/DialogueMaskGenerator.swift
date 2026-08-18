import CoreGraphics
import Foundation
import MangaKitchenCore

public actor DialogueMaskGenerator: DialogueMaskGenerating {
    public init() {}

    public func generateMask(
        sourceURL: URL,
        regions: [DialogueRegion],
        expansion: Double,
        outputURL: URL
    ) async throws {
        let source = try CGImageIO.load(from: sourceURL)
        let width = source.width
        let height = source.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let byteCount = width * height
        let bitmapData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt64>.alignment
        )
        bitmapData.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { bitmapData.deallocate() }
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for region in regions where region.automaticMaskEnabled {
            // 只有在確實知道對話框內緣時才裁切。若退回 region.bounds，外擴後的遮罩
            // 會立刻被裁回來源粗框，maskExpansion 等於完全失效。
            let bubbleBounds = region.bubbleBounds?.clamped()
            var clipRectangle: CGRect?
            if let bubbleBounds {
                let rectangle = pixelRect(for: bubbleBounds, width: width, height: height)
                guard rectangle.width > 0, rectangle.height > 0 else { continue }
                clipRectangle = rectangle
            }
            // 知道對話框實際形狀時就照形狀裁切。只用矩形，圓形框的四角會把
            // 人物與網點一起放進遮罩。
            let bubbleShape = region.bubbleMaskPolygons.compactMap {
                pixelRectangle(for: $0, width: width, height: height)
            }
            context.saveGState()
            if !bubbleShape.isEmpty {
                context.clip(to: bubbleShape)
            } else if let clipRectangle {
                context.clip(to: clipRectangle)
            }
            context.setFillColor(gray: 1, alpha: 1)

            if region.maskPolygons.isEmpty {
                var bounds = region.bounds.expanded(by: expansion)
                if let bubbleBounds {
                    bounds = bounds.intersection(with: bubbleBounds)
                }
                let rectangle = pixelRect(for: bounds, width: width, height: height)
                let radius = max(2, min(rectangle.width, rectangle.height) * 0.16)
                context.addPath(CGPath(
                    roundedRect: rectangle,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                ))
                context.fillPath()
            } else {
                // 精修遮罩的外擴餘裕已由 MangaTextMaskRefiner 在像素層膨脹完成。
                // 多邊形是逐列拆出的 run rectangle，在這裡對每一條個別描邊，
                // 斜筆畫那一堆 1px 高的矩形會各自鼓成圓角，邊界就長出扇貝狀毛邊。
                let expansionWidth = region.maskRefinementApplied
                    ? 0
                    : max(
                        0,
                        expansion * min(
                            region.bounds.width * Double(width),
                            region.bounds.height * Double(height)
                        ) * 2
                    )
                for polygon in region.maskPolygons {
                    guard let path = polygonPath(polygon, width: width, height: height) else { continue }
                    context.addPath(path)
                    context.fillPath()
                    if expansionWidth > 0 {
                        context.setStrokeColor(gray: 1, alpha: 1)
                        context.setLineWidth(expansionWidth)
                        context.setLineJoin(.round)
                        context.addPath(path)
                        context.strokePath()
                    }
                }
            }
            context.restoreGState()
        }

        for stroke in regions.flatMap(\.maskStrokes) {
            draw(stroke, in: context, width: width, height: height)
        }

        context.flush()
        let pixels = bitmapData.assumingMemoryBound(to: UInt8.self)
        for index in 0..<byteCount {
            pixels[index] = pixels[index] == 0 ? 0 : 255
        }

        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(image, to: outputURL)
    }

    /// 氣泡形狀是軸對齊矩形集合，直接轉成 CGRect 交給 CGContext 裁切。
    private func pixelRectangle(
        for polygon: [NormalizedPoint],
        width: Int,
        height: Int
    ) -> CGRect? {
        guard polygon.count >= 4 else { return nil }
        let xValues = polygon.map(\.x)
        let yValues = polygon.map(\.y)
        guard let minimumX = xValues.min(), let maximumX = xValues.max(),
              let minimumY = yValues.min(), let maximumY = yValues.max() else { return nil }
        let rectangle = CGRect(
            x: minimumX * Double(width),
            y: (1 - maximumY) * Double(height),
            width: (maximumX - minimumX) * Double(width),
            height: (maximumY - minimumY) * Double(height)
        ).integral
        return rectangle.width > 0 && rectangle.height > 0 ? rectangle : nil
    }

    private func pixelRect(for bounds: NormalizedRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: bounds.x * Double(width),
            y: (1 - bounds.maxY) * Double(height),
            width: bounds.width * Double(width),
            height: bounds.height * Double(height)
        ).integral
    }

    private func polygonPath(
        _ polygon: [NormalizedPoint],
        width: Int,
        height: Int
    ) -> CGPath? {
        guard polygon.count >= 3 else { return nil }
        let points = polygon.map { point in
            CGPoint(
                x: point.x * Double(width),
                y: (1 - point.y) * Double(height)
            )
        }
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func draw(_ stroke: MaskStroke, in context: CGContext, width: Int, height: Int) {
        let points = stroke.points.map { point in
            CGPoint(
                x: point.x * Double(width),
                y: (1 - point.y) * Double(height)
            )
        }
        guard let first = points.first else { return }

        let color: CGFloat = stroke.mode == .add ? 1 : 0
        let diameter = max(1, stroke.diameter * Double(min(width, height)))
        context.setFillColor(gray: color, alpha: 1)
        context.setStrokeColor(gray: color, alpha: 1)
        context.setLineWidth(diameter)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if points.count == 1 {
            context.fillEllipse(in: CGRect(
                x: first.x - diameter / 2,
                y: first.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            return
        }

        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }
}
