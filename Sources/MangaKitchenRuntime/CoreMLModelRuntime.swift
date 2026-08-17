import CoreImage
import CoreML
import Foundation
import MangaKitchenCore
import Vision

actor CoreMLModelRuntime: ImageToTextGenerating, ImageToImageGenerating {
    let manifest: ModelManifest
    let info: LoadedModelInfo

    private let model: MLModel
    private let metal: MetalContext
    private let compiledModelURL: URL

    init(directoryURL: URL, manifest: ModelManifest, metal: MetalContext) throws {
        guard manifest.backend == .coreML else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard let modelFile = manifest.modelFile,
              manifest.inputs != nil,
              manifest.outputs != nil else {
            throw ModelRuntimeError.featureNotFound("Core ML manifest 的 modelFile／inputs／outputs")
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
        configuration.computeUnits = .cpuAndGPU
        configuration.preferredMetalDevice = metal.device

        self.manifest = manifest
        self.metal = metal
        self.compiledModelURL = compiledURL
        self.model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        self.info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
    }

    func generateText(
        imageURL: URL,
        prompt: String,
        maximumOutputTokens _: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard manifest.capability == .imageToText else {
            throw ModelRuntimeError.invalidCapability(expected: .imageToText, actual: manifest.capability)
        }
        guard let outputName = manifest.outputs?.text else {
            throw ModelRuntimeError.featureNotFound("outputs.text")
        }

        progress(0.05)
        let provider = try makeInputProvider(imageURL: imageURL, maskURL: nil, prompt: prompt)
        progress(0.2)
        let prediction = try predictSynchronously(from: provider)
        progress(0.95)
        guard let value = prediction.featureValue(for: outputName), value.type == .string else {
            throw ModelRuntimeError.featureTypeMismatch(outputName)
        }
        progress(1)
        return value.stringValue
    }

    func generateImage(
        inputURL: URL,
        maskURL: URL?,
        prompt: String,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard manifest.capability == .imageToImage else {
            throw ModelRuntimeError.invalidCapability(expected: .imageToImage, actual: manifest.capability)
        }
        guard let outputName = manifest.outputs?.image else {
            throw ModelRuntimeError.featureNotFound("outputs.image")
        }

        progress(0.05)
        let provider = try makeInputProvider(imageURL: inputURL, maskURL: maskURL, prompt: prompt)
        progress(0.2)
        let prediction = try predictSynchronously(from: provider)
        progress(0.9)
        guard let value = prediction.featureValue(for: outputName),
              value.type == .image,
              let pixelBuffer = value.imageBufferValue else {
            throw ModelRuntimeError.featureTypeMismatch(outputName)
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try metal.coreImageContext.writePNGRepresentation(
                of: image,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            throw ModelRuntimeError.imageEncodingFailed(outputURL)
        }
        progress(1)
    }

    private func makeInputProvider(
        imageURL: URL,
        maskURL: URL?,
        prompt: String
    ) throws -> MLDictionaryFeatureProvider {
        var features: [String: MLFeatureValue] = [:]
        guard let inputs = manifest.inputs else {
            throw ModelRuntimeError.featureNotFound("inputs")
        }
        features[inputs.image] = try imageFeatureValue(
            at: imageURL,
            featureName: inputs.image
        )

        if let promptName = inputs.prompt {
            guard model.modelDescription.inputDescriptionsByName[promptName]?.type == .string else {
                throw ModelRuntimeError.featureTypeMismatch(promptName)
            }
            features[promptName] = MLFeatureValue(string: prompt)
        }

        if let maskName = inputs.mask {
            guard let maskURL else {
                throw ModelRuntimeError.featureNotFound("inputs.mask file")
            }
            features[maskName] = try imageFeatureValue(at: maskURL, featureName: maskName)
        }

        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Core ML 的同步 prediction 留在 actor 內序列化執行，避免同一模型重入。
    private func predictSynchronously(
        from provider: MLDictionaryFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func imageFeatureValue(at url: URL, featureName: String) throws -> MLFeatureValue {
        guard let description = model.modelDescription.inputDescriptionsByName[featureName],
              description.type == .image,
              let constraint = description.imageConstraint else {
            throw ModelRuntimeError.featureTypeMismatch(featureName)
        }
        let options: [MLFeatureValue.ImageOption: Any] = [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue
        ]
        return try MLFeatureValue(imageAt: url, constraint: constraint, options: options)
    }
}
