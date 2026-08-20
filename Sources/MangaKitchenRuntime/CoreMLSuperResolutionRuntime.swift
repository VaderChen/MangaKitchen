import CoreGraphics
import CoreImage
import CoreML
import Foundation
import MangaKitchenCore

actor CoreMLSuperResolutionRuntime: ImageSuperResolving {
    let manifest: ModelManifest
    let info: LoadedModelInfo

    private let model: MLModel
    private let metal: MetalContext
    private let scaleFactor: Int
    private let tileSize = 512
    private let overlap = 32

    init(directoryURL: URL, manifest: ModelManifest, metal: MetalContext) throws {
        guard manifest.backend == .coreML else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .superResolution else {
            throw ModelRuntimeError.invalidCapability(
                expected: .superResolution,
                actual: manifest.capability
            )
        }
        guard let modelFile = manifest.modelFile,
              let inputs = manifest.inputs,
              let outputs = manifest.outputs,
              outputs.image != nil else {
            throw ModelRuntimeError.featureNotFound(
                "超解析 Core ML manifest 的 modelFile／inputs／outputs.image"
            )
        }
        let sourceURL = directoryURL.appendingPathComponent(modelFile)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(sourceURL)
        }

        let compiledURL: URL
        if sourceURL.pathExtension.lowercased() == "mlmodelc" {
            compiledURL = sourceURL
        } else {
            compiledURL = try MLModel.compileModel(at: sourceURL)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.preferredMetalDevice = metal.device

        let loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        guard loadedModel.modelDescription.inputDescriptionsByName[inputs.image]?.type == .image,
              let outputName = outputs.image,
              loadedModel.modelDescription.outputDescriptionsByName[outputName]?.type == .image,
              let inputConstraint = loadedModel.modelDescription
                .inputDescriptionsByName[inputs.image]?.imageConstraint,
              let outputConstraint = loadedModel.modelDescription
                .outputDescriptionsByName[outputName]?.imageConstraint,
              inputConstraint.pixelsWide > 0,
              inputConstraint.pixelsHigh > 0,
              outputConstraint.pixelsWide.isMultiple(of: inputConstraint.pixelsWide),
              outputConstraint.pixelsHigh.isMultiple(of: inputConstraint.pixelsHigh) else {
            throw ModelRuntimeError.featureTypeMismatch("超解析模型 image input/output")
        }
        let horizontalScale = outputConstraint.pixelsWide / inputConstraint.pixelsWide
        let verticalScale = outputConstraint.pixelsHigh / inputConstraint.pixelsHigh
        guard horizontalScale == verticalScale, horizontalScale > 1 else {
            throw ModelRuntimeError.featureTypeMismatch("超解析模型輸出必須是等比例放大影像")
        }
        let requestedScale = manifest.superResolutionScale ?? horizontalScale
        guard requestedScale > 1, requestedScale <= horizontalScale else {
            throw ModelRuntimeError.featureTypeMismatch(
                "超解析 manifest 的 superResolutionScale 必須介於 2 與模型原生倍率之間"
            )
        }

        self.manifest = manifest
        self.metal = metal
        self.model = loadedModel
        self.scaleFactor = requestedScale
        self.info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
    }

    func superResolve(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard let inputs = manifest.inputs,
              let outputName = manifest.outputs?.image else {
            throw ModelRuntimeError.featureNotFound("超解析模型 inputs.image／outputs.image")
        }
        let source = try CGImageIO.load(from: inputURL)
        guard source.width > 0, source.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let inputDescription = model.modelDescription.inputDescriptionsByName[inputs.image]
        guard let constraint = inputDescription?.imageConstraint else {
            throw ModelRuntimeError.featureTypeMismatch(inputs.image)
        }
        guard constraint.pixelsWide == tileSize, constraint.pixelsHigh == tileSize else {
            throw ModelRuntimeError.featureTypeMismatch(
                "超解析模型必須使用 (tileSize)×(tileSize) 輸入"
            )
        }

        let xOrigins = tileOrigins(for: source.width)
        let yOrigins = tileOrigins(for: source.height)
        let totalTiles = max(1, xOrigins.count * yOrigins.count)
        var completedTiles = 0
        let targetWidth = source.width * scaleFactor
        let targetHeight = source.height * scaleFactor
        guard let outputContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        outputContext.setFillColor(CGColor(gray: 1, alpha: 1))
        outputContext.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        outputContext.interpolationQuality = .high

        for yOrigin in yOrigins {
            for xOrigin in xOrigins {
                try Task.checkCancellation()
                let sourceRect = tileRect(
                    xOrigin: xOrigin,
                    yOrigin: yOrigin,
                    sourceWidth: source.width,
                    sourceHeight: source.height
                )
                let tileImage = try makeTile(from: source, sourceRect: sourceRect)
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    inputs.image: MLFeatureValue(
                        cgImage: tileImage,
                        constraint: constraint,
                        options: [:]
                    )
                ])
                let prediction = try predictSynchronously(from: provider)
                guard let value = prediction.featureValue(for: outputName),
                      value.type == .image,
                      let pixelBuffer = value.imageBufferValue else {
                    throw ModelRuntimeError.featureTypeMismatch(outputName)
                }
                let outputImage = CIImage(cvPixelBuffer: pixelBuffer)
                guard let outputCGImage = metal.coreImageContext.createCGImage(
                    outputImage,
                    from: outputImage.extent
                ) else {
                    throw ImageProcessingError.cannotCreateBitmap
                }
                draw(
                    outputCGImage,
                    in: sourceRect,
                    on: outputContext
                )
                completedTiles += 1
                progress(Double(completedTiles) / Double(totalTiles))
            }
        }

        guard let result = outputContext.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(result, to: outputURL)
        progress(1)
    }

    private func tileOrigins(for dimension: Int) -> [Int] {
        let stride = max(1, tileSize - overlap)
        var origins = [0]
        var origin = stride
        while origin < dimension {
            let adjustedOrigin = min(origin, max(0, dimension - tileSize))
            if origins.last != adjustedOrigin {
                origins.append(adjustedOrigin)
            }
            origin += stride
        }
        return origins
    }

    private func tileRect(
        xOrigin: Int,
        yOrigin: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let x = min(max(0, xOrigin), max(0, sourceWidth - tileSize))
        let y = min(max(0, yOrigin), max(0, sourceHeight - tileSize))
        return CGRect(
            x: x,
            y: y,
            width: min(tileSize, sourceWidth - x),
            height: min(tileSize, sourceHeight - y)
        )
    }

    private func makeTile(from source: CGImage, sourceRect: CGRect) throws -> CGImage {
        guard let cropped = source.cropping(to: sourceRect),
              let context = CGContext(
                  data: nil,
                  width: tileSize,
                  height: tileSize,
                  bitsPerComponent: 8,
                  bytesPerRow: tileSize * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(tileSize))
        context.scaleBy(x: 1, y: -1)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
        context.restoreGState()
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
    }

    private func draw(_ image: CGImage, in sourceRect: CGRect, on context: CGContext) {
        let destination = CGRect(
            x: sourceRect.minX * CGFloat(scaleFactor),
            y: sourceRect.minY * CGFloat(scaleFactor),
            width: sourceRect.width * CGFloat(scaleFactor),
            height: sourceRect.height * CGFloat(scaleFactor)
        )
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: destination)
        context.restoreGState()
    }

    private func predictSynchronously(
        from provider: MLDictionaryFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }
}
