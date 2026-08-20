import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

struct DownloadableModelDescriptor: Hashable, Sendable {
    enum Format: String, Hashable, Sendable {
        case mlxDirectory
        case coreMLZip
    }

    var id: String
    var displayName: String
    var repositoryID: String
    var capability: ModelCapability
    var recommended: Bool = false
    var format: Format = .mlxDirectory
    var outputScale: Int? = nil

    var directoryName: String {
        repositoryID.split(separator: "/").last.map(String.init) ?? id
    }
}

enum DownloadableModelCatalog {
    static let imageToTextModels = [
        DownloadableModelDescriptor(
            id: "qwen3-vl-4b-4bit",
            displayName: "Qwen3-VL-4B 4-bit",
            repositoryID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
            capability: .imageToText,
            recommended: true
        ),
        DownloadableModelDescriptor(
            id: "qwen3-vl-4b-8bit",
            displayName: "Qwen3-VL-4B 8-bit",
            repositoryID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-8bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3-vl-2b-4bit",
            displayName: "Qwen3-VL-2B 4-bit",
            repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3-vl-8b-4bit",
            displayName: "Qwen3-VL-8B 4-bit",
            repositoryID: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            capability: .imageToText
        ),
        DownloadableModelDescriptor(
            id: "qwen3-vl-8b-8bit",
            displayName: "Qwen3-VL-8B 8-bit",
            repositoryID: "mlx-community/Qwen3-VL-8B-Instruct-8bit",
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
            outputScale: 4
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

    static var defaultImageToTextModel: DownloadableModelDescriptor {
        imageToTextModels[0]
    }

    static var defaultSuperResolutionModel: DownloadableModelDescriptor {
        superResolutionModels.first(where: \.recommended) ?? superResolutionModels[0]
    }

    static var allModels: [DownloadableModelDescriptor] {
        imageToTextModels + superResolutionModels
    }

    static func model(id: String, capability: ModelCapability) -> DownloadableModelDescriptor? {
        allModels.first { $0.id == id && $0.capability == capability }
    }

    static func model(matching directoryURL: URL, capability: ModelCapability) -> DownloadableModelDescriptor? {
        allModels.first {
            $0.capability == capability
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
        if model?.format == .coreMLZip {
            guard let manifest = try? ModelManifest.load(from: directoryURL),
                  manifest.capability == .superResolution,
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
