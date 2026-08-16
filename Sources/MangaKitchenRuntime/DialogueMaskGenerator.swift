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
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for region in regions where region.automaticMaskEnabled {
            let bounds = region.bounds.expanded(by: expansion)
            let rectangle = CGRect(
                x: bounds.x * Double(width),
                y: (1 - bounds.maxY) * Double(height),
                width: bounds.width * Double(width),
                height: bounds.height * Double(height)
            ).integral
            let radius = max(2, min(rectangle.width, rectangle.height) * 0.16)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(CGPath(roundedRect: rectangle, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        for stroke in regions.flatMap(\.maskStrokes) {
            draw(stroke, in: context, width: width, height: height)
        }

        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(image, to: outputURL)
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
