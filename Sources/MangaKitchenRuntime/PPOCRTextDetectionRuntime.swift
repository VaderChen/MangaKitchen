import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

/// 原生 Core ML PP-OCRv6 Medium 文字定位 runtime。
///
/// 只將整頁影像轉成文字行座標，不做 OCR、不建立 `DialogueRegion`，也不修改遮罩。
/// 正式工作流程可在使用者明確選擇後將它接到步驟二；既有 VLM 定位仍可並存。
public actor PPOCRTextDetectionRuntime: LocalTextLocating {
    private struct Letterbox {
        var input: MLMultiArray
        var scaledWidth: Int
        var scaledHeight: Int
        var horizontalPadding: Int
        var verticalPadding: Int
    }

    private struct Component {
        var confidence: Double
        var minimumX: Int
        var minimumY: Int
        var maximumX: Int
        var maximumY: Int
        var pixelCount: Int
    }

    public let modelID: String

    private let modelURL: URL
    private let pixelThreshold: Float
    private let boxThreshold: Double
    private let unclipRatio: Double
    private let maximumCandidates: Int
    private let minimumComponentPixels: Int
    private let mean: [Float]
    private let standardDeviation: [Float]
    private var model: MLModel?

    public init(
        modelURL: URL,
        modelID: String = "ppocrv6-medium-det",
        pixelThreshold: Float = 0.2,
        boxThreshold: Double = 0.45,
        unclipRatio: Double = 1.4,
        maximumCandidates: Int = 3_000,
        minimumComponentPixels: Int = 3,
        mean: [Float] = [0.406, 0.456, 0.485],
        standardDeviation: [Float] = [0.225, 0.224, 0.229]
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(modelURL)
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRuntimeError.featureNotFound("text localization modelID")
        }
        guard mean.count == 3, standardDeviation.count == 3,
              standardDeviation.allSatisfy({ $0 != 0 }) else {
            throw ModelRuntimeError.featureTypeMismatch("PP-OCRv6 detector normalization")
        }
        self.modelURL = modelURL
        self.modelID = modelID
        self.pixelThreshold = min(max(pixelThreshold, 0), 1)
        self.boxThreshold = min(max(boxThreshold, 0), 1)
        self.unclipRatio = max(0, unclipRatio)
        self.maximumCandidates = max(1, maximumCandidates)
        self.minimumComponentPixels = max(1, minimumComponentPixels)
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    public func locateText(in image: CGImage) async throws -> [TextLocalizationResult] {
        try Task.checkCancellation()
        let loadedModel = try resolvedModel()
        guard let inputEntry = loadedModel.modelDescription.inputDescriptionsByName.first(
            where: { $0.value.type == .multiArray }
        ), let constraint = inputEntry.value.multiArrayConstraint else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 detector input")
        }
        let shape = constraint.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == 3,
              shape[2] > 0, shape[3] > 0 else {
            throw ModelRuntimeError.featureTypeMismatch(inputEntry.key)
        }

        let height = shape[2]
        let width = shape[3]
        let letterbox = try makeLetterbox(
            from: image,
            width: width,
            height: height
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputEntry.key: MLFeatureValue(multiArray: letterbox.input)
        ])
        let prediction = try predictSynchronously(
            model: loadedModel,
            provider: provider
        )
        try Task.checkCancellation()
        guard let output = prediction.featureNames.compactMap({ name in
            prediction.featureValue(for: name)?.multiArrayValue
        }).first else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 detector output")
        }
        let components = try connectedComponents(
            in: output,
            expectedWidth: width,
            expectedHeight: height
        )
        return components.compactMap {
            localizationResult(
                from: $0,
                imageWidth: image.width,
                imageHeight: image.height,
                modelWidth: width,
                modelHeight: height,
                letterbox: letterbox
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
            loadedModel = try MLModel(
                contentsOf: compiledURL,
                configuration: preferredConfiguration
            )
        } catch {
            let fallbackConfiguration = MLModelConfiguration()
            fallbackConfiguration.computeUnits = .all
            loadedModel = try MLModel(
                contentsOf: compiledURL,
                configuration: fallbackConfiguration
            )
        }
        model = loadedModel
        return loadedModel
    }

    /// 保持 Core ML 推論在 actor 內序列執行，避免 `MLModel` 跨 isolation domain。
    private func predictSynchronously(
        model: MLModel,
        provider: MLDictionaryFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func makeLetterbox(
        from source: CGImage,
        width: Int,
        height: Int
    ) throws -> Letterbox {
        guard source.width > 0, source.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let scale = min(
            Double(width) / Double(source.width),
            Double(height) / Double(source.height)
        )
        let scaledWidth = max(1, min(width, Int((Double(source.width) * scale).rounded())))
        let scaledHeight = max(1, min(height, Int((Double(source.height) * scale).rounded())))
        let horizontalPadding = (width - scaledWidth) / 2
        let verticalPadding = (height - scaledHeight) / 2

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: scaledWidth,
                height: scaledHeight
            )
        )
        guard let data = context.data else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        let input = try MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        )
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = input.strides.map(\.intValue)
        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = y * context.bytesPerRow + x * 4
                // Core Graphics 是 RGBA；PP-OCR detector 的正規化參數是 BGR 順序。
                let channels = [
                    Float(bytes[pixelOffset + 2]) / 255,
                    Float(bytes[pixelOffset + 1]) / 255,
                    Float(bytes[pixelOffset]) / 255
                ]
                for channel in 0..<3 {
                    let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                    values[offset] = (channels[channel] - mean[channel])
                        / standardDeviation[channel]
                }
            }
        }
        return Letterbox(
            input: input,
            scaledWidth: scaledWidth,
            scaledHeight: scaledHeight,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    private func connectedComponents(
        in output: MLMultiArray,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> [Component] {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == 1,
              shape[2] == expectedHeight, shape[3] == expectedWidth,
              output.dataType == .float32 else {
            throw ModelRuntimeError.featureTypeMismatch("PP-OCRv6 detector probability map")
        }
        let strides = output.strides.map(\.intValue)
        let source = output.dataPointer.assumingMemoryBound(to: Float.self)
        let pixelCount = expectedWidth * expectedHeight
        var probabilities = Array(repeating: Float.zero, count: pixelCount)
        var active = Array(repeating: UInt8.zero, count: pixelCount)
        for y in 0..<expectedHeight {
            for x in 0..<expectedWidth {
                let flatIndex = y * expectedWidth + x
                let sourceIndex = y * strides[2] + x * strides[3]
                let probability = source[sourceIndex]
                probabilities[flatIndex] = probability
                active[flatIndex] = probability >= pixelThreshold ? 1 : 0
            }
        }

        var components: [Component] = []
        var queue: [Int] = []
        queue.reserveCapacity(1_024)
        for start in 0..<pixelCount where active[start] == 1 {
            if start % expectedWidth == 0 {
                try Task.checkCancellation()
            }
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            active[start] = 0
            var cursor = 0
            var minimumX = start % expectedWidth
            var maximumX = minimumX
            var minimumY = start / expectedWidth
            var maximumY = minimumY
            var confidenceSum = 0.0

            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                let x = current % expectedWidth
                let y = current / expectedWidth
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
                confidenceSum += Double(probabilities[current])

                if x > 0 { enqueue(current - 1, active: &active, queue: &queue) }
                if x + 1 < expectedWidth { enqueue(current + 1, active: &active, queue: &queue) }
                if y > 0 { enqueue(current - expectedWidth, active: &active, queue: &queue) }
                if y + 1 < expectedHeight {
                    enqueue(current + expectedWidth, active: &active, queue: &queue)
                }
            }

            let confidence = confidenceSum / Double(queue.count)
            guard queue.count >= minimumComponentPixels,
                  confidence >= boxThreshold else {
                continue
            }
            components.append(Component(
                confidence: confidence,
                minimumX: minimumX,
                minimumY: minimumY,
                maximumX: maximumX,
                maximumY: maximumY,
                pixelCount: queue.count
            ))
        }

        let strongest = components
            .sorted { $0.confidence > $1.confidence }
            .prefix(maximumCandidates)
        return strongest.sorted {
            if $0.minimumY == $1.minimumY { return $0.minimumX > $1.minimumX }
            return $0.minimumY < $1.minimumY
        }
    }

    private func enqueue(
        _ index: Int,
        active: inout [UInt8],
        queue: inout [Int]
    ) {
        guard active[index] == 1 else { return }
        active[index] = 0
        queue.append(index)
    }

    private func localizationResult(
        from component: Component,
        imageWidth: Int,
        imageHeight: Int,
        modelWidth: Int,
        modelHeight: Int,
        letterbox: Letterbox
    ) -> TextLocalizationResult? {
        let componentWidth = Double(component.maximumX - component.minimumX + 1)
        let componentHeight = Double(component.maximumY - component.minimumY + 1)
        let perimeter = max(1, 2 * (componentWidth + componentHeight))
        let expansion = componentWidth * componentHeight * unclipRatio / perimeter
        let modelLeft = max(0, Double(component.minimumX) - expansion)
        let modelTop = max(0, Double(component.minimumY) - expansion)
        let modelRight = min(Double(modelWidth), Double(component.maximumX + 1) + expansion)
        let modelBottom = min(Double(modelHeight), Double(component.maximumY + 1) + expansion)

        let left = (modelLeft - Double(letterbox.horizontalPadding))
            / Double(letterbox.scaledWidth)
        let top = (modelTop - Double(letterbox.verticalPadding))
            / Double(letterbox.scaledHeight)
        let right = (modelRight - Double(letterbox.horizontalPadding))
            / Double(letterbox.scaledWidth)
        let bottom = (modelBottom - Double(letterbox.verticalPadding))
            / Double(letterbox.scaledHeight)
        let bounds = NormalizedRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        ).clamped()
        guard bounds.width > 0, bounds.height > 0,
              imageWidth > 0, imageHeight > 0 else {
            return nil
        }
        let polygon = [
            NormalizedPoint(x: bounds.minX, y: bounds.minY),
            NormalizedPoint(x: bounds.maxX, y: bounds.minY),
            NormalizedPoint(x: bounds.maxX, y: bounds.maxY),
            NormalizedPoint(x: bounds.minX, y: bounds.maxY)
        ]
        return TextLocalizationResult(
            confidence: component.confidence,
            polygon: polygon,
            bounds: bounds
        )
    }
}

/// 將 PP-OCRv6 的文字行候選轉成步驟二可精修的專案區域。
///
/// 先找出對話框，再逐一裁切執行文字定位。同一氣泡內的多個直排欄／橫排行會
/// 合併成一個區域；對話框外的文字（包含現階段不處理的狀聲字）不會建立遮罩區域。
/// 這個 adapter 不做 OCR 或翻譯。
public actor PPOCRTextRegionDetector: SemanticRegionDetecting {
    private let locator: any LocalTextLocating
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime

    public init(
        locator: any LocalTextLocating,
        bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime
    ) {
        self.locator = locator
        self.bubbleSegmenter = bubbleSegmenter
    }

    public func detectRegions(
        pageURL: URL,
        sourceLanguageCodes _: [String],
        fineScanEnabled _: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        progress(0.03)
        let source = try CGImageIO.load(from: pageURL)
        let bubbles = try bubbleSegmenter.detectBubbles(in: source)
        try Task.checkCancellation()
        progress(0.18)
        guard !bubbles.isEmpty else {
            progress(1)
            return []
        }

        var regions: [DialogueRegion] = []
        regions.reserveCapacity(bubbles.count)
        for (index, bubble) in bubbles.enumerated() {
            try Task.checkCancellation()
            do {
                let crop = try crop(source: source, bounds: bubble.bounds)
                let localLines = try await locator.locateText(in: crop.image)
                let pageLines = localLines
                    .map { mapToPage($0, cropBounds: crop.bounds) }
                    .filter { isInsideBubble($0.bounds, bubble: bubble) }
                let groups = Self.groupedTextLines(pageLines)
                let groupedCandidates = groups.compactMap { lines
                    -> (bounds: NormalizedRect, confidence: Double)? in
                    guard let first = lines.first else { return nil }
                    let bounds = lines.dropFirst().reduce(first.bounds) {
                        $0.union(with: $1.bounds)
                    }
                    let confidence = lines.map(\.confidence).reduce(0, +)
                        / Double(lines.count)
                    return (bounds, confidence)
                }
                let primaryLayoutGroupIndex: Int? = bubble.layoutBounds.flatMap {
                    layoutBounds -> Int? in
                    let best = groupedCandidates.indices.max { lhs, rhs in
                        Self.intersectionArea(groupedCandidates[lhs].bounds, layoutBounds)
                            < Self.intersectionArea(groupedCandidates[rhs].bounds, layoutBounds)
                    }
                    guard let best,
                          Self.intersectionArea(
                              groupedCandidates[best].bounds,
                              layoutBounds
                          ) > 0 else { return nil }
                    return best
                }
                for (groupIndex, candidate) in groupedCandidates.enumerated() {
                    let layoutBounds: NormalizedRect?
                    if groupedCandidates.count == 1 || groupIndex == primaryLayoutGroupIndex {
                        layoutBounds = bubble.layoutBounds
                    } else {
                        // 氣泡模型偶爾會把兩顆相接的對話框輸出成一個葫蘆形遮罩。
                        // 次要文字群不可沿用最大內接矩形，否則兩段譯文會疊在同一顆
                        // 氣泡；以該群文字框安全擴張後限制在既有氣泡候選內。
                        let localLayout = candidate.bounds
                            .expanded(by: 0.4)
                            .intersection(with: bubble.bounds)
                        layoutBounds = localLayout.width > 0 && localLayout.height > 0
                            ? localLayout
                            : candidate.bounds
                    }
                    regions.append(DialogueRegion(
                        bounds: candidate.bounds,
                        bubbleBounds: bubble.bounds,
                        bubbleMaskPolygons: bubble.maskPolygons,
                        bubbleLayoutBounds: layoutBounds,
                        sourceText: "",
                        confidence: candidate.confidence,
                        automaticMaskEnabled: false
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單一對話框裁切或定位失敗時略過該框，其他對話框仍可繼續。
            }
            progress(0.18 + Double(index + 1) / Double(bubbles.count) * 0.82)
        }
        progress(1)
        return regions
    }

    /// PP-OCR Det 回傳的是文字行；同一氣泡裡的多欄直排或多列橫排需要合成一個
    /// 對話區域，但相接氣泡的兩段文字不能被無條件 union。依主要文字方向、
    /// 平行軸重疊率與相鄰間距分群，讓步驟三能逐區 OCR，不會只留下其中一段。
    static func groupedTextLines(
        _ lines: [TextLocalizationResult]
    ) -> [[TextLocalizationResult]] {
        var groups: [[TextLocalizationResult]] = []
        for line in lines {
            let matching = groups.indices.filter { groupIndex in
                groups[groupIndex].contains {
                    Self.belongsToSameTextBlock($0.bounds, line.bounds)
                }
            }
            guard let destination = matching.first else {
                groups.append([line])
                continue
            }
            groups[destination].append(line)
            for groupIndex in matching.dropFirst().reversed() {
                groups[destination].append(contentsOf: groups[groupIndex])
                groups.remove(at: groupIndex)
            }
        }
        return groups
    }

    private enum TextFlow {
        case vertical
        case horizontal
        case ambiguous
    }

    private static func textFlow(_ bounds: NormalizedRect) -> TextFlow {
        if bounds.height >= bounds.width * 1.35 { return .vertical }
        if bounds.width >= bounds.height * 1.35 { return .horizontal }
        return .ambiguous
    }

    private static func belongsToSameTextBlock(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Bool {
        let lhsFlow = textFlow(lhs)
        let rhsFlow = textFlow(rhs)
        if lhsFlow == .vertical, rhsFlow == .vertical {
            let parallelOverlap = overlapRatio(
                lhs.minY, lhs.maxY,
                rhs.minY, rhs.maxY
            )
            let columnGap = intervalGap(lhs.minX, lhs.maxX, rhs.minX, rhs.maxX)
            let neighboringColumns = parallelOverlap >= 0.52
                && columnGap <= max(lhs.width, rhs.width) * 1.75
            let sameColumn = overlapRatio(
                lhs.minX, lhs.maxX,
                rhs.minX, rhs.maxX
            ) >= 0.45
                && intervalGap(lhs.minY, lhs.maxY, rhs.minY, rhs.maxY)
                    <= max(lhs.width, rhs.width) * 1.8
            return neighboringColumns || sameColumn
        }
        if lhsFlow == .horizontal, rhsFlow == .horizontal {
            let parallelOverlap = overlapRatio(
                lhs.minX, lhs.maxX,
                rhs.minX, rhs.maxX
            )
            let rowGap = intervalGap(lhs.minY, lhs.maxY, rhs.minY, rhs.maxY)
            let neighboringRows = parallelOverlap >= 0.52
                && rowGap <= max(lhs.height, rhs.height) * 1.75
            let sameRow = overlapRatio(
                lhs.minY, lhs.maxY,
                rhs.minY, rhs.maxY
            ) >= 0.45
                && intervalGap(lhs.minX, lhs.maxX, rhs.minX, rhs.maxX)
                    <= max(lhs.height, rhs.height) * 1.8
            return neighboringRows || sameRow
        }

        // 方形標點或單字可能被 Det 拆成獨立元件；只有與另一框在其中一軸
        // 明顯重疊且距離不超過一個短邊時才合併，避免跨氣泡吸附。
        let horizontalOverlap = overlapRatio(
            lhs.minX, lhs.maxX,
            rhs.minX, rhs.maxX
        )
        let verticalOverlap = overlapRatio(
            lhs.minY, lhs.maxY,
            rhs.minY, rhs.maxY
        )
        let scale = max(
            min(lhs.width, lhs.height),
            min(rhs.width, rhs.height)
        )
        return (horizontalOverlap >= 0.5
                && intervalGap(lhs.minY, lhs.maxY, rhs.minY, rhs.maxY) <= scale)
            || (verticalOverlap >= 0.5
                && intervalGap(lhs.minX, lhs.maxX, rhs.minX, rhs.maxX) <= scale)
    }

    private static func overlapRatio(
        _ lhsMinimum: Double,
        _ lhsMaximum: Double,
        _ rhsMinimum: Double,
        _ rhsMaximum: Double
    ) -> Double {
        let overlap = max(0, min(lhsMaximum, rhsMaximum) - max(lhsMinimum, rhsMinimum))
        let shorter = min(lhsMaximum - lhsMinimum, rhsMaximum - rhsMinimum)
        return shorter > 0 ? overlap / shorter : 0
    }

    private static func intervalGap(
        _ lhsMinimum: Double,
        _ lhsMaximum: Double,
        _ rhsMinimum: Double,
        _ rhsMaximum: Double
    ) -> Double {
        max(0, max(lhsMinimum, rhsMinimum) - min(lhsMaximum, rhsMaximum))
    }

    private static func intersectionArea(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Double {
        let intersection = lhs.intersection(with: rhs)
        return intersection.width * intersection.height
    }

    private func crop(
        source: CGImage,
        bounds: NormalizedRect
    ) throws -> (image: CGImage, bounds: NormalizedRect) {
        let sourceWidth = Double(source.width)
        let sourceHeight = Double(source.height)
        let rectangle = CGRect(
            x: floor(bounds.minX * sourceWidth),
            y: floor(bounds.minY * sourceHeight),
            width: ceil(bounds.maxX * sourceWidth) - floor(bounds.minX * sourceWidth),
            height: ceil(bounds.maxY * sourceHeight) - floor(bounds.minY * sourceHeight)
        ).intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard rectangle.width >= 1, rectangle.height >= 1,
              let image = source.cropping(to: rectangle) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return (
            image,
            NormalizedRect(
                x: rectangle.minX / sourceWidth,
                y: rectangle.minY / sourceHeight,
                width: rectangle.width / sourceWidth,
                height: rectangle.height / sourceHeight
            ).clamped()
        )
    }

    private func mapToPage(
        _ line: TextLocalizationResult,
        cropBounds: NormalizedRect
    ) -> TextLocalizationResult {
        let mappedBounds = NormalizedRect(
            x: cropBounds.minX + line.bounds.minX * cropBounds.width,
            y: cropBounds.minY + line.bounds.minY * cropBounds.height,
            width: line.bounds.width * cropBounds.width,
            height: line.bounds.height * cropBounds.height
        ).clamped()
        let mappedPolygon = line.polygon.map {
            NormalizedPoint(
                x: cropBounds.minX + $0.x * cropBounds.width,
                y: cropBounds.minY + $0.y * cropBounds.height
            ).clamped()
        }
        return TextLocalizationResult(
            confidence: line.confidence,
            polygon: mappedPolygon,
            bounds: mappedBounds
        )
    }

    private func isInsideBubble(
        _ textBounds: NormalizedRect,
        bubble: BubbleDetection
    ) -> Bool {
        guard !bubble.maskPolygons.isEmpty else { return true }
        let center = NormalizedPoint(x: textBounds.centerX, y: textBounds.centerY)
        return bubble.maskPolygons.contains { polygon in
            guard let first = polygon.first else { return false }
            let rectangle = polygon.dropFirst().reduce(
                NormalizedRect(x: first.x, y: first.y, width: 0, height: 0)
            ) { bounds, point in
                bounds.union(with: NormalizedRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            return center.x >= rectangle.minX && center.x <= rectangle.maxX
                && center.y >= rectangle.minY && center.y <= rectangle.maxY
        }
    }
}
