import Foundation
import ImageIO
import MLXLMCommon
import MLXVLM
import MangaKitchenCore
import UniformTypeIdentifiers

/// 執行本機 Hugging Face MLX VLM 目錄；矩陣運算由 MLX 的 Metal 後端處理。
actor MLXVLMRuntime: ImageToTextGenerating {
    let info: LoadedModelInfo

    private let modelDirectory: URL
    private let generation: ModelManifest.Generation
    private var container: ModelContainer?

    init(directoryURL: URL, manifest: ModelManifest) throws {
        guard manifest.backend == .mlxSwift else {
            throw ModelRuntimeError.unsupportedBackend(manifest.backend)
        }
        guard manifest.capability == .imageToText else {
            throw ModelRuntimeError.unsupportedBackendCapability(.mlxSwift, manifest.capability)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelRuntimeError.modelFileNotFound(directoryURL)
        }

        self.modelDirectory = directoryURL
        self.generation = manifest.generation ?? ModelManifest.Generation()
        self.info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
    }

    func prepare(progress: @escaping InferenceProgress) async throws {
        _ = try await loadContainer(progress: progress)
    }

    func generateText(
        imageURL: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw MLXVLMRuntimeError.missingInputFile(imageURL)
        }
        let preparedImage = try Self.preparedImageURL(
            from: imageURL,
            maximumPixelSize: min(max(generation.maximumImageDimension, 512), 4_096)
        )
        defer {
            if preparedImage.isTemporary {
                try? FileManager.default.removeItem(at: preparedImage.url)
            }
        }

        progress(0.01)
        let container = try await loadContainer(progress: progress)
        try Task.checkCancellation()
        progress(0.48)

        let input = UserInput(chat: [
            .user(prompt, images: [.url(preparedImage.url)])
        ])
        let prepared = try await container.prepare(input: input)
        progress(0.55)

        let requestedMaxTokens = maximumOutputTokens.map {
            min($0, generation.maxTokens)
        } ?? generation.maxTokens
        let maxTokens = min(max(requestedMaxTokens, 128), 8_192)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: min(max(generation.temperature, 0), 2),
            topP: min(max(generation.topP, 0.05), 1),
            repetitionPenalty: max(generation.repetitionPenalty, 1),
            repetitionContextSize: 128
        )
        let stream = try await container.generate(input: prepared, parameters: parameters)
        let expectedChunks = min(maxTokens, 512)
        var result = ""
        var chunks = 0

        for await event in stream {
            try Task.checkCancellation()
            if case let .chunk(text) = event {
                result += text
                chunks += 1
                progress(min(0.99, 0.55 + Double(chunks) / Double(expectedChunks) * 0.44))
            }
        }

        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw MLXVLMRuntimeError.emptyResponse }
        progress(1)
        return output
    }

    private func loadContainer(progress: @escaping InferenceProgress) async throws -> ModelContainer {
        if let container {
            progress(0.45)
            return container
        }
        let loaded = try await VLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: modelDirectory)
        ) { value in
            progress(value.fractionCompleted * 0.45)
        }
        container = loaded
        return loaded
    }

    private static func preparedImageURL(
        from sourceURL: URL,
        maximumPixelSize: Int
    ) throws -> (url: URL, isTemporary: Bool) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        guard max(width.intValue, height.intValue) > maximumPixelSize else {
            return (sourceURL, false)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-vlm-\(UUID().uuidString)")
            .appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw MLXVLMRuntimeError.invalidImage(sourceURL)
        }
        return (temporaryURL, true)
    }
}

enum MLXVLMRuntimeError: LocalizedError, Sendable {
    case missingInputFile(URL)
    case invalidImage(URL)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case let .missingInputFile(url): "找不到圖生文輸入圖片：\(url.path)"
        case let .invalidImage(url): "圖生文模型無法讀取圖片：\(url.path)"
        case .emptyResponse: "MLX 圖生文模型沒有回傳內容。"
        }
    }
}
