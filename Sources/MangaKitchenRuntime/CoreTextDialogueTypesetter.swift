import AppKit
import CoreGraphics
import CoreText
import Foundation
import MangaKitchenCore

public actor CoreTextDialogueTypesetter: DialogueTypesetting {
    public init() {}

    public func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL
    ) async throws {
        let background = try CGImageIO.load(from: backgroundURL)
        let width = background.width
        let height = background.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        for region in regions where !region.translatedText.isEmpty {
            try Task.checkCancellation()
            let outerRect = pixelRect(for: region.bounds, width: width, height: height)
            let inset = max(2, min(outerRect.width, outerRect.height) * 0.08)
            let textRect = outerRect.insetBy(dx: inset, dy: inset)
            guard textRect.width > 2, textRect.height > 2 else { continue }

            let writingDirection = resolvedDirection(for: region)
            let attributed = makeFittedText(
                region.translatedText,
                style: region.style,
                direction: writingDirection,
                availableSize: textRect.size
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: textRect, transform: nil)
            let frameAttributes: CFDictionary?
            if writingDirection == .vertical {
                frameAttributes = [
                    kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue
                ] as CFDictionary
            } else {
                frameAttributes = nil
            }
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                path,
                frameAttributes
            )
            CTFrameDraw(frame, context)
        }

        guard let output = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(output, to: outputURL)
    }

    private func makeFittedText(
        _ text: String,
        style: DialogueStyle,
        direction: WritingDirection,
        availableSize: CGSize
    ) -> NSAttributedString {
        if let fontSize = style.fontSize, fontSize.isFinite {
            return attributedText(
                text,
                style: style,
                direction: direction,
                fontSize: min(max(fontSize, 4), 512)
            )
        }
        let minimum = max(4, style.minimumFontSize)
        let maximum = max(minimum, style.maximumFontSize)
        var lower = minimum
        var upper = maximum
        var best = attributedText(text, style: style, direction: direction, fontSize: minimum)

        for _ in 0..<9 {
            let candidateSize = (lower + upper) / 2
            let candidate = attributedText(
                text,
                style: style,
                direction: direction,
                fontSize: candidateSize
            )
            if fits(candidate, in: availableSize, direction: direction) {
                best = candidate
                lower = candidateSize
            } else {
                upper = candidateSize
            }
        }
        return best
    }

    private func attributedText(
        _ text: String,
        style: DialogueStyle,
        direction: WritingDirection,
        fontSize: Double
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = max(0, fontSize * 0.04)
        let font = NSFont(name: style.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(from: style.textColorHex),
            .paragraphStyle: paragraph
        ]
        if direction == .vertical {
            attributes[kCTVerticalFormsAttributeName as NSAttributedString.Key] = true
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func fits(
        _ attributed: NSAttributedString,
        in size: CGSize,
        direction: WritingDirection
    ) -> Bool {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let attributes: CFDictionary?
        if direction == .vertical {
            attributes = [
                kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue
            ] as CFDictionary
        } else {
            attributes = nil
        }
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            attributes
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        return !lines.isEmpty && visibleRange.length >= attributed.length
    }

    private func resolvedDirection(for region: DialogueRegion) -> WritingDirection {
        guard region.style.writingDirection == .automatic else {
            return region.style.writingDirection
        }
        let isCJK = region.translatedText.unicodeScalars.contains { scalar in
            (0x3000...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        return isCJK && region.bounds.height > region.bounds.width * 1.25
            ? .vertical
            : .horizontal
    }

    private func pixelRect(for bounds: NormalizedRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: bounds.x * Double(width),
            y: (1 - bounds.maxY) * Double(height),
            width: bounds.width * Double(width),
            height: bounds.height * Double(height)
        ).integral
    }

    private func color(from hex: String) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .black }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
