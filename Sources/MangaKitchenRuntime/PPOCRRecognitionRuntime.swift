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
        modelID: String = "ppocrv6-small-rec",
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

/// 先由 VLM 決定文字區域，再以指定 OCR 模型保存獨立候選。
///
/// 這個 decorator 特意不覆寫 `sourceText`：目前只保存每個 OCR 模型的結果，
/// 複合 OCR 與二次校稿融合留給後續功能。
public actor OCRRegionTextRecognitionService: RegionTextRecognizing {
    private let locator: any RegionTextRecognizing
    private let ocr: any LocalOCRRecognizing

    public init(
        locator: any RegionTextRecognizing,
        ocr: any LocalOCRRecognizing
    ) {
        self.locator = locator
        self.ocr = ocr
    }

    public func recognizeRegions(
        pageURL: URL,
        regions: [DialogueRegion],
        sourceLanguageCodes: [String],
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }
        let located = try await locator.recognizeRegions(
            pageURL: pageURL,
            regions: regions,
            sourceLanguageCodes: sourceLanguageCodes,
            regionProgress: regionProgress,
            progress: { value in progress(min(max(value, 0), 1) * 0.6) }
        )
        try Task.checkCancellation()

        let source = try CGImageIO.load(from: pageURL)
        var updated = located
        let candidates = located.indices.filter {
            !located[$0].sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else {
            progress(1)
            return updated
        }

        for (offset, index) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let region = located[index]
                let crop = try Self.crop(source: source, bounds: region.bounds)
                var candidate = try await ocr.recognize(crop: crop, bounds: region.bounds)
                if candidate.writingDirection == .automatic {
                    candidate.writingDirection = region.detectedWritingDirection
                }
                // 只更新該模型的槽位；原文、座標、遮罩與既有 VLM 結果保持不變。
                updated[index].ocrResults[ocr.modelID] = candidate
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單一區域 OCR 失敗時保留 VLM 結果，其他區域仍可完成翻譯。
            }
            progress(0.6 + Double(offset + 1) / Double(candidates.count) * 0.4)
        }
        return updated
    }

    private static func crop(source: CGImage, bounds: NormalizedRect) throws -> CGImage {
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
        return crop
    }
}
