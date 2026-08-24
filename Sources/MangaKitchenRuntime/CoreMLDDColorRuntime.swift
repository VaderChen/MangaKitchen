import Accelerate
import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

actor CoreMLDDColorRuntime: ImageColorizing {
    let manifest: ModelManifest
    let info: LoadedModelInfo

    private let model: MLModel
    private let compiledModelURL: URL
    private let inputName: String
    private let outputName: String
    private let inputSize: Int
    private let compositor: MaskedImageCompositor

    init(directoryURL: URL, manifest: ModelManifest, metal: MetalContext) throws {
        guard manifest.backend == .coreML else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .imageColorization else {
            throw ModelRuntimeError.invalidCapability(
                expected: .imageColorization,
                actual: manifest.capability
            )
        }
        guard let modelFile = manifest.modelFile,
              let inputName = manifest.inputs?.image,
              let outputName = manifest.outputs?.chroma,
              let colorization = manifest.colorization,
              colorization.kind == .ddcolor,
              (32...2_048).contains(colorization.inputSize) else {
            throw ModelRuntimeError.featureNotFound(
                "DDColor manifest 的 modelFile／inputs.image／outputs.chroma／colorization"
            )
        }

        let sourceURL = directoryURL.appendingPathComponent(modelFile)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ModelRuntimeError.modelFileNotFound(sourceURL)
        }
        let compiledModelURL: URL
        if sourceURL.pathExtension.lowercased() == "mlmodelc" {
            compiledModelURL = sourceURL
        } else {
            compiledModelURL = try MLModel.compileModel(at: sourceURL)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.preferredMetalDevice = metal.device
        let model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName[inputName]?.type == .multiArray,
              model.modelDescription.outputDescriptionsByName[outputName]?.type == .multiArray else {
            throw ModelRuntimeError.featureTypeMismatch("\(inputName)／\(outputName)")
        }

        self.manifest = manifest
        self.model = model
        self.compiledModelURL = compiledModelURL
        self.inputName = inputName
        self.outputName = outputName
        self.inputSize = colorization.inputSize
        self.compositor = MaskedImageCompositor(metal: metal)
        self.info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
    }

    func colorize(
        inputURL: URL,
        maskURL: URL?,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        try Task.checkCancellation()
        progress(0.03)
        let source = try CGImageIO.load(from: inputURL)
        let originalWidth = source.width
        let originalHeight = source.height
        guard originalWidth > 0, originalHeight > 0 else {
            throw ImageProcessingError.unreadableImage(inputURL)
        }

        let originalPixels = try rgbaPixels(
            from: source,
            width: originalWidth,
            height: originalHeight
        )
        let originalLuminance = luminance(from: originalPixels)
        let resizedPixels = try rgbaPixels(from: source, width: inputSize, height: inputSize)
        let input = try makeModelInput(from: resizedPixels)
        progress(0.25)

        try Task.checkCancellation()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: input)
        ])
        let prediction = try predictSynchronously(from: provider)
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw ModelRuntimeError.featureTypeMismatch(outputName)
        }
        progress(0.7)

        let chroma = try resizedChroma(
            from: output,
            width: originalWidth,
            height: originalHeight
        )
        let generated = try makeImage(
            luminance: originalLuminance,
            chroma: chroma,
            width: originalWidth,
            height: originalHeight
        )
        try Task.checkCancellation()
        progress(0.9)

        if let maskURL {
            let candidateURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent("ddcolor-candidate-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: candidateURL) }
            try CGImageIO.writePNG(generated, to: candidateURL)
            try await compositor.composite(
                sourceURL: inputURL,
                generatedURL: candidateURL,
                maskURL: maskURL,
                outputURL: outputURL
            )
        } else {
            try CGImageIO.writePNG(generated, to: outputURL)
        }
        progress(1)
    }

    private func predictSynchronously(
        from provider: MLDictionaryFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func makeModelInput(from pixels: [UInt8]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)],
            dataType: .float32
        )
        let strides = array.strides.map(\.intValue)
        guard strides.count == 4 else {
            throw ModelRuntimeError.featureTypeMismatch(inputName)
        }
        let values = array.dataPointer.assumingMemoryBound(to: Float.self)
        let channelStride = strides[1]
        let rowStride = strides[2]
        let columnStride = strides[3]
        let pixelCount = inputSize * inputSize
        guard pixels.count == pixelCount * 4 else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        for index in 0..<pixelCount {
            let pixelOffset = index * 4
            let red = Float(pixels[pixelOffset]) / 255
            let green = Float(pixels[pixelOffset + 1]) / 255
            let blue = Float(pixels[pixelOffset + 2]) / 255
            let lightness = Self.srgbToLightness(red: red, green: green, blue: blue)
            let gray = Self.labToSrgb(lightness: lightness, a: 0, b: 0)
            let row = index / inputSize
            let column = index % inputSize
            let base = row * rowStride + column * columnStride
            values[base] = gray.red
            values[channelStride + base] = gray.green
            values[channelStride * 2 + base] = gray.blue
        }
        return array
    }

    private func resizedChroma(
        from output: MLMultiArray,
        width: Int,
        height: Int
    ) throws -> [Float] {
        guard output.dataType == .float32,
              output.shape.count == 4,
              output.shape[1].intValue == 2 else {
            throw ModelRuntimeError.featureTypeMismatch(outputName)
        }
        let sourceHeight = output.shape[2].intValue
        let sourceWidth = output.shape[3].intValue
        let strides = output.strides.map(\.intValue)
        guard sourceWidth > 0, sourceHeight > 0, strides.count == 4 else {
            throw ModelRuntimeError.featureTypeMismatch(outputName)
        }

        let sourceCount = sourceWidth * sourceHeight
        var source = [Float](repeating: 0, count: sourceCount * 2)
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        for channel in 0..<2 {
            for row in 0..<sourceHeight {
                for column in 0..<sourceWidth {
                    let sourceOffset = channel * strides[1]
                        + row * strides[2]
                        + column * strides[3]
                    source[channel * sourceCount + row * sourceWidth + column] = values[sourceOffset]
                }
            }
        }

        let destinationCount = width * height
        var destination = [Float](repeating: 0, count: destinationCount * 2)
        let scaleError = source.withUnsafeMutableBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                var error: vImage_Error = kvImageNoError
                for channel in 0..<2 where error == kvImageNoError {
                    var sourceImage = vImage_Buffer(
                        data: sourceBuffer.baseAddress!.advanced(by: channel * sourceCount),
                        height: vImagePixelCount(sourceHeight),
                        width: vImagePixelCount(sourceWidth),
                        rowBytes: sourceWidth * MemoryLayout<Float>.stride
                    )
                    var destinationImage = vImage_Buffer(
                        data: destinationBuffer.baseAddress!.advanced(by: channel * destinationCount),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width * MemoryLayout<Float>.stride
                    )
                    error = vImageScale_PlanarF(
                        &sourceImage,
                        &destinationImage,
                        nil,
                        vImage_Flags(kvImageHighQualityResampling)
                    )
                }
                return error
            }
        }
        guard scaleError == kvImageNoError else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return destination
    }

    private func luminance(from pixels: [UInt8]) -> [Float] {
        let pixelCount = pixels.count / 4
        var result = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let offset = index * 4
            result[index] = Self.srgbToLightness(
                red: Float(pixels[offset]) / 255,
                green: Float(pixels[offset + 1]) / 255,
                blue: Float(pixels[offset + 2]) / 255
            )
        }
        return result
    }

    private func rgbaPixels(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }

    private func makeImage(
        luminance: [Float],
        chroma: [Float],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let pixelCount = width * height
        guard luminance.count == pixelCount, chroma.count == pixelCount * 2 else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)
        for index in 0..<pixelCount {
            let rgb = Self.labToSrgb(
                lightness: luminance[index],
                a: chroma[index],
                b: chroma[pixelCount + index]
            )
            let offset = index * 4
            pixels[offset] = UInt8(clamping: Int((rgb.red * 255).rounded()))
            pixels[offset + 1] = UInt8(clamping: Int((rgb.green * 255).rounded()))
            pixels[offset + 2] = UInt8(clamping: Int((rgb.blue * 255).rounded()))
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ), let image = context.makeImage() else {
                throw ImageProcessingError.cannotCreateBitmap
            }
            return image
        }
    }

    private static func srgbToLightness(red: Float, green: Float, blue: Float) -> Float {
        let linearRed = srgbToLinear(red)
        let linearGreen = srgbToLinear(green)
        let linearBlue = srgbToLinear(blue)
        let y = linearRed * 0.2126729 + linearGreen * 0.7151522 + linearBlue * 0.0721750
        let transformed = y > 0.008856 ? pow(y, 1 / 3) : 7.787 * y + 16 / 116
        return 116 * transformed - 16
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func labToSrgb(
        lightness: Float,
        a: Float,
        b: Float
    ) -> (red: Float, green: Float, blue: Float) {
        let fy = (lightness + 16) / 116
        let fx = a / 500 + fy
        let fz = fy - b / 200
        let x = inverseLabTransform(fx) * 0.95047
        let y = inverseLabTransform(fy)
        let z = inverseLabTransform(fz) * 1.08883
        let red = x * 3.2404542 + y * -1.5371385 + z * -0.4985314
        let green = x * -0.9692660 + y * 1.8760108 + z * 0.0415560
        let blue = x * 0.0556434 + y * -0.2040259 + z * 1.0572252
        return (linearToSrgb(red), linearToSrgb(green), linearToSrgb(blue))
    }

    private static func inverseLabTransform(_ value: Float) -> Float {
        let cubed = value * value * value
        return cubed > 0.008856 ? cubed : (value - 16 / 116) / 7.787
    }

    private static func linearToSrgb(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}
