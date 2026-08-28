import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

enum DownloadableModelRole: String, Hashable, Sendable {
    case translation
    case agent
}

struct DownloadableModelDescriptor: Hashable, Sendable {
    enum Format: String, Hashable, Sendable {
        case mlxDirectory
        case ggufDirectory
        case coreMLZip
        case coreMLPackage
    }

    struct CoreMLContract: Hashable, Sendable {
        var modelFileName: String
        var inputName: String
        var outputName: String
    }

    var id: String
    var displayName: String
    var repositoryID: String
    var capability: ModelCapability
    var role: DownloadableModelRole? = nil
    var recommended: Bool = false
    var format: Format = .mlxDirectory
    var outputScale: Int? = nil
    var coreMLContract: CoreMLContract? = nil
    var colorizationInputSize: Int? = nil
    var weightsFileName: String? = nil
    var mmprojFileName: String? = nil
    var auxiliaryRepositoryID: String? = nil
    var auxiliaryFileNames: [String] = []

    var directoryName: String {
        repositoryID.split(separator: "/").last.map(String.init) ?? id
    }
}

enum DownloadableModelCatalog {
    static let translationModels = [
        DownloadableModelDescriptor(
            id: "qwen3-4b-4bit",
            displayName: "Qwen3 4B 4-bit（MLX）",
            repositoryID: "mlx-community/Qwen3-4B-4bit",
            capability: .textToText,
            role: .translation,
            recommended: true
        ),
        DownloadableModelDescriptor(
            id: "qwen3-8b-4bit",
            displayName: "Qwen3 8B 4-bit（MLX）",
            repositoryID: "mlx-community/Qwen3-8B-4bit",
            capability: .textToText,
            role: .translation
        ),
        DownloadableModelDescriptor(
            id: "gpt-oss-20b-mxfp4-q4-mlx",
            displayName: "GPT-OSS 20B MXFP4 Q4（MLX／不推薦）",
            repositoryID: "mlx-community/gpt-oss-20b-MXFP4-Q4",
            capability: .textToText,
            role: .translation
        ),
        DownloadableModelDescriptor(
            id: "gpt-oss-20b-mxfp4-q8-mlx",
            displayName: "GPT-OSS 20B MXFP4 Q8（MLX／不推薦）",
            repositoryID: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            capability: .textToText,
            role: .translation
        ),
        DownloadableModelDescriptor(
            id: "gpt-oss-20b-q4-0-gguf-translation",
            displayName: "GPT-OSS 20B Q4_0（GGUF／不推薦）",
            repositoryID: "unsloth/gpt-oss-20b-GGUF",
            capability: .textToText,
            role: .translation,
            format: .ggufDirectory,
            weightsFileName: "gpt-oss-20b-Q4_0.gguf",
            auxiliaryRepositoryID: "openai/gpt-oss-20b",
            auxiliaryFileNames: [
                "chat_template.jinja",
                "config.json",
                "generation_config.json",
                "special_tokens_map.json",
                "tokenizer.json",
                "tokenizer_config.json"
            ]
        )
    ]

    static let agentModels = [
        DownloadableModelDescriptor(
            id: "gpt-oss-20b-q4-0-gguf",
            displayName: "GPT-OSS 20B Q4_0 GGUF（Agent）",
            repositoryID: "unsloth/gpt-oss-20b-GGUF",
            capability: .textToText,
            role: .agent,
            recommended: true,
            format: .ggufDirectory,
            weightsFileName: "gpt-oss-20b-Q4_0.gguf",
            auxiliaryRepositoryID: "openai/gpt-oss-20b",
            auxiliaryFileNames: [
                "chat_template.jinja",
                "config.json",
                "generation_config.json",
                "special_tokens_map.json",
                "tokenizer.json",
                "tokenizer_config.json"
            ]
        )
    ]

    static let imageToTextModels = [
        DownloadableModelDescriptor(
            id: "qwen3.5-4b-4bit",
            displayName: "Qwen3.5-4B 4-bit",
            repositoryID: "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            capability: .imageToText,
            recommended: true
        ),
        DownloadableModelDescriptor(
            id: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B 4-bit",
            repositoryID: "mlx-community/gemma-4-e4b-it-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B 4-bit",
            repositoryID: "mlx-community/gemma-4-e2b-it-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "gemma-4-12b-it-4bit",
            displayName: "Gemma 4 12B 4-bit",
            repositoryID: "mlx-community/gemma-4-12B-it-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3.5-4b-q4-0-gguf",
            displayName: "Qwen3.5-4B Q4_0 GGUF",
            repositoryID: "unsloth/Qwen3.5-4B-GGUF",
            capability: .imageToText,
            format: .ggufDirectory,
            weightsFileName: "Qwen3.5-4B-Q4_0.gguf",
            mmprojFileName: "mmproj-F16.gguf",
            auxiliaryRepositoryID: "Qwen/Qwen3.5-4B",
            auxiliaryFileNames: [
                "config.json",
                "chat_template.jinja",
                "preprocessor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "video_preprocessor_config.json",
                "vocab.json",
                "merges.txt"
            ]
        ),
        DownloadableModelDescriptor(
            id: "qwen3.5-9b-4bit",
            displayName: "Qwen3.5-9B 4-bit",
            repositoryID: "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3.8-27b-4bit",
            displayName: "Qwen3.8-27B 4-bit",
            repositoryID: "lmstudio-community/Qwen3.8-27B-MLX-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3.8-27b-q4-0-gguf",
            displayName: "Qwen3.8-27B Q4_0 GGUF",
            repositoryID: "unsloth/Qwen3.8-27B-GGUF",
            capability: .imageToText,
            format: .ggufDirectory,
            weightsFileName: "Qwen3.8-27B-Q4_0.gguf",
            mmprojFileName: "mmproj-F16.gguf",
            auxiliaryRepositoryID: "Qwen/Qwen3.8-27B",
            auxiliaryFileNames: [
                "config.json",
                "generation_config.json",
                "chat_template.jinja",
                "preprocessor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "video_preprocessor_config.json",
                "vocab.json",
                "merges.txt"
            ]
        ),
        DownloadableModelDescriptor(
            id: "qwen3-vl-4b-4bit",
            displayName: "Qwen3-VL-4B 4-bit",
            repositoryID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
            capability: .imageToText
        )
    ]

    static let superResolutionModels = [
        DownloadableModelDescriptor(
            id: "realesrgan-anime-512-coreml",
            displayName: "Real-ESRGAN Anime 512（Core ML／4×）",
            repositoryID: "TheMurusTeam/coreml-upscaler-realesrganAnime512",
            capability: .superResolution,
            format: .coreMLZip,
            outputScale: 4,
            coreMLContract: .init(
                modelFileName: "realesrganAnime512.mlmodel",
                inputName: "input",
                outputName: "activation_out"
            )
        ),
        DownloadableModelDescriptor(
            id: "realesrgan-x2plus-mlx",
            displayName: "Real-ESRGAN x2plus（MLX／2×）",
            repositoryID: "mlx-community/Real-ESRGAN-x2plus",
            capability: .superResolution,
            recommended: true,
            format: .mlxDirectory,
            outputScale: 2
        )
    ]

    static let imageColorizationModels = [
        DownloadableModelDescriptor(
            id: "ddcolor-tiny-coreml",
            displayName: "DDColor Tiny（Core ML）",
            repositoryID: "mlboydaisuke/DDColor-Tiny-CoreML",
            capability: .imageColorization,
            recommended: true,
            format: .coreMLPackage,
            coreMLContract: .init(
                modelFileName: "DDColor_Tiny.mlpackage",
                inputName: "image",
                outputName: "ab_channels"
            ),
            colorizationInputSize: 512
        )
    ]

    static var defaultImageToTextModel: DownloadableModelDescriptor {
        imageToTextModels.first(where: \.recommended) ?? imageToTextModels[0]
    }

    static var defaultAgentModel: DownloadableModelDescriptor {
        agentModels.first(where: \.recommended) ?? agentModels[0]
    }

    static var defaultTranslationModel: DownloadableModelDescriptor {
        translationModels.first(where: \.recommended) ?? translationModels[0]
    }

    static var defaultSuperResolutionModel: DownloadableModelDescriptor {
        superResolutionModels.first(where: \.recommended) ?? superResolutionModels[0]
    }

    static var defaultImageColorizationModel: DownloadableModelDescriptor {
        imageColorizationModels.first(where: \.recommended) ?? imageColorizationModels[0]
    }

    static var allModels: [DownloadableModelDescriptor] {
        translationModels + agentModels + imageToTextModels + imageColorizationModels + superResolutionModels
    }

    static func translationModel(id: String) -> DownloadableModelDescriptor? {
        translationModels.first { $0.id == id }
    }

    static func agentModel(id: String) -> DownloadableModelDescriptor? {
        agentModels.first { $0.id == id }
    }

    static func translationModel(matching directoryURL: URL) -> DownloadableModelDescriptor? {
        translationModels.first {
            $0.directoryName.caseInsensitiveCompare(directoryURL.lastPathComponent) == .orderedSame
        }
    }

    static func agentModel(matching directoryURL: URL) -> DownloadableModelDescriptor? {
        agentModels.first {
            $0.directoryName.caseInsensitiveCompare(directoryURL.lastPathComponent) == .orderedSame
        }
    }

    static func model(
        id: String,
        capability: ModelCapability,
        role: DownloadableModelRole? = nil
    ) -> DownloadableModelDescriptor? {
        allModels.first {
            $0.id == id && $0.capability == capability && (role == nil || $0.role == role)
        }
    }

    static func model(
        matching directoryURL: URL,
        capability: ModelCapability,
        role: DownloadableModelRole? = nil
    ) -> DownloadableModelDescriptor? {
        allModels.first {
            $0.capability == capability
                && (role == nil || $0.role == role)
                && $0.directoryName.caseInsensitiveCompare(directoryURL.lastPathComponent) == .orderedSame
        }
    }

    static func modelDirectory(
        storageDirectoryURL: URL,
        model: DownloadableModelDescriptor
    ) -> URL {
        storageDirectoryURL
            .standardizedFileURL
            .appendingPathComponent(model.directoryName, isDirectory: true)
    }

    static func installedModelDirectory(
        storageDirectoryURL: URL,
        model: DownloadableModelDescriptor
    ) -> URL? {
        let directoryURL = modelDirectory(storageDirectoryURL: storageDirectoryURL, model: model)
        return isCompleteModelDirectory(directoryURL, model: model) ? directoryURL : nil
    }

    static func isCompleteModelDirectory(
        _ directoryURL: URL,
        model: DownloadableModelDescriptor? = nil
    ) -> Bool {
        let fileManager = FileManager.default
        if model?.format == .ggufDirectory {
            guard let model,
                  let weightsFileName = model.weightsFileName,
                  fileManager.fileExists(
                    atPath: directoryURL.appendingPathComponent("config.json").path
                  ),
                  fileManager.fileExists(atPath: directoryURL.appendingPathComponent(weightsFileName).path)
            else { return false }
            if let mmprojFileName = model.mmprojFileName,
               !fileManager.fileExists(atPath: directoryURL.appendingPathComponent(mmprojFileName).path) {
                return false
            }
            return model.auxiliaryFileNames.allSatisfy {
                fileManager.fileExists(atPath: directoryURL.appendingPathComponent($0).path)
            }
        }
        if model?.format == .coreMLZip || model?.format == .coreMLPackage {
            guard let manifest = try? ModelManifest.load(from: directoryURL),
                  manifest.capability == model?.capability,
                  let modelFile = manifest.modelFile else { return false }
            return fileManager.fileExists(atPath: directoryURL.appendingPathComponent(modelFile).path)
        }
        let configURL = directoryURL.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return false }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            return true
        }
        return false
    }
}

struct ModelDownloadState: Encodable, Sendable {
    var capability: ModelCapability
    var variantID: String
    var progress: Double
    var downloadedByteCount: Int64 = 0
    var totalByteCount: Int64 = 0
    var bytesPerSecond: Double? = nil
}

struct ModelLoadingState: Encodable, Equatable, Sendable {
    enum Phase: String, Encodable, Equatable, Sendable {
        case loading
        case completed
        case failed
    }

    var id: UUID
    var phase: Phase
    var displayName: String
    var currentIndex: Int
    var totalCount: Int
    var progress: Double
    var errorMessage: String?
}
