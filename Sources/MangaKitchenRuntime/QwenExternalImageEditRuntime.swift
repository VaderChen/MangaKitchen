import Darwin
import Foundation
import MangaKitchenCore

actor QwenExternalImageEditRuntime: ImageToImageGenerating {
    let info: LoadedModelInfo

    private struct WorkerRequest: Encodable {
        var modelDirectory: String
        var quantization: String
        var inputPath: String
        var maskPath: String?
        var outputPath: String
        var prompt: String
        var negativePrompt: String
        var steps: Int
        var trueCFGScale: Float
        var seed: UInt64
    }

    private struct WorkerEvent: Decodable {
        var type: String
        var stage: String?
        var value: Double?
        var message: String?
    }

    private let modelDirectory: URL
    private let configuration: ModelManifest.ExternalRuntime
    private let executableURL: URL
    private let compositor: MaskedImageCompositor
    private var runningProcess: Process?

    init(directoryURL: URL, manifest: ModelManifest, metal: MetalContext) throws {
        if #unavailable(macOS 26) {
            throw QwenExternalRuntimeError.requiresMacOS26
        }
        guard manifest.backend == .externalRuntime,
              manifest.capability == .imageToImage else {
            throw ModelRuntimeError.unsupportedBackendCapability(
                manifest.backend,
                manifest.capability
            )
        }
        guard let configuration = manifest.externalRuntime else {
            throw ModelRuntimeError.externalRuntimeConfigurationMissing
        }
        guard configuration.kind == .qwenImageEdit2511 else {
            throw ModelRuntimeError.unsupportedBackend(.externalRuntime)
        }

        self.modelDirectory = directoryURL
        self.configuration = configuration
        self.executableURL = try Self.findWorker(named: configuration.executableName)
        self.compositor = MaskedImageCompositor(metal: metal)
        self.info = LoadedModelInfo(
            id: manifest.id,
            displayName: manifest.displayName,
            capability: manifest.capability,
            backend: manifest.backend,
            location: directoryURL
        )
        try Self.validateModelDirectory(directoryURL, quantization: configuration.quantization)
    }

    func generateImage(
        inputURL: URL,
        maskURL: URL?,
        prompt: String,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw QwenExternalRuntimeError.missingInput(inputURL)
        }
        if let maskURL, !FileManager.default.fileExists(atPath: maskURL.path) {
            throw QwenExternalRuntimeError.missingInput(maskURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let identifier = UUID().uuidString
        let workDirectory = outputURL.deletingLastPathComponent()
        let candidateURL = workDirectory.appendingPathComponent("qwen-candidate-\(identifier).png")
        let requestURL = workDirectory.appendingPathComponent("qwen-request-\(identifier).json")
        let logURL = workDirectory.appendingPathComponent("qwen-log-\(identifier).jsonl")
        defer {
            try? FileManager.default.removeItem(at: candidateURL)
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: logURL)
        }

        let payload = WorkerRequest(
            modelDirectory: modelDirectory.path,
            quantization: configuration.quantization.rawValue,
            inputPath: inputURL.path,
            maskPath: maskURL?.path,
            outputPath: candidateURL.path,
            prompt: prompt,
            negativePrompt: configuration.negativePrompt,
            steps: min(max(configuration.steps, 1), 100),
            trueCFGScale: min(max(configuration.trueCFGScale, 1), 10),
            seed: configuration.seed
        )
        try JSONEncoder().encode(payload).write(to: requestURL, options: .atomic)
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw QwenExternalRuntimeError.logCreationFailed(logURL)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--request", requestURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        runningProcess = process
        defer { runningProcess = nil }

        progress(0.01)
        try process.run()
        var lastProgress = 0.01
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250))
                if let value = Self.latestProgress(in: logURL), value > lastProgress {
                    lastProgress = value
                    progress(min(0.95, value * 0.95))
                }
            }
        } catch is CancellationError {
            await terminate(process)
            throw CancellationError()
        }

        guard process.terminationStatus == 0 else {
            throw QwenExternalRuntimeError.workerFailed(
                status: process.terminationStatus,
                message: Self.logMessage(in: logURL)
            )
        }
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            throw QwenExternalRuntimeError.outputMissing(candidateURL)
        }
        progress(0.96)

        if let maskURL {
            try await compositor.composite(
                sourceURL: inputURL,
                generatedURL: candidateURL,
                maskURL: maskURL,
                outputURL: outputURL
            )
        } else {
            try Data(contentsOf: candidateURL).write(to: outputURL, options: .atomic)
        }
        progress(1)
    }

    private func terminate(_ process: Process) async {
        if process.isRunning { process.terminate() }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private nonisolated static func validateModelDirectory(
        _ directoryURL: URL,
        quantization: ModelManifest.ExternalRuntime.Quantization
    ) throws {
        let snapshot = directoryURL.appendingPathComponent("snapshot", isDirectory: true)
        var required = [
            snapshot.appendingPathComponent("vae/config.json"),
            snapshot.appendingPathComponent("text_encoder/config.json"),
            snapshot.appendingPathComponent("processor/tokenizer.json")
        ]
        switch quantization {
        case .int4:
            let quantized = directoryURL.appendingPathComponent("quantized", isDirectory: true)
            required += [
                quantized.appendingPathComponent("qie-2511-dit-int4-mod8.safetensors"),
                quantized.appendingPathComponent("qie-2511-vl7b-int4.safetensors")
            ]
        case .int8, .fp16:
            required.append(snapshot.appendingPathComponent("transformer/config.json"))
        }
        if let missing = required.first(where: {
            !FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw QwenExternalRuntimeError.modelFileMissing(missing)
        }
    }

    private nonisolated static func findWorker(named name: String) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["MANGAKITCHEN_QWEN_WORKER"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent(name))
            candidates.append(
                executableDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(name)
        )

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workerRoot = packageRoot
            .appendingPathComponent("RuntimeSupport", isDirectory: true)
            .appendingPathComponent("QwenImageEditWorker", isDirectory: true)
        candidates.append(workerRoot.appendingPathComponent(".build/release/\(name)"))
        candidates.append(workerRoot.appendingPathComponent(".build/debug/\(name)"))

        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw QwenExternalRuntimeError.workerNotFound(candidates.map(\.path))
        }
        return executable
    }

    private nonisolated static func latestProgress(in logURL: URL) -> Double? {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return nil }
        return data.split(separator: 0x0A).compactMap { line -> Double? in
            guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: Data(line)),
                  event.type == "progress" else { return nil }
            return event.value
        }.max()
    }

    private nonisolated static func logMessage(in logURL: URL) -> String {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else {
            return "Worker 未提供錯誤訊息。"
        }
        let events = data.split(separator: 0x0A).compactMap {
            try? JSONDecoder().decode(WorkerEvent.self, from: Data($0))
        }
        if let message = events.last(where: { $0.type == "error" })?.message {
            return message
        }
        return String(data: data.suffix(4_096), encoding: .utf8) ?? "Worker 執行失敗。"
    }
}

enum QwenExternalRuntimeError: LocalizedError, Sendable {
    case requiresMacOS26
    case workerNotFound([String])
    case modelFileMissing(URL)
    case missingInput(URL)
    case logCreationFailed(URL)
    case workerFailed(status: Int32, message: String)
    case outputMissing(URL)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            "Qwen Image Edit Swift Worker 目前需要 macOS 26 或更新版本。"
        case let .workerNotFound(paths):
            "找不到 MangaKitchen Qwen Image Edit Worker。已檢查：\(paths.joined(separator: "、"))"
        case let .modelFileMissing(url): "Qwen Image Edit 模型缺少檔案：\(url.path)"
        case let .missingInput(url): "Qwen Image Edit 找不到輸入檔：\(url.path)"
        case let .logCreationFailed(url): "無法建立 Worker log：\(url.path)"
        case let .workerFailed(status, message): "Qwen Image Edit Worker 結束（\(status)）：\(message)"
        case let .outputMissing(url): "Worker 完成但沒有產生圖片：\(url.path)"
        }
    }
}
