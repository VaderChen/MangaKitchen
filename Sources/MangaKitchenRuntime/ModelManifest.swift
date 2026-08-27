import Foundation
import MangaKitchenCore

/// 每個模型目錄都以此 manifest 描述 Core ML 的實際 feature 名稱。
/// 這讓核心流程不需要針對每個模型寫死欄位。
public struct ModelManifest: Codable, Hashable, Sendable {
    public enum WeightsFormat: String, Codable, Hashable, Sendable {
        case safetensors
        case gguf
    }

    public struct Inputs: Codable, Hashable, Sendable {
        public var image: String
        public var prompt: String?
        public var mask: String?

        public init(image: String, prompt: String? = nil, mask: String? = nil) {
            self.image = image
            self.prompt = prompt
            self.mask = mask
        }
    }

    public struct Outputs: Codable, Hashable, Sendable {
        public var text: String?
        public var image: String?
        public var chroma: String?

        public init(text: String? = nil, image: String? = nil, chroma: String? = nil) {
            self.text = text
            self.image = image
            self.chroma = chroma
        }
    }

    public struct Colorization: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case ddcolor
        }

        public var kind: Kind
        public var inputSize: Int

        public init(kind: Kind = .ddcolor, inputSize: Int = 512) {
            self.kind = kind
            self.inputSize = inputSize
        }
    }

    public struct Generation: Codable, Hashable, Sendable {
        public var maximumImageDimension: Int
        public var maxTokens: Int
        public var temperature: Float
        public var topP: Float
        public var repetitionPenalty: Float

        public init(
            maximumImageDimension: Int = 1_280,
            maxTokens: Int = 4_096,
            temperature: Float = 0.2,
            topP: Float = 0.9,
            repetitionPenalty: Float = 1.1
        ) {
            self.maximumImageDimension = maximumImageDimension
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.repetitionPenalty = repetitionPenalty
        }
    }

    public struct ExternalRuntime: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case qwenImageEdit2511
        }

        public enum Quantization: String, Codable, Hashable, Sendable {
            case int4
            case int8
            case fp16
        }

        public var kind: Kind
        public var executableName: String
        public var quantization: Quantization
        public var steps: Int
        public var trueCFGScale: Float
        public var seed: UInt64
        public var negativePrompt: String

        public init(
            kind: Kind = .qwenImageEdit2511,
            executableName: String = "MangaKitchenQwenImageEditWorker",
            quantization: Quantization = .int4,
            steps: Int = 20,
            trueCFGScale: Float = 4,
            seed: UInt64 = 42,
            negativePrompt: String = "text, letters, watermark, artifacts"
        ) {
            self.kind = kind
            self.executableName = executableName
            self.quantization = quantization
            self.steps = steps
            self.trueCFGScale = trueCFGScale
            self.seed = seed
            self.negativePrompt = negativePrompt
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var displayName: String
    public var capability: ModelCapability
    public var backend: ModelBackend
    public var modelFile: String?
    public var weightsFile: String?
    public var weightsFormat: WeightsFormat?
    public var mmprojFile: String?
    public var inputs: Inputs?
    public var outputs: Outputs?
    public var colorization: Colorization?
    public var superResolutionScale: Int?
    public var generation: Generation?
    public var externalRuntime: ExternalRuntime?

    public init(
        schemaVersion: Int = 1,
        id: String,
        displayName: String,
        capability: ModelCapability,
        backend: ModelBackend = .coreML,
        modelFile: String? = nil,
        weightsFile: String? = nil,
        weightsFormat: WeightsFormat? = nil,
        mmprojFile: String? = nil,
        inputs: Inputs? = nil,
        outputs: Outputs? = nil,
        colorization: Colorization? = nil,
        superResolutionScale: Int? = nil,
        generation: Generation? = nil,
        externalRuntime: ExternalRuntime? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.capability = capability
        self.backend = backend
        self.modelFile = modelFile
        self.weightsFile = weightsFile
        self.weightsFormat = weightsFormat
        self.mmprojFile = mmprojFile
        self.inputs = inputs
        self.outputs = outputs
        self.colorization = colorization
        self.superResolutionScale = superResolutionScale
        self.generation = generation
        self.externalRuntime = externalRuntime
    }

    public static func load(from directoryURL: URL) throws -> ModelManifest {
        let manifestURL = directoryURL.appendingPathComponent("mangakitchen-model.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            if let inferredManifest = try inferMLXLanguageManifest(from: directoryURL) {
                return inferredManifest
            }
            throw ModelRuntimeError.manifestNotFound(manifestURL)
        }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1 else {
            throw ModelRuntimeError.unsupportedManifestVersion(manifest.schemaVersion)
        }
        try manifest.validateRuntimeAssets(in: directoryURL)
        return manifest
    }

    private func validateRuntimeAssets(in directoryURL: URL) throws {
        guard backend == .mlxSwift else { return }
        let explicitlyUsesGGUF = weightsFormat == .gguf
            || weightsFile?.lowercased().hasSuffix(".gguf") == true
            || modelFile?.lowercased().hasSuffix(".gguf") == true
        guard explicitlyUsesGGUF else { return }

        guard let weightURL = try MLXGGUFModelSource.weightURL(
            in: directoryURL,
            manifest: self
        ) else {
            throw MLXGGUFLoaderError.ambiguousWeights(directoryURL)
        }
        let missingAssets = MLXGGUFModelSource.missingRuntimeAssetNames(
            in: directoryURL,
            weightURL: weightURL
        )
        guard missingAssets.isEmpty else {
            throw ModelRuntimeError.ggufRuntimeAssetsMissing(directoryURL, missingAssets)
        }
        if capability == .imageToText,
           try MLXGGUFModelSource.mmprojURL(in: directoryURL, manifest: self) == nil {
            throw MLXGGUFLoaderError.missingMultimodalProjector(
                directoryURL.appendingPathComponent("mmproj-F16.gguf")
            )
        }
    }

    /// 無 manifest 的 Hugging Face MLX 目錄會依 config 自動區分純文字 LLM
    /// 與 VLM，避免 Qwen3 純文字權重被誤判為圖生文。
    private static func inferMLXLanguageManifest(from directoryURL: URL) throws -> ModelManifest? {
        let fileManager = FileManager.default
        let configURL = directoryURL.appendingPathComponent("config.json")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let hasSafetensors = entries.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasGGUF = entries.contains { $0.pathExtension.lowercased() == "gguf" }
        guard hasSafetensors || hasGGUF else { return nil }
        if hasGGUF {
            let missingAssets = MLXGGUFModelSource.missingRuntimeAssetNames(in: directoryURL)
            if !missingAssets.isEmpty {
                throw ModelRuntimeError.ggufRuntimeAssetsMissing(directoryURL, missingAssets)
            }
        } else if !MLXGGUFModelSource.missingRuntimeAssetNames(in: directoryURL).isEmpty {
            return nil
        }
        let mainGGUF = entries
            .filter {
                $0.pathExtension.lowercased() == "gguf"
                    && !$0.lastPathComponent.lowercased().contains("mmproj")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let mmprojGGUF = entries
            .filter {
                $0.pathExtension.lowercased() == "gguf"
                    && $0.lastPathComponent.lowercased().contains("mmproj")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let configData: Data
        if hasGGUF, mainGGUF.count == 1,
           let embeddedConfigData = try? MLXGGUFEmbeddedAssets.configurationData(
               weightURL: mainGGUF[0],
               mmprojURL: mmprojGGUF.count == 1 ? mmprojGGUF[0] : nil
           ) {
            configData = embeddedConfigData
        } else if fileManager.fileExists(atPath: configURL.path) {
            guard let externalConfigData = try? Data(contentsOf: configURL) else {
                return nil
            }
            configData = externalConfigData
        } else {
            return nil
        }
        guard let configObject = try? JSONSerialization.jsonObject(with: configData),
              let config = configObject as? [String: Any]
        else {
            return nil
        }

        let architectureNames = config["architectures"] as? [String] ?? []
        let modelType = config["model_type"] as? String ?? ""
        let imageCapabilityDescriptors = Array(config.keys) + architectureNames + [modelType]
        let hasImageCapability = imageCapabilityDescriptors.contains { descriptor in
            let normalized = descriptor.lowercased()
            return normalized.contains("vision") || normalized.contains("image")
        }
        let configuredID = (config["_name_or_path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = directoryURL.lastPathComponent
        let modelID: String
        if let configuredID, !configuredID.isEmpty {
            modelID = configuredID
        } else {
            modelID = directoryName
        }

        let weightsFormat: WeightsFormat? =
            hasGGUF && !hasSafetensors
            ? .gguf
            : nil
        let inferredWeightsFile = hasSafetensors
            ? nil
            : mainGGUF.count == 1 ? mainGGUF[0].lastPathComponent : nil
        let inferredMMProjFile = hasSafetensors
            ? nil
            : mmprojGGUF.count == 1 ? mmprojGGUF[0].lastPathComponent : nil

        if let inferredWeightsFile, weightsFormat == .gguf {
            let weightURL = directoryURL.appendingPathComponent(inferredWeightsFile)
            let inspection = try MLXNativeGGUFBackend().inspect(fileURL: weightURL)
            guard MLXNativeGGUFBackend().canMaterialize(inspection) else {
                throw GGUFBackendError.unsupportedMaterialization(types: inspection.unsupportedTypes)
            }
        }

        let manifest = ModelManifest(
            id: modelID,
            displayName: directoryName,
            capability: hasImageCapability ? .imageToText : .textToText,
            backend: .mlxSwift,
            weightsFile: inferredWeightsFile,
            weightsFormat: weightsFormat,
            mmprojFile: inferredMMProjFile,
            generation: Generation()
        )
        try manifest.validateRuntimeAssets(in: directoryURL)
        return manifest
    }
}

public enum ModelRuntimeError: LocalizedError, Sendable {
    case manifestNotFound(URL)
    case unsupportedManifestVersion(Int)
    case unsupportedBackend(ModelBackend)
    case unsupportedBackendCapability(ModelBackend, ModelCapability)
    case externalRuntimeConfigurationMissing
    case ggufRuntimeAssetsMissing(URL, [String])
    case modelFileNotFound(URL)
    case capabilityNotLoaded(ModelCapability)
    case invalidCapability(expected: ModelCapability, actual: ModelCapability)
    case featureNotFound(String)
    case featureTypeMismatch(String)
    case imageEncodingFailed(URL)

    public var errorDescription: String? {
        switch self {
        case let .manifestNotFound(url):
            "找不到模型描述檔：\(url.path)"
        case let .unsupportedManifestVersion(version):
            "不支援模型描述檔版本：\(version)"
        case let .unsupportedBackend(backend):
            "目前尚未安裝 \(backend.rawValue) 模型 Adapter。"
        case let .unsupportedBackendCapability(backend, capability):
            "\(backend.rawValue) Adapter 尚未支援 \(capability.rawValue) 模型。"
        case .externalRuntimeConfigurationMissing:
            "externalRuntime manifest 缺少 externalRuntime 設定。"
        case let .ggufRuntimeAssetsMissing(url, assets):
            "GGUF 模型缺少必要的 Hugging Face runtime 資產（\(assets.joined(separator: ", "))）：\(url.path)"
        case let .modelFileNotFound(url):
            "找不到 Core ML 模型：\(url.path)"
        case let .capabilityNotLoaded(capability):
            "尚未載入 \(capability.rawValue) 模型。"
        case let .invalidCapability(expected, actual):
            "模型能力不符，預期 \(expected.rawValue)，實際為 \(actual.rawValue)。"
        case let .featureNotFound(name):
            "模型沒有名為 \(name) 的 feature。"
        case let .featureTypeMismatch(name):
            "模型 feature「\(name)」的型別不符合 manifest。"
        case let .imageEncodingFailed(url):
            "無法輸出模型圖片：\(url.path)"
        }
    }
}
