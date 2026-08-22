import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

/// 原生 Core ML PP-OCRv6 recognizer。
///
/// 模型轉換仍在開發環境離線完成；App 執行時只載入 `.mlpackage`／`.mlmodelc`，
/// 不需要 Python。這個 runtime 不做整頁偵測，也不會改動 MangaKitchen 的區域或遮罩。
public actor PPOCRRecognitionRuntime: LocalOCRRecognizing {
    public let modelID: String

    private let modelURL: URL
    private let characters: [String]
    private let mean: [Float]
    private let standardDeviation: [Float]
    private var model: MLModel?

    public init(
        modelURL: URL,
        modelID: String = "ppocrv6-medium-rec",
        characters: [String],
        mean: [Float] = [0.5, 0.5, 0.5],
        standardDeviation: [Float] = [0.5, 0.5, 0.5]
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(modelURL)
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRuntimeError.featureNotFound("OCR modelID")
        }
        guard !characters.isEmpty else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 character list")
        }
        guard mean.count == 3, standardDeviation.count == 3,
              standardDeviation.allSatisfy({ $0 != 0 }) else {
            throw ModelRuntimeError.featureTypeMismatch("PP-OCRv6 normalization")
        }
        self.modelURL = modelURL
        self.modelID = modelID
        self.characters = characters
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    public func recognize(
        crop: CGImage,
        bounds: NormalizedRect
    ) async throws -> OCRModelResult {
        try Task.checkCancellation()
        let loadedModel = try resolvedModel()
        guard let inputEntry = loadedModel.modelDescription.inputDescriptionsByName.first(
            where: { $0.value.type == .multiArray }
        ), let inputConstraint = inputEntry.value.multiArrayConstraint else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 recognizer input")
        }
        let inputName = inputEntry.key
        guard
              inputConstraint.shape.count == 4,
              inputConstraint.shape[0].intValue == 1,
              inputConstraint.shape[1].intValue == 3 else {
            throw ModelRuntimeError.featureTypeMismatch(inputName)
        }

        let height = inputConstraint.shape[2].intValue
        let width = inputConstraint.shape[3].intValue
        guard height > 0, width > 0 else {
            throw ModelRuntimeError.featureTypeMismatch(inputName)
        }
        let inputArray = try makeInputArray(
            from: crop,
            width: width,
            height: height
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: inputArray)
        ])
        let prediction = try predictSynchronously(
            model: loadedModel,
            provider: provider
        )
        guard let output = prediction.featureNames.compactMap({ name in
            prediction.featureValue(for: name)?.multiArrayValue
        }).first else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 recognizer output")
        }

        let decoded = decode(output)
        let line = OCRTextLineResult(
            text: decoded.text,
            confidence: decoded.confidence,
            bounds: bounds
        )
        return OCRModelResult(
            modelID: modelID,
            text: decoded.text,
            confidence: decoded.confidence,
            lines: decoded.text.isEmpty ? [] : [line]
        )
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

    /// Core ML 的同步 prediction 留在 actor 內序列化執行，避免 Swift 6 將
    /// `MLModel` 跨 actor 傳入 async API 判定為資料競爭。
    private func predictSynchronously(
        model: MLModel,
        provider: MLDictionaryFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func makeInputArray(
        from source: CGImage,
        width: Int,
        height: Int
    ) throws -> MLMultiArray {
        guard source.width > 0, source.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let preparedSource: CGImage
        if Double(source.height) / Double(source.width) >= 1.5 {
            preparedSource = try rotateCounterClockwise(source)
        } else {
            preparedSource = source
        }
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

        // PP-OCR 的 recognizer 以固定高度等比例縮放，右側不足處補零；
        // 不拉伸文字，避免直排日文筆畫被扭曲。
        let scale = min(
            Double(height) / Double(preparedSource.height),
            Double(width) / Double(preparedSource.width)
        )
        let scaledWidth = max(1, min(width, Int((Double(preparedSource.width) * scale).rounded())))
        let scaledHeight = max(1, min(height, Int((Double(preparedSource.height) * scale).rounded())))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(
            preparedSource,
            in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
        )

        guard let data = context.data else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        )
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        let values = array.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = array.strides.map(\.intValue)
        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = y * context.bytesPerRow + x * 4
                let channels = [
                    Float(pointer[pixelOffset]) / 255,
                    Float(pointer[pixelOffset + 1]) / 255,
                    Float(pointer[pixelOffset + 2]) / 255
                ]
                for channel in 0..<3 {
                    let normalized = (channels[channel] - mean[channel])
                        / standardDeviation[channel]
                    let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                    values[offset] = normalized
                }
            }
        }
        return array
    }

    private func rotateCounterClockwise(_ source: CGImage) throws -> CGImage {
        let rotatedWidth = source.height
        let rotatedHeight = source.width
        guard let context = CGContext(
            data: nil,
            width: rotatedWidth,
            height: rotatedHeight,
            bitsPerComponent: 8,
            bytesPerRow: rotatedWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.translateBy(x: CGFloat(rotatedWidth), y: 0)
        context.rotate(by: .pi / 2)
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
        )
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
    }

    private func decode(_ output: MLMultiArray) -> (text: String, confidence: Double?) {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1,
              shape[1] > 0, shape[2] > 1 else {
            return ("", nil)
        }
        let timeCount = shape[1]
        let classCount = min(shape[2], characters.count)
        guard output.dataType == .float32 else {
            return ("", nil)
        }
        let strides = output.strides.map(\.intValue)
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        var previousClass: Int?
        var pieces: [String] = []
        var confidenceSum = 0.0
        var confidenceCount = 0

        for time in 0..<timeCount {
            var scores = Array(repeating: 0.0, count: classCount)
            for value in 0..<classCount {
                let offset = time * strides[1] + value * strides[2]
                scores[value] = Double(values[offset])
            }
            let scoreSum = scores.reduce(0, +)
            let isProbabilityVector = scores.allSatisfy {
                $0 >= -0.0001 && $0 <= 1.0001
            } && abs(scoreSum - 1) < 0.02
            if !isProbabilityVector {
                let maximum = scores.max() ?? 0
                var total = 0.0
                for index in scores.indices {
                    scores[index] = exp(scores[index] - maximum)
                    total += scores[index]
                }
                if total > 0 {
                    for index in scores.indices {
                        scores[index] /= total
                    }
                }
            }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else {
                continue
            }
            let probability = min(max(scores[best], 0), 1)
            if best == 0 {
                previousClass = nil
                continue
            }
            guard best != previousClass,
                  best < characters.count,
                  characters[best] != "blank" else {
                previousClass = best
                continue
            }
            pieces.append(characters[best])
            confidenceSum += probability
            confidenceCount += 1
            previousClass = best
        }
        let text = pieces.joined()
        let confidence = confidenceCount > 0
            ? min(max(confidenceSum / Double(confidenceCount), 0), 1)
            : nil
        return (text, confidence)
    }
}

/// 讀取 PP-OCR Hugging Face `preprocessor_config.json` 內的 character_list。
/// 也接受純 JSON 陣列或每行一字的字典檔，方便將模型與字典分開發佈。
public enum PPOCRCharacterList {
    public static func load(from url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        if let characters = try? JSONDecoder().decode([String].self, from: data) {
            return characters
        }
        if let configuration = try? JSONDecoder().decode(Configuration.self, from: data) {
            return configuration.characterList
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        guard !lines.isEmpty else {
            throw ModelRuntimeError.featureNotFound("PP-OCRv6 character list")
        }
        return lines
    }

    private struct Configuration: Decodable {
        var characterList: [String]

        private enum CodingKeys: String, CodingKey {
            case characterList = "character_list"
        }
    }
}

/// 在步驟二已建立的對話遮罩區域上執行指定 OCR 模型。
///
/// 每個模型的完整結果都會保存在 `ocrResults`。只有目前 `sourceText`
/// 為空白時，才採用這個預設 OCR 候選作為翻譯原文；已有的 VLM、Agent 或人工
/// 原文不會被覆寫，座標與遮罩也絕不在此步驟修改。
public struct UnavailableOCRRegionTextRecognizer: RegionTextRecognizing {
    public init() {}

    public func recognizeRegions(
        pageURL _: URL,
        regions _: [DialogueRegion],
        sourceLanguageCodes _: [String],
        regionProgress _: @escaping PageRegionProgress,
        progress _: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        throw ModelRuntimeError.featureNotFound("bundled PP-OCR recognition runtime")
    }
}

public actor OCRRegionTextRecognitionService: RegionTextRecognizing {
    private let ocr: any LocalOCRRecognizing
    private let locator: (any LocalTextLocating)?

    public init(
        ocr: any LocalOCRRecognizing,
        locator: (any LocalTextLocating)? = nil
    ) {
        self.ocr = ocr
        self.locator = locator
    }

    public func recognizeRegions(
        pageURL: URL,
        regions: [DialogueRegion],
        sourceLanguageCodes _: [String],
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }
        let source = try CGImageIO.load(from: pageURL)
        var updated = regions
        regionProgress(0, regions.count)
        for index in regions.indices {
            try Task.checkCancellation()
            do {
                let region = regions[index]
                let candidate = try await recognize(
                    source: source,
                    region: region
                )
                // 每個模型保留獨立槽位，方便後續複合 OCR／VLM 校稿。
                updated[index].ocrResults[ocr.modelID] = candidate
                let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if updated[index].sourceText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty, !text.isEmpty {
                    updated[index].rawSourceText = text
                    updated[index].sourceText = text
                    // `ocrTextRefined` 是舊版 VLM／人工確認標記；單模型 OCR
                    // 只是預設原文來源，不得將這個標記設為 true。
                    updated[index].ocrTextRefined = false
                    if candidate.writingDirection != .automatic {
                        updated[index].detectedWritingDirection = candidate.writingDirection
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單一區域 OCR 失敗時保留現有原文，並繼續其他區域。
            }
            regionProgress(index + 1, regions.count)
            progress(Double(index + 1) / Double(regions.count))
        }
        return updated
    }

    /// PP-OCR recognizer 是單行模型。有 locator 時，只在步驟二既有
    /// `region.bounds` 內切出文字行／直排欄後逐一辨識；定位結果不會寫回
    /// `DialogueRegion`，因此不可改變步驟二的座標、遮罩或背景。
    private func recognize(
        source: CGImage,
        region: DialogueRegion
    ) async throws -> OCRModelResult {
        let regionCrop = try Self.crop(source: source, bounds: region.bounds)
        let localizedLines: [TextLocalizationResult]
        if let locator {
            localizedLines = try await locator.locateText(in: regionCrop.image)
        } else {
            localizedLines = []
        }
        let mappedLines = localizedLines.compactMap {
            Self.mapToPage(
                $0,
                cropBounds: regionCrop.pageBounds,
                clippingBounds: region.bounds
            )
        }
        let writingDirection = Self.resolvedWritingDirection(
            preferred: region.detectedWritingDirection,
            lines: mappedLines
        )
        let lineBounds = Self.orderedLineBounds(
            mappedLines.map(\.bounds),
            writingDirection: writingDirection
        )
        let recognitionBounds = lineBounds.isEmpty ? [region.bounds] : lineBounds

        var recognizedLines: [OCRTextLineResult] = []
        recognizedLines.reserveCapacity(recognitionBounds.count)
        var recognizedDirections: [WritingDirection] = []
        for bounds in recognitionBounds {
            try Task.checkCancellation()
            let rawCrop = try Self.crop(source: source, bounds: bounds).image
            let lineDirection = Self.resolvedLineDirection(
                bounds,
                fallback: writingDirection
            )
            let preparedCrop = lineDirection == .vertical
                ? try Self.rotateCounterClockwise(rawCrop)
                : rawCrop
            let result = try await ocr.recognize(
                crop: preparedCrop,
                bounds: bounds
            )
            guard !result.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else { continue }
            recognizedLines.append(OCRTextLineResult(
                text: result.text,
                confidence: result.confidence,
                bounds: bounds
            ))
            if result.writingDirection != .automatic {
                recognizedDirections.append(result.writingDirection)
            }
        }

        let resolvedDirection = writingDirection == .automatic
            ? (recognizedDirections.first ?? .automatic)
            : writingDirection
        let separator = resolvedDirection == .horizontal ? "\n" : ""
        let text = recognizedLines.map(\.text).joined(separator: separator)
        let confidences = recognizedLines.compactMap(\.confidence)
        let confidence = confidences.isEmpty
            ? nil
            : confidences.reduce(0, +) / Double(confidences.count)
        return OCRModelResult(
            modelID: ocr.modelID,
            text: text,
            confidence: confidence,
            lines: recognizedLines,
            writingDirection: resolvedDirection
        )
    }

    private static func crop(
        source: CGImage,
        bounds: NormalizedRect
    ) throws -> (image: CGImage, pageBounds: NormalizedRect) {
        let width = Double(source.width)
        let height = Double(source.height)
        let x = max(0, min(width - 1, bounds.x * width))
        let y = max(0, min(height - 1, bounds.y * height))
        let maxX = max(x + 1, min(width, (bounds.x + bounds.width) * width))
        let maxY = max(y + 1, min(height, (bounds.y + bounds.height) * height))
        let rect = CGRect(
            x: floor(x),
            y: floor(y),
            width: max(1, ceil(maxX) - floor(x)),
            height: max(1, ceil(maxY) - floor(y))
        ).intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let crop = source.cropping(to: rect), crop.width > 0, crop.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return (
            crop,
            NormalizedRect(
                x: rect.minX / width,
                y: rect.minY / height,
                width: rect.width / width,
                height: rect.height / height
            ).clamped()
        )
    }

    private static func mapToPage(
        _ line: TextLocalizationResult,
        cropBounds: NormalizedRect,
        clippingBounds: NormalizedRect
    ) -> TextLocalizationResult? {
        let mappedBounds = NormalizedRect(
            x: cropBounds.minX + line.bounds.minX * cropBounds.width,
            y: cropBounds.minY + line.bounds.minY * cropBounds.height,
            width: line.bounds.width * cropBounds.width,
            height: line.bounds.height * cropBounds.height
        ).expanded(by: 0.04).intersection(with: clippingBounds)
        guard mappedBounds.width > 0, mappedBounds.height > 0 else { return nil }
        return TextLocalizationResult(
            confidence: line.confidence,
            polygon: [
                NormalizedPoint(x: mappedBounds.minX, y: mappedBounds.minY),
                NormalizedPoint(x: mappedBounds.maxX, y: mappedBounds.minY),
                NormalizedPoint(x: mappedBounds.maxX, y: mappedBounds.maxY),
                NormalizedPoint(x: mappedBounds.minX, y: mappedBounds.maxY)
            ],
            bounds: mappedBounds
        )
    }

    private static func resolvedWritingDirection(
        preferred: WritingDirection,
        lines: [TextLocalizationResult]
    ) -> WritingDirection {
        if preferred != .automatic { return preferred }
        var vertical = 0
        var horizontal = 0
        for line in lines {
            if line.bounds.height >= line.bounds.width * 1.25 {
                vertical += 1
            } else if line.bounds.width >= line.bounds.height * 1.25 {
                horizontal += 1
            }
        }
        if vertical > horizontal { return .vertical }
        if horizontal > vertical { return .horizontal }
        return .automatic
    }

    private static func resolvedLineDirection(
        _ bounds: NormalizedRect,
        fallback: WritingDirection
    ) -> WritingDirection {
        if bounds.height >= bounds.width * 1.25 { return .vertical }
        if bounds.width >= bounds.height * 1.25 { return .horizontal }
        return fallback
    }

    private static func orderedLineBounds(
        _ bounds: [NormalizedRect],
        writingDirection: WritingDirection
    ) -> [NormalizedRect] {
        bounds.sorted { lhs, rhs in
            switch writingDirection {
            case .vertical:
                if abs(lhs.centerX - rhs.centerX) > 0.001 {
                    return lhs.centerX > rhs.centerX
                }
                return lhs.minY < rhs.minY
            case .horizontal, .automatic:
                if abs(lhs.centerY - rhs.centerY) > 0.001 {
                    return lhs.centerY < rhs.centerY
                }
                return lhs.minX < rhs.minX
            }
        }
    }

    private static func rotateCounterClockwise(_ source: CGImage) throws -> CGImage {
        let rotatedWidth = source.height
        let rotatedHeight = source.width
        guard let context = CGContext(
            data: nil,
            width: rotatedWidth,
            height: rotatedHeight,
            bitsPerComponent: 8,
            bytesPerRow: rotatedWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.translateBy(x: CGFloat(rotatedWidth), y: 0)
        context.rotate(by: .pi / 2)
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
        )
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
    }
}
