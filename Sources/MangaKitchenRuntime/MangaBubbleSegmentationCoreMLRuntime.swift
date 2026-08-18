import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

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
    }

    private let modelURL: URL
    private let confidenceThreshold: Double
    private let intersectionOverUnionThreshold: Double
    private let maximumCandidates: Int
    private let lock = NSLock()
    private var model: MLModel?

    public init(
        modelURL: URL,
        confidenceThreshold: Double = 0.25,
        intersectionOverUnionThreshold: Double = 0.5,
        maximumCandidates: Int = 36
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(modelURL)
        }
        self.modelURL = modelURL
        self.confidenceThreshold = min(max(confidenceThreshold, 0), 1)
        self.intersectionOverUnionThreshold = min(max(intersectionOverUnionThreshold, 0), 1)
        self.maximumCandidates = max(1, maximumCandidates)
    }

    public func detect(in source: CGImage) throws -> [NormalizedRect] {
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
        return nonMaximumSuppressedCandidates(
            from: rawPredictions,
            sourceWidth: source.width,
            sourceHeight: source.height,
            letterboxed: letterboxed
        ).map(\.bounds)
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
            candidates.append(Candidate(bounds: normalized, confidence: confidence))
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
