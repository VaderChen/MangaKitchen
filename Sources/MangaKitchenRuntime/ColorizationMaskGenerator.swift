import CoreGraphics
import Foundation
import MangaKitchenCore

/// 建立 DDColor 使用的反對話框遮罩：白色區域允許上色，黑色區域保留輸入。
public struct ColorizationMaskGenerator: Sendable {
    public init() {}

    public func generateMask(
        sourceURL: URL,
        regions: [DialogueRegion],
        strokes: [MaskStroke],
        outputURL: URL
    ) throws {
        let source = try CGImageIO.load(from: sourceURL)
        let width = source.width
        let height = source.height
        let byteCount = width * height
        let bitmapData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt64>.alignment
        )
        bitmapData.initializeMemory(as: UInt8.self, repeating: 255, count: byteCount)
        defer { bitmapData.deallocate() }
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.setFillColor(gray: 0, alpha: 1)
        for region in regions {
            context.saveGState()
            let bubbleShape = region.bubbleMaskPolygons.compactMap {
                pixelRectangle(for: $0, width: width, height: height)
            }
            if !bubbleShape.isEmpty {
                context.clip(to: bubbleShape)
            } else {
                context.clip(to: pixelRect(
                    for: region.bubbleBounds ?? region.bounds,
                    width: width,
                    height: height
                ))
            }
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }

        for stroke in strokes {
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

    private func pixelRectangle(
        for polygon: [NormalizedPoint],
        width: Int,
        height: Int
    ) -> CGRect? {
        guard polygon.count >= 3 else { return nil }
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

    private func draw(_ stroke: MaskStroke, in context: CGContext, width: Int, height: Int) {
        let points = stroke.points.map { point in
            CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height))
        }
        guard let first = points.first else { return }
        let value: CGFloat = stroke.mode == .add ? 1 : 0
        let diameter = max(1, stroke.diameter * Double(min(width, height)))
        context.setFillColor(gray: value, alpha: 1)
        context.setStrokeColor(gray: value, alpha: 1)
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
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }
}
