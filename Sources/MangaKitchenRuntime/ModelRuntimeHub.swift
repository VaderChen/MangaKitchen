import Foundation
import MangaKitchenCore

public actor ModelRuntimeHub: ModelManaging, ImageToTextGenerating, ImageToImageGenerating {
    private let metal: MetalContext
    private var imageToTextRuntime: (any ImageToTextGenerating)?
    private var imageToImageRuntime: (any ImageToImageGenerating)?
    private var modelInfos: [ModelCapability: LoadedModelInfo] = [:]

    public init(metal: MetalContext) {
        self.metal = metal
    }

    public func loadModel(at directoryURL: URL) async throws -> LoadedModelInfo {
        let manifest = try ModelManifest.load(from: directoryURL)
        let info: LoadedModelInfo
        switch manifest.backend {
        case .coreML:
            let runtime = try CoreMLModelRuntime(
                directoryURL: directoryURL,
                manifest: manifest,
                metal: metal
            )
            info = runtime.info
            switch manifest.capability {
            case .imageToText: imageToTextRuntime = runtime
            case .imageToImage: imageToImageRuntime = runtime
            }

        case .mlxSwift:
            guard manifest.capability == .imageToText else {
                throw ModelRuntimeError.unsupportedBackendCapability(.mlxSwift, manifest.capability)
            }
            let runtime = try MLXVLMRuntime(directoryURL: directoryURL, manifest: manifest)
            try await runtime.prepare { _ in }
            info = runtime.info
            imageToTextRuntime = runtime

        case .externalRuntime:
            guard manifest.capability == .imageToImage else {
                throw ModelRuntimeError.unsupportedBackendCapability(
                    .externalRuntime,
                    manifest.capability
                )
            }
            let runtime = try QwenExternalImageEditRuntime(
                directoryURL: directoryURL,
                manifest: manifest,
                metal: metal
            )
            info = runtime.info
            imageToImageRuntime = runtime
        }
        modelInfos[manifest.capability] = info
        return info
    }

    public func unloadModel(capability: ModelCapability) async {
        switch capability {
        case .imageToText: imageToTextRuntime = nil
        case .imageToImage: imageToImageRuntime = nil
        }
        modelInfos[capability] = nil
    }

    public func loadedModels() async -> [LoadedModelInfo] {
        modelInfos.values.sorted { $0.capability.rawValue < $1.capability.rawValue }
    }

    public func isLoaded(_ capability: ModelCapability) -> Bool {
        switch capability {
        case .imageToText: imageToTextRuntime != nil
        case .imageToImage: imageToImageRuntime != nil
        }
    }

    public func generateText(
        imageURL: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard let runtime = imageToTextRuntime else {
            throw ModelRuntimeError.capabilityNotLoaded(.imageToText)
        }
        return try await runtime.generateText(
            imageURL: imageURL,
            prompt: prompt,
            maximumOutputTokens: maximumOutputTokens,
            progress: progress
        )
    }

    public func generateImage(
        inputURL: URL,
        maskURL: URL?,
        prompt: String,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard let runtime = imageToImageRuntime else {
            throw ModelRuntimeError.capabilityNotLoaded(.imageToImage)
        }
        try await runtime.generateImage(
            inputURL: inputURL,
            maskURL: maskURL,
            prompt: prompt,
            outputURL: outputURL,
            progress: progress
        )
    }
}
