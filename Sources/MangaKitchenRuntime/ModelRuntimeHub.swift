import Foundation
import MangaKitchenCore

public actor ModelRuntimeHub: ModelManaging, TextGenerating, ImageToTextGenerating, ImageToImageGenerating, ImageColorizing, ImageSuperResolving {
    private struct ModelLoadIdentity: Equatable {
        var id: String
        var capability: ModelCapability
        var canonicalPath: String
    }

    private let metal: MetalContext
    private let log: RuntimeLogHandler
    private let reasoningStream: RuntimeReasoningStreamHandler
    private let ggufQuantizationGroupSize: Int
    private var textToTextRuntime: (any TextGenerating)?
    private var imageToTextRuntime: (any ImageToTextGenerating)?
    private var imageToImageRuntime: (any ImageToImageGenerating)?
    private var imageColorizationRuntime: (any ImageColorizing)?
    private var superResolutionRuntime: (any ImageSuperResolving)?
    private var modelInfos: [ModelCapability: LoadedModelInfo] = [:]
    /// `prepare()` 會 suspend 並讓 actor 重入；記錄正在載入的身分，避免原文
    /// 抽取與翻譯同時請求同一個 VLM 時各建立一份 runtime。
    private var activeLoadIdentities: [ModelCapability: ModelLoadIdentity] = [:]
    private var thinkingEnabled: Bool

    public init(
        metal: MetalContext,
        ggufQuantizationGroupSize: Int = 64,
        thinkingEnabled: Bool = false,
        log: @escaping RuntimeLogHandler = { _, _, _ in },
        reasoningStream: @escaping RuntimeReasoningStreamHandler = { _ in }
    ) {
        self.metal = metal
        self.ggufQuantizationGroupSize = ggufQuantizationGroupSize
        self.thinkingEnabled = thinkingEnabled
        self.log = log
        self.reasoningStream = reasoningStream
    }

    public func loadModel(at directoryURL: URL) async throws -> LoadedModelInfo {
        let directoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try ModelManifest.load(from: directoryURL)
        let requestedIdentity = ModelLoadIdentity(
            id: manifest.id,
            capability: manifest.capability,
            canonicalPath: directoryURL.path
        )
        if let loaded = modelInfos[manifest.capability],
           isLoaded(manifest.capability),
           loaded.matchesModel(
               id: manifest.id,
               capability: manifest.capability,
               at: directoryURL
           ) {
            log(
                .debug,
                "Model",
                "Skipped loading \(loaded.displayName) because the same runtime is already loaded."
            )
            return loaded
        }

        // Actor 在第一個 runtime.prepare() 期間可處理第二個 loadModel()。
        // 不論兩個請求是否同模型，同一 capability 都必須序列化；
        // 若前一個完成後就是目標模型，直接共用已載入的 runtime。
        var didLogWaiting = false
        while let activeIdentity = activeLoadIdentities[manifest.capability] {
            if !didLogWaiting {
                let relationship = activeIdentity == requestedIdentity ? "the same" : "another"
                log(
                    .debug,
                    "Model",
                    "Waiting for \(relationship) \(manifest.capability.rawValue) model load to finish."
                )
                didLogWaiting = true
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
            if let loaded = modelInfos[manifest.capability],
               isLoaded(manifest.capability),
               loaded.matchesModel(
                   id: manifest.id,
                   capability: manifest.capability,
                   at: directoryURL
               ) {
                log(
                    .debug,
                    "Model",
                    "Reused \(loaded.displayName) after the existing load completed."
                )
                return loaded
            }
        }
        // 前一個載入可能剛好在 initial check 與 while 之間完成。
        if let loaded = modelInfos[manifest.capability],
           isLoaded(manifest.capability),
           loaded.matchesModel(
               id: manifest.id,
               capability: manifest.capability,
               at: directoryURL
           ) {
            log(.debug, "Model", "Reused \(loaded.displayName) after load synchronization.")
            return loaded
        }
        activeLoadIdentities[manifest.capability] = requestedIdentity
        defer {
            if activeLoadIdentities[manifest.capability] == requestedIdentity {
                activeLoadIdentities[manifest.capability] = nil
            }
        }

        let info: LoadedModelInfo
        switch manifest.backend {
        case .coreML:
            switch manifest.capability {
            case .textToText:
                throw ModelRuntimeError.unsupportedBackendCapability(.coreML, manifest.capability)
            case .imageToText, .imageToImage:
                let runtime = try CoreMLModelRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest,
                    metal: metal
                )
                info = runtime.info
                if manifest.capability == .imageToText {
                    imageToTextRuntime = runtime
                } else {
                    imageToImageRuntime = runtime
                }
            case .imageColorization:
                let runtime = try CoreMLDDColorRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest,
                    metal: metal
                )
                info = runtime.info
                imageColorizationRuntime = runtime
            case .superResolution:
                let superResolution = try CoreMLSuperResolutionRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest,
                    metal: metal
                )
                info = superResolution.info
                superResolutionRuntime = superResolution
            }

        case .mlxSwift:
            switch manifest.capability {
            case .textToText:
                let runtime = try MLXTextRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest,
                    ggufQuantizationGroupSize: ggufQuantizationGroupSize,
                    thinkingEnabled: thinkingEnabled,
                    log: log,
                    reasoningStream: reasoningStream
                )
                try await runtime.prepare { _ in }
                info = runtime.info
                textToTextRuntime = runtime
            case .imageToText:
                let runtime = try MLXVLMRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest,
                    ggufQuantizationGroupSize: ggufQuantizationGroupSize,
                    thinkingEnabled: thinkingEnabled,
                    log: log,
                    reasoningStream: reasoningStream
                )
                try await runtime.prepare { _ in }
                info = runtime.info
                imageToTextRuntime = runtime
            case .superResolution:
                let runtime = try MLXRealESRGANSuperResolutionRuntime(
                    directoryURL: directoryURL,
                    manifest: manifest
                )
                info = runtime.info
                superResolutionRuntime = runtime
            case .imageToImage:
                throw ModelRuntimeError.unsupportedBackendCapability(.mlxSwift, manifest.capability)
            case .imageColorization:
                throw ModelRuntimeError.unsupportedBackendCapability(.mlxSwift, manifest.capability)
            }

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
        log(
            .info,
            "Model",
            "Loaded \(info.displayName) (\(info.backend.rawValue) / \(info.capability.rawValue))."
        )
        return info
    }

    public func unloadModel(capability: ModelCapability) async {
        switch capability {
        case .textToText: textToTextRuntime = nil
        case .imageToText: imageToTextRuntime = nil
        case .imageToImage: imageToImageRuntime = nil
        case .imageColorization: imageColorizationRuntime = nil
        case .superResolution: superResolutionRuntime = nil
        }
        modelInfos[capability] = nil
    }

    /// Think Mode 會改變 chat template；清掉文字 runtime，下一次使用時才依
    /// 新設定延遲重載。OCR、超解析與圖生圖不受影響。
    public func setThinkingEnabled(_ enabled: Bool) {
        guard thinkingEnabled != enabled else { return }
        thinkingEnabled = enabled
        textToTextRuntime = nil
        imageToTextRuntime = nil
        modelInfos[.textToText] = nil
        modelInfos[.imageToText] = nil
    }

    public func loadedModels() async -> [LoadedModelInfo] {
        modelInfos.values.sorted { $0.capability.rawValue < $1.capability.rawValue }
    }

    public func isLoaded(_ capability: ModelCapability) -> Bool {
        switch capability {
        case .textToText: textToTextRuntime != nil
        case .imageToText: imageToTextRuntime != nil
        case .imageToImage: imageToImageRuntime != nil
        case .imageColorization: imageColorizationRuntime != nil
        case .superResolution: superResolutionRuntime != nil
        }
    }

    public func generateText(
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard let runtime = textToTextRuntime else {
            log(.error, "Text Model", "Text-to-text generation requested but no text model is loaded.")
            throw ModelRuntimeError.capabilityNotLoaded(.textToText)
        }
        do {
            return try await runtime.generateText(
                prompt: prompt,
                maximumOutputTokens: maximumOutputTokens,
                progress: progress
            )
        } catch {
            log(.error, "Text Model", "Text-to-text generation failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func generateText(
        imageURL: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        guard let runtime = imageToTextRuntime else {
            log(.error, "Image Model", "Image-to-text generation requested but no image model is loaded.")
            throw ModelRuntimeError.capabilityNotLoaded(.imageToText)
        }
        do {
            return try await runtime.generateText(
                imageURL: imageURL,
                prompt: prompt,
                maximumOutputTokens: maximumOutputTokens,
                progress: progress
            )
        } catch {
            log(.error, "Image Model", "Image-to-text generation failed: \(error.localizedDescription)")
            throw error
        }
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

    public func superResolve(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard let runtime = superResolutionRuntime else {
            throw ModelRuntimeError.capabilityNotLoaded(.superResolution)
        }
        try await runtime.superResolve(
            inputURL: inputURL,
            outputURL: outputURL,
            progress: progress
        )
    }

    public func colorize(
        inputURL: URL,
        maskURL: URL?,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard let runtime = imageColorizationRuntime else {
            throw ModelRuntimeError.capabilityNotLoaded(.imageColorization)
        }
        try await runtime.colorize(
            inputURL: inputURL,
            maskURL: maskURL,
            outputURL: outputURL,
            progress: progress
        )
    }
}
