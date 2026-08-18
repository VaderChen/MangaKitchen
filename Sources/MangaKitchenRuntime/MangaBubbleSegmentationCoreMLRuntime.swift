import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

/// 一個對話框候選：矩形框，加上分割模型給出的實際形狀。
///
/// `maskPolygons` 是軸對齊矩形集合而非輪廓多邊形，下游只需要判斷「這個像素在不在
/// 氣泡裡」，矩形集合在 CGContext 裁切與像素查表兩邊都比多邊形填充便宜。
/// 空陣列代表模型沒有輸出 prototype，此時只有 `bounds` 可用。
public struct BubbleDetection: Sendable {
    public var bounds: NormalizedRect
    public var maskPolygons: [[NormalizedPoint]]
    /// 完全落在氣泡形狀內的最大矩形，供譯文排版使用。
    ///
    /// 不能直接拿 `bounds` 排版：圓形對話框的外接矩形四角在氣泡之外，
    /// 填滿它的譯文會溢出到畫面上。也不能把 `bounds` 縮成這個值 ——
    /// 它同時是遮罩的搜尋邊界，縮了會讓貼著上下弧線的字沒被遮到。
    public var layoutBounds: NormalizedRect?

    public init(
        bounds: NormalizedRect,
        maskPolygons: [[NormalizedPoint]] = [],
        layoutBounds: NormalizedRect? = nil
    ) {
        self.bounds = bounds
        self.maskPolygons = maskPolygons
        self.layoutBounds = layoutBounds
    }
}

public final class MangaBubbleSegmentationCoreMLRuntime: @unchecked Sendable {
    private struct LetterboxedImage {
        var image: CGImage
        var scale: Double
        var horizontalPadding: Double
        var verticalPadding: Double
    }

    private struct Candidate {
        var bounds: NormalizedRect
        var confidence: Double
        /// YOLO-seg 的 32 個遮罩係數，與 prototype 線性組合後才是真正的氣泡形狀。
        var maskCoefficients: [Float]
        /// letterbox 座標下的框，用來把 prototype 裁到這個實例。
        var letterboxBounds: CGRect
    }

    private let modelURL: URL
    private let confidenceThreshold: Double
    private let intersectionOverUnionThreshold: Double
    private let maximumCandidates: Int
    /// 氣泡遮罩往內縮的來源像素數。YOLO 的框與分割遮罩都含框線本身，
    /// 不內縮的話字形搜尋會把黑色外框當成文字擦掉，邊緣就出現缺口。
    private let maskErosionPixels: Int
    private let lock = NSLock()
    private var model: MLModel?

    public init(
        modelURL: URL,
        confidenceThreshold: Double = 0.25,
        intersectionOverUnionThreshold: Double = 0.5,
        maximumCandidates: Int = 36,
        maskErosionPixels: Int = 3
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(modelURL)
        }
        self.modelURL = modelURL
        self.confidenceThreshold = min(max(confidenceThreshold, 0), 1)
        self.intersectionOverUnionThreshold = min(max(intersectionOverUnionThreshold, 0), 1)
        self.maximumCandidates = max(1, maximumCandidates)
        self.maskErosionPixels = max(0, maskErosionPixels)
    }

    public func detect(in source: CGImage) throws -> [NormalizedRect] {
        try detectBubbles(in: source).map(\.bounds)
    }

    public func detectBubbles(in source: CGImage) throws -> [BubbleDetection] {
        lock.lock()
        defer { lock.unlock() }

        let loadedModel = try resolvedModel()
        guard let input = loadedModel.modelDescription.inputDescriptionsByName.first(where: {
            $0.value.type == .image
        }), let constraint = input.value.imageConstraint else {
            throw ModelRuntimeError.featureNotFound("氣泡分割模型 image input")
        }
        guard constraint.pixelsWide == constraint.pixelsHigh,
              constraint.pixelsWide > 0 else {
            throw ModelRuntimeError.featureTypeMismatch(input.key)
        }

        let letterboxed = try makeLetterboxedImage(
            source,
            side: constraint.pixelsWide
        )
        let feature = try MLFeatureValue(
            cgImage: letterboxed.image,
            constraint: constraint,
            options: [:]
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [input.key: feature])
        let prediction = try loadedModel.prediction(from: provider)
        let rawPredictions = try predictionArray(from: prediction)
        let prototypes = maskPrototypeArray(from: prediction)
        let candidates = nonMaximumSuppressedCandidates(
            from: rawPredictions,
            sourceWidth: source.width,
            sourceHeight: source.height,
            letterboxed: letterboxed
        )
        return candidates.map { candidate in
            // 沒有 prototype 就退回矩形框；行為與加上分割前一致，不會整批失效。
            let shape = prototypes.map {
                bubbleShape(
                    for: candidate,
                    prototypes: $0,
                    sourceWidth: source.width,
                    sourceHeight: source.height,
                    letterboxed: letterboxed
                )
            }
            return BubbleDetection(
                bounds: candidate.bounds,
                maskPolygons: shape?.polygons ?? [],
                layoutBounds: shape?.layoutBounds
            )
        }
    }

    private func resolvedModel() throws -> MLModel {
        if let model { return model }

        let compiledURL: URL
        if modelURL.pathExtension.lowercased() == "mlmodelc" {
            compiledURL = modelURL
        } else {
            compiledURL = try MLModel.compileModel(at: modelURL)
        }

        let preferredConfiguration = MLModelConfiguration()
        preferredConfiguration.computeUnits = .cpuAndNeuralEngine
        let loadedModel: MLModel
        do {
            loadedModel = try MLModel(contentsOf: compiledURL, configuration: preferredConfiguration)
        } catch {
            let fallbackConfiguration = MLModelConfiguration()
            fallbackConfiguration.computeUnits = .all
            loadedModel = try MLModel(contentsOf: compiledURL, configuration: fallbackConfiguration)
        }
        model = loadedModel
        return loadedModel
    }

    private func makeLetterboxedImage(_ source: CGImage, side: Int) throws -> LetterboxedImage {
        guard source.width > 0, source.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let scale = min(
            Double(side) / Double(source.width),
            Double(side) / Double(source.height)
        )
        let scaledWidth = max(1, Int((Double(source.width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(source.height) * scale).rounded()))
        let horizontalPadding = (side - scaledWidth) / 2
        let verticalPadding = (side - scaledHeight) / 2

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.interpolationQuality = .high
        context.setFillColor(red: 114.0 / 255.0, green: 114.0 / 255.0, blue: 114.0 / 255.0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(
            source,
            in: CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: scaledWidth,
                height: scaledHeight
            )
        )
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return LetterboxedImage(
            image: image,
            scale: scale,
            horizontalPadding: Double(horizontalPadding),
            verticalPadding: Double(verticalPadding)
        )
    }

    private func predictionArray(from prediction: any MLFeatureProvider) throws -> MLMultiArray {
        for outputName in prediction.featureNames {
            guard let feature = prediction.featureValue(for: outputName),
                  feature.type == .multiArray,
                  let array = feature.multiArrayValue else {
                continue
            }
            let dimensions = array.shape.map(\.intValue)
            guard dimensions.count == 3,
                  dimensions[0] == 1,
                  dimensions[1] >= 5,
                  dimensions[1] <= 256,
                  dimensions[2] > dimensions[1] else {
                continue
            }
            return array
        }
        throw ModelRuntimeError.featureNotFound("YOLO 氣泡預測輸出")
    }

    /// YOLO-seg 的第二個輸出是 [1, 32, H, W] 的 prototype。與候選框的 32 個係數
    /// 線性組合再取 sigmoid，才得到該實例的遮罩。
    private func maskPrototypeArray(from prediction: any MLFeatureProvider) -> MLMultiArray? {
        for outputName in prediction.featureNames {
            guard let feature = prediction.featureValue(for: outputName),
                  feature.type == .multiArray,
                  let array = feature.multiArrayValue else { continue }
            let dimensions = array.shape.map(\.intValue)
            guard dimensions.count == 4,
                  dimensions[0] == 1,
                  dimensions[1] > 1,
                  dimensions[2] > 1,
                  dimensions[3] > 1 else { continue }
            return array
        }
        return nil
    }

    private func nonMaximumSuppressedCandidates(
        from predictions: MLMultiArray,
        sourceWidth: Int,
        sourceHeight: Int,
        letterboxed: LetterboxedImage
    ) -> [Candidate] {
        let dimensions = predictions.shape.map(\.intValue)
        let featureCount = dimensions[1]
        let candidateCount = dimensions[2]
        guard featureCount >= 5 else { return [] }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(candidateCount, maximumCandidates * 4))
        for candidateIndex in 0..<candidateCount {
            let confidence = Double(value(
                in: predictions,
                batch: 0,
                feature: 4,
                candidate: candidateIndex
            ))
            guard confidence >= confidenceThreshold else { continue }

            let centerX = Double(value(in: predictions, batch: 0, feature: 0, candidate: candidateIndex))
            let centerY = Double(value(in: predictions, batch: 0, feature: 1, candidate: candidateIndex))
            let width = Double(value(in: predictions, batch: 0, feature: 2, candidate: candidateIndex))
            let height = Double(value(in: predictions, batch: 0, feature: 3, candidate: candidateIndex))
            guard width > 0, height > 0 else { continue }

            let left = (centerX - width / 2 - letterboxed.horizontalPadding) / letterboxed.scale
            let top = (centerY - height / 2 - letterboxed.verticalPadding) / letterboxed.scale
            let right = (centerX + width / 2 - letterboxed.horizontalPadding) / letterboxed.scale
            let bottom = (centerY + height / 2 - letterboxed.verticalPadding) / letterboxed.scale
            let normalized = NormalizedRect(
                x: left / Double(sourceWidth),
                y: top / Double(sourceHeight),
                width: (right - left) / Double(sourceWidth),
                height: (bottom - top) / Double(sourceHeight)
            ).clamped()
            guard normalized.width > 0, normalized.height > 0 else { continue }
            var maskCoefficients: [Float] = []
            if featureCount > 5 {
                maskCoefficients.reserveCapacity(featureCount - 5)
                for featureIndex in 5..<featureCount {
                    maskCoefficients.append(value(
                        in: predictions,
                        batch: 0,
                        feature: featureIndex,
                        candidate: candidateIndex
                    ))
                }
            }
            candidates.append(Candidate(
                bounds: normalized,
                confidence: confidence,
                maskCoefficients: maskCoefficients,
                letterboxBounds: CGRect(
                    x: centerX - width / 2,
                    y: centerY - height / 2,
                    width: width,
                    height: height
                )
            ))
        }

        let ordered = candidates.sorted { $0.confidence > $1.confidence }
        var retained: [Candidate] = []
        retained.reserveCapacity(min(ordered.count, maximumCandidates))
        for candidate in ordered {
            guard !retained.contains(where: {
                intersectionOverUnion(candidate.bounds, $0.bounds) >= intersectionOverUnionThreshold
            }) else {
                continue
            }
            retained.append(candidate)
            if retained.count == maximumCandidates { break }
        }
        return retained.sorted {
            let rowTolerance = max($0.bounds.height, $1.bounds.height) * 0.25
            if abs($0.bounds.minY - $1.bounds.minY) > rowTolerance {
                return $0.bounds.minY < $1.bounds.minY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
    }

    /// 把單一候選的分割遮罩解出來，轉成來源圖正規化座標的軸對齊矩形集合。
    ///
    /// 用矩形集合而不是輪廓多邊形，是因為下游只需要「這個像素在不在氣泡裡」：
    /// CGContext 可以直接 clip 一組矩形，像素端也只是查表，兩邊都不必做多邊形填充。
    private func bubbleShape(
        for candidate: Candidate,
        prototypes: MLMultiArray,
        sourceWidth: Int,
        sourceHeight: Int,
        letterboxed: LetterboxedImage
    ) -> (polygons: [[NormalizedPoint]], layoutBounds: NormalizedRect?) {
        let dimensions = prototypes.shape.map(\.intValue)
        let prototypeCount = dimensions[1]
        let prototypeHeight = dimensions[2]
        let prototypeWidth = dimensions[3]
        let usableCount = min(prototypeCount, candidate.maskCoefficients.count)
        guard usableCount > 0 else { return ([], nil) }

        // prototype 的解析度低於 letterbox 輸入，先換算出這個框在 prototype 上的範圍。
        let letterboxSide = Double(prototypeWidth) // 方形輸入，寬高比例一致
        let scaleToPrototype = letterboxSide / Double(letterboxed.image.width)
        let minX = max(0, Int((candidate.letterboxBounds.minX * scaleToPrototype).rounded(.down)))
        let maxX = min(prototypeWidth, Int((candidate.letterboxBounds.maxX * scaleToPrototype).rounded(.up)))
        let minY = max(0, Int((candidate.letterboxBounds.minY * scaleToPrototype).rounded(.down)))
        let maxY = min(prototypeHeight, Int((candidate.letterboxBounds.maxY * scaleToPrototype).rounded(.up)))
        guard maxX > minX, maxY > minY else { return ([], nil) }

        let strides = prototypes.strides.map(\.intValue)
        let localWidth = maxX - minX
        let localHeight = maxY - minY
        var inside = [Bool](repeating: false, count: localWidth * localHeight)
        for y in minY..<maxY {
            for x in minX..<maxX {
                var total: Float = 0
                for channel in 0..<usableCount {
                    let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                    total += candidate.maskCoefficients[channel] * prototypeValue(prototypes, at: offset)
                }
                // sigmoid > 0.5 等價於線性組合 > 0，省掉一次 exp。
                inside[(y - minY) * localWidth + (x - minX)] = total > 0
            }
        }

        // 遮罩含氣泡框線本身，往內縮再交給下游，字形搜尋才不會咬到黑色外框。
        let prototypePixelsPerSourcePixel = scaleToPrototype * letterboxed.scale
        // prototype 通常是輸入圖的 1/4 解析度；直接四捨五入會讓 3px 在
        // 大圖上變成 0，等於完全沒有內縮。只要設定了來源像素內縮，就至少
        // 內縮一個 prototype 像素，避免框線重新落入文字搜尋範圍。
        let erosionRounds = maskErosionPixels > 0
            ? max(
                1,
                Int((Double(maskErosionPixels) * prototypePixelsPerSourcePixel).rounded(.up))
            )
            : 0
        for _ in 0..<max(0, erosionRounds) {
            inside = eroded(inside, width: localWidth, height: localHeight)
        }

        let polygons = normalizedRunRectangles(
            inside,
            width: localWidth,
            height: localHeight,
            originX: minX,
            originY: minY,
            scaleToPrototype: scaleToPrototype,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            letterboxed: letterboxed
        )
        let layoutBounds = maximalInsideRectangle(
            inside,
            width: localWidth,
            height: localHeight
        ).flatMap { rectangle -> NormalizedRect? in
            let left = sourceCoordinate(
                Double(minX + rectangle.minX), scaleToPrototype: scaleToPrototype,
                padding: letterboxed.horizontalPadding, scale: letterboxed.scale,
                dimension: sourceWidth
            )
            let right = sourceCoordinate(
                Double(minX + rectangle.maxX), scaleToPrototype: scaleToPrototype,
                padding: letterboxed.horizontalPadding, scale: letterboxed.scale,
                dimension: sourceWidth
            )
            let top = sourceCoordinate(
                Double(minY + rectangle.minY), scaleToPrototype: scaleToPrototype,
                padding: letterboxed.verticalPadding, scale: letterboxed.scale,
                dimension: sourceHeight
            )
            let bottom = sourceCoordinate(
                Double(minY + rectangle.maxY), scaleToPrototype: scaleToPrototype,
                padding: letterboxed.verticalPadding, scale: letterboxed.scale,
                dimension: sourceHeight
            )
            guard right > left, bottom > top else { return nil }
            return NormalizedRect(
                x: left, y: top, width: right - left, height: bottom - top
            ).clamped()
        }
        return (polygons, layoutBounds)
    }

    private func sourceCoordinate(
        _ prototypeValue: Double,
        scaleToPrototype: Double,
        padding: Double,
        scale: Double,
        dimension: Int
    ) -> Double {
        min(max((prototypeValue / scaleToPrototype - padding) / scale / Double(dimension), 0), 1)
    }

    /// 二值遮罩裡完全為 true 的最大軸對齊矩形。逐列累積高度，再用單調堆疊求
    /// 每一列直方圖的最大矩形，整體 O(寬 × 高)。
    private func maximalInsideRectangle(
        _ mask: [Bool],
        width: Int,
        height: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard width > 0, height > 0 else { return nil }
        var heights = [Int](repeating: 0, count: width)
        var bestArea = 0
        var best: (minX: Int, minY: Int, maxX: Int, maxY: Int)?

        for y in 0..<height {
            for x in 0..<width {
                heights[x] = mask[y * width + x] ? heights[x] + 1 : 0
            }
            var stack: [(start: Int, height: Int)] = []
            for x in 0...width {
                let currentHeight = x < width ? heights[x] : 0
                var start = x
                while let last = stack.last, last.height > currentHeight {
                    stack.removeLast()
                    let area = last.height * (x - last.start)
                    if area > bestArea {
                        bestArea = area
                        best = (
                            minX: last.start,
                            minY: y - last.height + 1,
                            maxX: x,
                            maxY: y + 1
                        )
                    }
                    start = last.start
                }
                if stack.last?.height != currentHeight {
                    stack.append((start: start, height: currentHeight))
                }
            }
        }
        return best
    }

    private func prototypeValue(_ array: MLMultiArray, at offset: Int) -> Float {
        switch array.dataType {
        case .float32: array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        case .float16: Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        default: 0
        }
    }

    private func eroded(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var result = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index] else { continue }
                // 碰到裁切邊界就視為外部，避免框緣殘留一圈。
                guard x > 0, y > 0, x < width - 1, y < height - 1,
                      mask[index - 1], mask[index + 1],
                      mask[index - width], mask[index + width] else { continue }
                result[index] = true
            }
        }
        return result
    }

    /// 逐列把連續的 true 併成矩形，再換算回來源圖正規化座標。
    private func normalizedRunRectangles(
        _ mask: [Bool],
        width: Int,
        height: Int,
        originX: Int,
        originY: Int,
        scaleToPrototype: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        letterboxed: LetterboxedImage
    ) -> [[NormalizedPoint]] {
        func sourceX(_ prototypeX: Double) -> Double {
            (prototypeX / scaleToPrototype - letterboxed.horizontalPadding)
                / letterboxed.scale / Double(sourceWidth)
        }
        func sourceY(_ prototypeY: Double) -> Double {
            (prototypeY / scaleToPrototype - letterboxed.verticalPadding)
                / letterboxed.scale / Double(sourceHeight)
        }

        var rectangles: [[NormalizedPoint]] = []
        for y in 0..<height {
            var runStart: Int?
            for x in 0...width {
                let filled = x < width && mask[y * width + x]
                if filled, runStart == nil { runStart = x }
                guard !filled, let start = runStart else { continue }
                runStart = nil
                let left = min(max(sourceX(Double(originX + start)), 0), 1)
                let right = min(max(sourceX(Double(originX + x)), 0), 1)
                let top = min(max(sourceY(Double(originY + y)), 0), 1)
                let bottom = min(max(sourceY(Double(originY + y + 1)), 0), 1)
                guard right > left, bottom > top else { continue }
                rectangles.append([
                    NormalizedPoint(x: left, y: top),
                    NormalizedPoint(x: right, y: top),
                    NormalizedPoint(x: right, y: bottom),
                    NormalizedPoint(x: left, y: bottom)
                ])
            }
        }
        return rectangles
    }

    private func value(
        in array: MLMultiArray,
        batch: Int,
        feature: Int,
        candidate: Int
    ) -> Float {
        let offset = batch * array.strides[0].intValue
            + feature * array.strides[1].intValue
            + candidate * array.strides[2].intValue
        switch array.dataType {
        case .float32:
            return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double:
            return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        case .float16:
            return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        default:
            return array[[NSNumber(value: batch), NSNumber(value: feature), NSNumber(value: candidate)]].floatValue
        }
    }

    private func intersectionOverUnion(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let intersection = lhs.intersection(with: rhs)
        let intersectionArea = intersection.width * intersection.height
        guard intersectionArea > 0 else { return 0 }
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        return intersectionArea / max(lhsArea + rhsArea - intersectionArea, .leastNonzeroMagnitude)
    }
}
