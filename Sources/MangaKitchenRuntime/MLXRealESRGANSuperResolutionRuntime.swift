import CoreGraphics
import Foundation
import MLX
import MLXNN
import MangaKitchenCore

actor MLXRealESRGANSuperResolutionRuntime: ImageSuperResolving {
    let manifest: ModelManifest
    let info: LoadedModelInfo

    private let weights: [String: MLXArray]
    private let tileSize = 256
    private let overlap = 16
    private let scaleFactor = 2

    init(directoryURL: URL, manifest: ModelManifest) throws {
        guard manifest.backend == .mlxSwift else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .superResolution else {
            throw ModelRuntimeError.invalidCapability(
                expected: .superResolution,
                actual: manifest.capability
            )
        }
        guard manifest.superResolutionScale == 2,
              let modelFile = manifest.modelFile else {
            throw ModelRuntimeError.featureNotFound(
                "MLX Real-ESRGAN manifest 的 modelFile／superResolutionScale=2"
            )
        }
        let modelURL = directoryURL.appendingPathComponent(modelFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(modelURL)
        }
        let loadedWeights = try loadArrays(url: modelURL)
        let requiredKeys = [
            "conv_first.weight", "conv_first.bias",
            "conv_body.weight", "conv_body.bias",
            "conv_up1.weight", "conv_up1.bias",
            "conv_up2.weight", "conv_up2.bias",
            "conv_hr.weight", "conv_hr.bias",
            "conv_last.weight", "conv_last.bias"
        ]
        guard requiredKeys.allSatisfy({ loadedWeights[$0] != nil }) else {
            throw ModelRuntimeError.featureNotFound("MLX Real-ESRGAN RRDBNet 權重")
        }
        self.manifest = manifest
        self.weights = loadedWeights
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
        let source = try CGImageIO.load(from: inputURL)
        guard source.width > 0, source.height > 0 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let outputWidth = source.width * scaleFactor
        let outputHeight = source.height * scaleFactor
        guard let outputContext = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        outputContext.setFillColor(CGColor(gray: 1, alpha: 1))
        outputContext.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        outputContext.interpolationQuality = .high

        let xOrigins = tileOrigins(for: source.width)
        let yOrigins = tileOrigins(for: source.height)
        let totalTiles = max(1, xOrigins.count * yOrigins.count)
        var completedTiles = 0
        for yOrigin in yOrigins {
            for xOrigin in xOrigins {
                try Task.checkCancellation()
                let sourceRect = tileRect(
                    xOrigin: xOrigin,
                    yOrigin: yOrigin,
                    sourceWidth: source.width,
                    sourceHeight: source.height
                )
                let input = try makeModelInput(from: source, sourceRect: sourceRect)
                let output = try predict(input)
                output.eval()
                let outputImage = try makeImage(from: output)
                draw(outputImage, in: sourceRect, on: outputContext)
                completedTiles += 1
                progress(Double(completedTiles) / Double(totalTiles))
                Memory.clearCache()
            }
        }

        guard let result = outputContext.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try CGImageIO.writePNG(result, to: outputURL)
        progress(1)
    }

    private func predict(_ input: MLXArray) throws -> MLXArray {
        var features = try convolution(input, name: "conv_first")
        var body = features
        for blockIndex in 0..<23 {
            body = try residualInResidualDenseBlock(body, blockIndex: blockIndex)
        }
        body = try convolution(body, name: "conv_body")
        features = features + body
        let upsample = Upsample(scaleFactor: 2.0, mode: .nearest)
        features = leakyReLU(try convolution(upsample(features), name: "conv_up1"))
        features = leakyReLU(try convolution(upsample(features), name: "conv_up2"))
        features = leakyReLU(try convolution(features, name: "conv_hr"))
        return clip(try convolution(features, name: "conv_last"), min: 0, max: 1)
            .asType(.float32)
    }

    private func residualInResidualDenseBlock(
        _ input: MLXArray,
        blockIndex: Int
    ) throws -> MLXArray {
        var value = input
        for denseIndex in 1...3 {
            value = try residualDenseBlock(
                value,
                prefix: "body.\(blockIndex).rdb\(denseIndex)"
            )
        }
        return input + value * 0.2
    }

    private func residualDenseBlock(_ input: MLXArray, prefix: String) throws -> MLXArray {
        let first = leakyReLU(try convolution(input, name: "\(prefix).conv1"))
        let secondInput = concatenated([input, first], axis: -1)
        let second = leakyReLU(try convolution(secondInput, name: "\(prefix).conv2"))
        let thirdInput = concatenated([input, first, second], axis: -1)
        let third = leakyReLU(try convolution(thirdInput, name: "\(prefix).conv3"))
        let fourthInput = concatenated([input, first, second, third], axis: -1)
        let fourth = leakyReLU(try convolution(fourthInput, name: "\(prefix).conv4"))
        let fifthInput = concatenated([input, first, second, third, fourth], axis: -1)
        let fifth = try convolution(fifthInput, name: "\(prefix).conv5")
        return input + fifth * 0.2
    }

    private func convolution(_ input: MLXArray, name: String) throws -> MLXArray {
        guard let weight = weights["\(name).weight"],
              let bias = weights["\(name).bias"] else {
            throw ModelRuntimeError.featureNotFound(name)
        }
        return conv2d(input, weight, padding: 1) + bias
    }

    private func leakyReLU(_ input: MLXArray) -> MLXArray {
        maximum(input, input * 0.2)
    }

    private func makeModelInput(from source: CGImage, sourceRect: CGRect) throws -> MLXArray {
        guard let cropped = source.cropping(to: sourceRect) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        var pixels = [UInt8](repeating: 255, count: tileSize * tileSize * 4)
        guard let context = CGContext(
            data: &pixels,
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

        let reducedSize = tileSize / 2
        var values = [Float](repeating: 0, count: reducedSize * reducedSize * 12)
        for y in 0..<reducedSize {
            for x in 0..<reducedSize {
                for channel in 0..<3 {
                    for offsetY in 0..<2 {
                        for offsetX in 0..<2 {
                            let sourceOffset = ((y * 2 + offsetY) * tileSize + x * 2 + offsetX) * 4
                                + channel
                            let targetChannel = channel * 4 + offsetY * 2 + offsetX
                            let targetOffset = (y * reducedSize + x) * 12 + targetChannel
                            values[targetOffset] = Float(pixels[sourceOffset]) / 255
                        }
                    }
                }
            }
        }
        return MLXArray(values, [1, reducedSize, reducedSize, 12]).asType(.float16)
    }

    private func makeImage(from output: MLXArray) throws -> CGImage {
        let (_, height, width, channels) = output.shape4
        guard channels == 3 else {
            throw ModelRuntimeError.featureTypeMismatch("MLX Real-ESRGAN output")
        }
        let values = output.asArray(Float.self)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8(clamping: Int((values[index * 3] * 255).rounded()))
            pixels[index * 4 + 1] = UInt8(clamping: Int((values[index * 3 + 1] * 255).rounded()))
            pixels[index * 4 + 2] = UInt8(clamping: Int((values[index * 3 + 2] * 255).rounded()))
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
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
}
