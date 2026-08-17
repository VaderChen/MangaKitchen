import AppKit
import CoreGraphics
import CoreText
import Foundation
import MangaKitchenCore

public actor CoreTextDialogueTypesetter: DialogueTypesetting {
    private struct FittedText {
        var attributed: NSAttributedString
        var fontSize: Double
        var fitsCompletely: Bool
    }

    private struct LayoutPlan {
        var attributed: NSAttributedString
        var textRect: CGRect
        var clippingRect: CGRect
        var direction: WritingDirection
    }

    private struct LayoutGeometry {
        var regionID: UUID
        var direction: WritingDirection
        var clippingRect: CGRect
        var sourceRect: CGRect
        var translationAnchor: CGPoint?
        /// 已知對話框時的安全橢圓。對話框是橢圓形，但 bubbleBounds 是它的
        /// 外接矩形；把字排滿矩形，四角的字必然壓到或越過框線。
        var bubbleEllipse: CGRect?

        /// 已知對話框時置中於對話框，這也是漫畫嵌字的慣例；
        /// 否則沿用原文字區域的位置。
        var anchor: CGPoint {
            if let translationAnchor { return translationAnchor }
            if let bubbleEllipse {
                return CGPoint(x: bubbleEllipse.midX, y: bubbleEllipse.midY)
            }
            return CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        }
    }

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

        let renderableRegions = regions.filter { !$0.translatedText.isEmpty }
        let geometries = renderableRegions.compactMap {
            layoutGeometry(for: $0, width: width, height: height)
        }
        let geometryByID = Dictionary(
            uniqueKeysWithValues: geometries.map { ($0.regionID, $0) }
        )

        for region in renderableRegions {
            try Task.checkCancellation()
            guard let geometry = geometryByID[region.id] else { continue }
            let layoutCell = nonOverlappingLayoutCell(
                for: geometry,
                among: geometries
            )
            guard let plan = layoutPlan(
                for: region,
                geometry: geometry,
                layoutCell: layoutCell
            ) else { continue }
            let framesetter = CTFramesetterCreateWithAttributedString(plan.attributed)
            let path = CGPath(rect: plan.textRect, transform: nil)
            let frameAttributes: CFDictionary?
            if plan.direction == .vertical {
                frameAttributes = [
                    kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue
                ] as CFDictionary
            } else {
                frameAttributes = nil
            }
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: plan.attributed.length),
                path,
                frameAttributes
            )
            // Core Text 的字形（特別是直排標點）可能略微伸出 frame path，
            // 因此仍以安全內框硬裁切。但不沿橢圓裁切：bubbleBounds 沒有形狀資訊，
            // 方形旁白框若被橢圓裁掉四角就是毀字。溢出改在配置階段用 sizeFitted
            // 把區塊縮進橢圓內解決，圓框不會超出，方框也不會被切壞。
            context.saveGState()
            context.clip(to: plan.clippingRect)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }

        guard let output = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(output, to: outputURL)
    }

    private func layoutGeometry(
        for region: DialogueRegion,
        width: Int,
        height: Int
    ) -> LayoutGeometry? {
        let hasExplicitTranslationBounds = region.translationBounds != nil
        let hasBubble = !hasExplicitTranslationBounds && region.bubbleBounds != nil
        let originalHardBounds = (
            region.translationBounds ?? region.bubbleBounds ?? region.bounds
        ).clamped()
        let hardBounds: NormalizedRect
        if let anchor = region.translationAnchor?.clamped() {
            hardBounds = NormalizedRect(
                x: min(max(anchor.x - originalHardBounds.width / 2, 0), 1 - originalHardBounds.width),
                y: min(max(anchor.y - originalHardBounds.height / 2, 0), 1 - originalHardBounds.height),
                width: originalHardBounds.width,
                height: originalHardBounds.height
            )
        } else {
            hardBounds = originalHardBounds
        }
        let outerRect = pixelRect(for: hardBounds, width: width, height: height)
        let inset = hasExplicitTranslationBounds
            ? 0
            : max(2, min(outerRect.width, outerRect.height) * 0.055)
        let clippingRect = outerRect.insetBy(dx: inset, dy: inset).integral
        guard clippingRect.width > 4, clippingRect.height > 4 else { return nil }
        // bubbleBounds 描述的是對話框；region.bounds 只是原文字的粗框，
        // 後者本來就是矩形，不該再套橢圓限制。
        let bubbleEllipse = hasBubble ? clippingRect : nil

        let direction = resolvedDirection(for: region)
        let sourceBounds = maskPolygonBounds(for: region) ?? region.bounds
        let translationAnchor = region.translationAnchor.map {
            CGPoint(
                x: $0.x * Double(width),
                y: (1 - $0.y) * Double(height)
            )
        }
        var sourceRect: CGRect
        if let translationAnchor {
            let sourceSize = pixelRect(for: sourceBounds, width: width, height: height).size
            sourceRect = CGRect(
                x: translationAnchor.x - sourceSize.width / 2,
                y: translationAnchor.y - sourceSize.height / 2,
                width: sourceSize.width,
                height: sourceSize.height
            ).intersection(clippingRect)
        } else {
            sourceRect = pixelRect(for: sourceBounds, width: width, height: height)
                .intersection(clippingRect)
        }
        if sourceRect.isNull || sourceRect.width < 2 || sourceRect.height < 2 {
            if let translationAnchor {
                sourceRect = CGRect(
                    x: translationAnchor.x - 1,
                    y: translationAnchor.y - 1,
                    width: 2,
                    height: 2
                ).intersection(clippingRect)
            } else {
                sourceRect = pixelRect(for: region.bounds, width: width, height: height)
                    .intersection(clippingRect)
            }
        }
        guard !sourceRect.isNull, sourceRect.width > 0, sourceRect.height > 0 else {
            return nil
        }

        return LayoutGeometry(
            regionID: region.id,
            direction: direction,
            clippingRect: clippingRect,
            sourceRect: sourceRect,
            translationAnchor: translationAnchor,
            bubbleEllipse: bubbleEllipse
        )
    }

    /// 置中於橢圓的區塊，其半寬 w、半高 h 必須滿足 (w/a)² + (h/b)² ≤ 1。
    /// 超出時等比例縮回橢圓內，比固定內縮矩形更能保留細長欄位的可用空間。
    private func sizeFitted(_ size: CGSize, inEllipse ellipse: CGRect) -> CGSize {
        let semiWidth = ellipse.width / 2
        let semiHeight = ellipse.height / 2
        guard semiWidth > 0, semiHeight > 0 else { return size }
        let ratioX = size.width / 2 / semiWidth
        let ratioY = size.height / 2 / semiHeight
        let overflow = (ratioX * ratioX + ratioY * ratioY).squareRoot()
        guard overflow > 1 else { return size }
        return CGSize(width: size.width / overflow, height: size.height / overflow)
    }

    private func nonOverlappingLayoutCell(
        for geometry: LayoutGeometry,
        among geometries: [LayoutGeometry]
    ) -> CGRect {
        var minX = geometry.clippingRect.minX
        var maxX = geometry.clippingRect.maxX
        var minY = geometry.clippingRect.minY
        var maxY = geometry.clippingRect.maxY
        for other in geometries where other.regionID != geometry.regionID {
            guard other.direction == geometry.direction else { continue }
            let overlap = geometry.clippingRect.intersection(other.clippingRect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }

            if geometry.direction == .vertical {
                let requiredOverlap = min(
                    geometry.clippingRect.height,
                    other.clippingRect.height
                ) * 0.3
                guard overlap.height >= requiredOverlap else { continue }
                let midpoint = (geometry.anchor.x + other.anchor.x) / 2
                if other.anchor.x < geometry.anchor.x {
                    minX = max(minX, midpoint)
                } else if other.anchor.x > geometry.anchor.x {
                    maxX = min(maxX, midpoint)
                }
            } else {
                let requiredOverlap = min(
                    geometry.clippingRect.width,
                    other.clippingRect.width
                ) * 0.3
                guard overlap.width >= requiredOverlap else { continue }
                let midpoint = (geometry.anchor.y + other.anchor.y) / 2
                if other.anchor.y < geometry.anchor.y {
                    minY = max(minY, midpoint)
                } else if other.anchor.y > geometry.anchor.y {
                    maxY = min(maxY, midpoint)
                }
            }
        }
        let cell = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard cell.width >= 4, cell.height >= 4 else {
            return geometry.clippingRect
        }
        return cell.integral
    }

    private func layoutPlan(
        for region: DialogueRegion,
        geometry: LayoutGeometry,
        layoutCell: CGRect
    ) -> LayoutPlan? {
        let direction = geometry.direction
        let clippingRect = layoutCell
        var sourceRect = geometry.sourceRect.intersection(clippingRect)
        if sourceRect.isNull || sourceRect.width < 2 || sourceRect.height < 2 {
            let anchor = CGPoint(
                x: min(max(geometry.anchor.x, clippingRect.minX + 2), clippingRect.maxX - 2),
                y: min(max(geometry.anchor.y, clippingRect.minY + 2), clippingRect.maxY - 2)
            )
            sourceRect = CGRect(x: anchor.x - 1, y: anchor.y - 1, width: 2, height: 2)
        }

        // 非重疊切割後的橢圓仍要落在可用欄位內，避免相鄰對話框互相蓋住。
        let bubbleEllipse = geometry.bubbleEllipse.map { $0.intersection(clippingRect) }
            .flatMap { $0.isNull || $0.width < 4 || $0.height < 4 ? nil : $0 }

        let preferredMaximum = preferredMaximumFontSize(
            for: region,
            sourceRect: geometry.sourceRect
        )
        var desiredSize = estimatedLayoutSize(
            sourceText: region.sourceText,
            translatedText: region.translatedText,
            sourceRect: sourceRect,
            direction: direction,
            fontSize: preferredMaximum,
            style: region.style,
            maximumSize: clippingRect.size
        )
        if let bubbleEllipse {
            desiredSize = sizeFitted(desiredSize, inEllipse: bubbleEllipse)
        }
        let rawAnchor = bubbleEllipse.map { CGPoint(x: $0.midX, y: $0.midY) } ?? geometry.anchor
        let anchor = CGPoint(
            x: min(max(rawAnchor.x, clippingRect.minX), clippingRect.maxX),
            y: min(max(rawAnchor.y, clippingRect.minY), clippingRect.maxY)
        )
        var selected: (FittedText, CGRect)?

        // 先盡量維持原文字區域的位置與尺寸。只要縮字後能完整容納就停止；
        // 只有連 4 pt 都放不下時才逐步使用更多的非重疊欄位空間。
        for fraction in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            var candidateSize = CGSize(
                width: desiredSize.width
                    + (clippingRect.width - desiredSize.width) * fraction,
                height: desiredSize.height
                    + (clippingRect.height - desiredSize.height) * fraction
            )
            // 放大時同樣不能超出對話框橢圓，否則四角的字會壓到框線。
            if let bubbleEllipse {
                candidateSize = sizeFitted(candidateSize, inEllipse: bubbleEllipse)
            }
            let candidateRect = anchoredRect(
                size: candidateSize,
                anchor: anchor,
                inside: clippingRect
            )
            let fitted = makeFittedText(
                region.translatedText,
                style: region.style,
                direction: direction,
                availableSize: candidateRect.size,
                preferredMaximum: preferredMaximum
            )
            selected = (fitted, candidateRect)
            if fitted.fitsCompletely {
                break
            }
        }

        guard let selected else { return nil }
        return LayoutPlan(
            attributed: selected.0.attributed,
            textRect: selected.1,
            clippingRect: clippingRect,
            direction: direction
        )
    }

    private func makeFittedText(
        _ text: String,
        style: DialogueStyle,
        direction: WritingDirection,
        availableSize: CGSize,
        preferredMaximum: Double
    ) -> FittedText {
        let minimum = 4.0
        let maximum = min(max(preferredMaximum, minimum), 512)
        var lower = minimum
        var upper = maximum
        var best = attributedText(
            text,
            style: style,
            direction: direction,
            fontSize: minimum
        )
        guard fits(best, in: availableSize, direction: direction) else {
            return FittedText(
                attributed: best,
                fontSize: minimum,
                fitsCompletely: false
            )
        }

        let preferred = attributedText(
            text,
            style: style,
            direction: direction,
            fontSize: maximum
        )
        if fits(preferred, in: availableSize, direction: direction) {
            return FittedText(
                attributed: preferred,
                fontSize: maximum,
                fitsCompletely: true
            )
        }

        for _ in 0..<10 {
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
        return FittedText(
            attributed: best,
            fontSize: lower,
            fitsCompletely: true
        )
    }

    private func preferredMaximumFontSize(
        for region: DialogueRegion,
        sourceRect: CGRect
    ) -> Double {
        if let fontSize = region.style.fontSize, fontSize.isFinite {
            return min(max(fontSize, 4), 512)
        }
        let sourceCount = max(visibleCharacterCount(region.sourceText), 1)
        let inferred = sqrt(
            max(sourceRect.width * sourceRect.height, 1) / Double(sourceCount)
        ) * 1.08
        return min(
            max(inferred, max(4, region.style.minimumFontSize)),
            min(max(region.style.maximumFontSize, 4), 512)
        )
    }

    private func estimatedLayoutSize(
        sourceText: String,
        translatedText: String,
        sourceRect: CGRect,
        direction: WritingDirection,
        fontSize: Double,
        style: DialogueStyle,
        maximumSize: CGSize
    ) -> CGSize {
        let sourceCount = max(visibleCharacterCount(sourceText), 1)
        let targetCount = max(visibleCharacterCount(translatedText), 1)
        // CJK 全形字的字身推進就是一個字級。
        let glyphAdvance = max(4, fontSize)
        let lineAdvance = max(4, lineAdvance(fontSize: fontSize, style: style))
        let padding = max(2, fontSize * 0.32) * 2
        let width: Double
        let height: Double

        if direction == .vertical {
            let sourceColumns = max(1, Int((sourceRect.width / lineAdvance).rounded()))
            let sourceRows = max(1, Int(ceil(Double(sourceCount) / Double(sourceColumns))))
            let targetColumns = max(1, Int(ceil(Double(targetCount) / Double(sourceRows))))
            let targetRows = max(1, Int(ceil(Double(targetCount) / Double(targetColumns))))
            width = Double(targetColumns) * lineAdvance + padding
            height = Double(targetRows) * glyphAdvance + padding
        } else {
            let sourceRows = max(1, Int((sourceRect.height / lineAdvance).rounded()))
            let sourceColumns = max(1, Int(ceil(Double(sourceCount) / Double(sourceRows))))
            let targetRows = max(1, Int(ceil(Double(targetCount) / Double(sourceColumns))))
            let targetColumns = max(1, Int(ceil(Double(targetCount) / Double(targetRows))))
            width = Double(targetColumns) * glyphAdvance + padding
            height = Double(targetRows) * lineAdvance + padding
        }

        return CGSize(
            width: min(max(4, width), maximumSize.width),
            height: min(max(4, height), maximumSize.height)
        )
    }

    private func anchoredRect(
        size: CGSize,
        anchor: CGPoint,
        inside bounds: CGRect
    ) -> CGRect {
        let width = min(max(4, size.width), bounds.width)
        let height = min(max(4, size.height), bounds.height)
        let x = min(max(anchor.x - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(anchor.y - height / 2, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private func maskPolygonBounds(for region: DialogueRegion) -> NormalizedRect? {
        let points = region.maskPolygons.flatMap { $0 }
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        guard maxX > minX, maxY > minY else { return nil }
        return NormalizedRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).clamped()
    }

    private func visibleCharacterCount(_ text: String) -> Int {
        max(
            1,
            text.reduce(into: 0) { count, character in
                if !character.isWhitespace { count += 1 }
            }
        )
    }

    /// 欄距（直排）／行距（橫排）的實際推進量。
    /// 原本寫死 fontSize * 1.14，但 Core Text 以字型的 ascent + descent + leading
    /// 排版：PingFang TC 自然行高就是 1.40 字級，Hiragino Sans 更達 1.50。
    /// 低估兩成以上會讓預估區塊過窄，配適時被迫縮字或折出不自然的欄數。
    private func lineAdvance(fontSize: Double, style: DialogueStyle) -> Double {
        let font = resolvedFont(style: style, fontSize: fontSize) as CTFont
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return max(natural, fontSize) + lineGap(fontSize: fontSize)
    }

    /// 欄與欄之間額外留白。緊貼著排在對話框裡不易閱讀。
    private func lineGap(fontSize: Double) -> Double {
        max(0, fontSize * 0.12)
    }

    private func resolvedFont(style: DialogueStyle, fontSize: Double) -> NSFont {
        let regularFont = NSFont(name: style.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
        guard style.fontWeight == .bold else { return regularFont }
        let boldDescriptor = regularFont.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: boldDescriptor, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
    }

    private func attributedText(
        _ text: String,
        style: DialogueStyle,
        direction: WritingDirection,
        fontSize: Double
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // 直排時「行」就是一欄，行首在最上方。置中會讓字數較少的末欄浮在半空，
        // 與漫畫直排各欄齊頭的排法不符；橫排則維持置中。
        paragraph.alignment = direction == .vertical ? .left : .center
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = lineGap(fontSize: fontSize)
        let font = resolvedFont(style: style, fontSize: fontSize)
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
        let isCJK = (region.sourceText + region.translatedText).unicodeScalars.contains { scalar in
            (0x3000...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        let sourceBounds = maskPolygonBounds(for: region) ?? region.bounds
        let hasVerticalColumnSeparators = region.sourceText.contains("\u{3000}")
        return isCJK && (
            hasVerticalColumnSeparators
                || sourceBounds.height > sourceBounds.width * 0.8
        )
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
