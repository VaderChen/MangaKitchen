import Foundation
import MangaKitchenCore
import MangaKitchenRuntime
#if canImport(Darwin)
import Darwin
#endif

private struct BenchmarkSnapshot: Sendable {
    let firstTokenLatency: Double?
    let promptTokensPerSecond: Double?
    let tokensPerSecond: Double?
    let promptTokenCount: Int?
    let generationTokenCount: Int?
}

private final class BenchmarkMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstTokenLatency: Double?
    private var promptTokensPerSecond: Double?
    private var tokensPerSecond: Double?
    private var promptTokenCount: Int?
    private var generationTokenCount: Int?

    func record(category: String, message: String) {
        guard category == "Generation Metrics" else { return }
        lock.lock()
        defer { lock.unlock() }
        if let value = Self.doubleValue(named: "firstTokenLatency", in: message),
           firstTokenLatency == nil {
            firstTokenLatency = value
        }
        if let value = Self.doubleValue(named: "promptTokensPerSecond", in: message) {
            promptTokensPerSecond = value
        }
        if let value = Self.doubleValue(named: "tokensPerSecond", in: message) {
            tokensPerSecond = value
        }
        if let value = Self.intValue(named: "promptTokens", in: message) {
            promptTokenCount = value
        }
        if let value = Self.intValue(named: "generationTokens", in: message) {
            generationTokenCount = value
        }
    }

    func snapshot() -> BenchmarkSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BenchmarkSnapshot(
            firstTokenLatency: firstTokenLatency,
            promptTokensPerSecond: promptTokensPerSecond,
            tokensPerSecond: tokensPerSecond,
            promptTokenCount: promptTokenCount,
            generationTokenCount: generationTokenCount
        )
    }

    private static func doubleValue(named name: String, in message: String) -> Double? {
        guard let token = valueToken(named: name, in: message) else { return nil }
        return Double(token)
    }

    private static func intValue(named name: String, in message: String) -> Int? {
        guard let token = valueToken(named: name, in: message) else { return nil }
        return Int(token)
    }

    private static func valueToken(named name: String, in message: String) -> Substring? {
        let prefix = name + "="
        guard let range = message.range(of: prefix) else { return nil }
        return message[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first
    }
}

@main
struct GGUFSmoke {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var filePath: String?
        var directoryPath: String?
        var mmprojPath: String?
        var shouldLoad = false
        var shouldBenchmark = false
        var imagePath: String?
        var prompt = "Describe this image in one short sentence."
        var maximumOutputTokens = 128
        var ggufQuantizationGroupSize = 32
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                guard index < arguments.count else { return usage() }
                filePath = arguments[index]
            case "--directory":
                index += 1
                guard index < arguments.count else { return usage() }
                directoryPath = arguments[index]
            case "--mmproj":
                index += 1
                guard index < arguments.count else { return usage() }
                mmprojPath = arguments[index]
            case "--load":
                shouldLoad = true
            case "--benchmark":
                shouldLoad = true
                shouldBenchmark = true
            case "--image":
                index += 1
                guard index < arguments.count else { return usage() }
                imagePath = arguments[index]
            case "--prompt":
                index += 1
                guard index < arguments.count else { return usage() }
                prompt = arguments[index]
            case "--tokens":
                index += 1
                guard index < arguments.count,
                      let parsedTokens = Int(arguments[index]),
                      parsedTokens > 0
                else { return usage() }
                maximumOutputTokens = parsedTokens
            case "--gguf-group-size":
                index += 1
                guard index < arguments.count,
                      let parsedGroupSize = Int(arguments[index]),
                      parsedGroupSize == 32 || parsedGroupSize == 64
                else { return usage() }
                ggufQuantizationGroupSize = parsedGroupSize
            case "--help", "-h":
                return usage()
            default:
                return usage()
            }
            index += 1
        }

        guard (filePath != nil) != (directoryPath != nil),
              !(directoryPath != nil && mmprojPath != nil) else {
            return usage()
        }

        do {
            let directoryURL: URL
            if let filePath {
                let backend = MLXNativeGGUFBackend()
                let mainURL = URL(fileURLWithPath: filePath)
                let mainInspection = try backend.inspect(fileURL: mainURL)
                printInspection("main", mainInspection)
                if let mmprojPath {
                    let mmprojInspection = try backend.inspect(
                        fileURL: URL(fileURLWithPath: mmprojPath)
                    )
                    printInspection("mmproj", mmprojInspection)
                }
                directoryURL = mainURL.deletingLastPathComponent()
            } else if let directoryPath {
                directoryURL = URL(fileURLWithPath: directoryPath)
                print("directory=\(directoryURL.standardizedFileURL.path)")
            } else {
                return usage()
            }
            if shouldLoad {
                print(
                    "mlxLoad=starting directory=\(directoryURL.path) "
                        + "ggufGroupSize=\(ggufQuantizationGroupSize)"
                )
                let metal = try MetalContext()
                let metricsRecorder = BenchmarkMetricsRecorder()
                let hub = ModelRuntimeHub(
                    metal: metal,
                    ggufQuantizationGroupSize: ggufQuantizationGroupSize,
                    log: { level, category, message in
                        metricsRecorder.record(category: category, message: message)
                        print("log=\(level.rawValue) category=\(category) message=\(message)")
                    }
                )
                let loadStart = Date()
                let loaded = try await hub.loadModel(at: directoryURL)
                let loadSeconds = Date().timeIntervalSince(loadStart)
                let peakRSSBytes = Self.peakRSSBytes()
                print(
                    "mlxLoad=ok model=\(loaded.displayName) "
                        + "seconds=\(loadSeconds)"
                )
                printMeasurement(name: "load", seconds: loadSeconds, peakRSSBytes: peakRSSBytes)
                if shouldBenchmark {
                    let benchmarkStart = Date()
                    switch loaded.capability {
                    case .imageToText:
                        guard let imagePath else { return usage() }
                        _ = try await hub.generateText(
                            imageURL: URL(fileURLWithPath: imagePath),
                            prompt: prompt,
                            maximumOutputTokens: maximumOutputTokens,
                            progress: { _ in }
                        )
                    case .textToText:
                        _ = try await hub.generateText(
                            prompt: prompt,
                            maximumOutputTokens: maximumOutputTokens,
                            progress: { _ in }
                        )
                    default:
                        return usage()
                    }
                    let benchmarkSeconds = Date().timeIntervalSince(benchmarkStart)
                    print("benchmark=ok seconds=\(benchmarkSeconds)")
                    printMeasurement(
                        name: "generation",
                        seconds: benchmarkSeconds,
                        peakRSSBytes: Self.peakRSSBytes(),
                        metrics: metricsRecorder.snapshot()
                    )
                }
            }
        } catch {
            fputs("load failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func printInspection(
        _ label: String,
        _ inspection: GGUFBackendInspection
    ) {
        print(
            "\(label): backend=mlx-native "
                + "materializable=\(inspection.unsupportedTypes.isEmpty) "
                + "version=\(inspection.version) "
                + "tensors=\(inspection.tensorCount)"
        )
        print("types=\(inspection.quantizationCounts)")
        print("storage=\(inspection.storageTypeCounts)")
        print("conversionTensors=\(inspection.conversionTensorCount)")
        print("preservedQuantizedTensors=\(inspection.storagePlan.preservedQuantizedTensorCount)")
        if !inspection.unsupportedTypes.isEmpty {
            print("unsupportedTypes=\(inspection.unsupportedTypes)")
        }
    }

    private static func printMeasurement(
        name: String,
        seconds: Double,
        peakRSSBytes: UInt64?,
        metrics: BenchmarkSnapshot? = nil
    ) {
        var fields = [
            "measurement=\(name)",
            "seconds=\(seconds)"
        ]
        if let peakRSSBytes {
            fields.append("peakRSSBytes=\(peakRSSBytes)")
            fields.append("peakRSSGiB=\(Double(peakRSSBytes) / 1_073_741_824)")
        }
        if let metrics {
            if let value = metrics.firstTokenLatency {
                fields.append("firstTokenLatencySeconds=\(value)")
            }
            if let value = metrics.promptTokensPerSecond {
                fields.append("promptTokensPerSecond=\(value)")
            }
            if let value = metrics.tokensPerSecond {
                fields.append("tokensPerSecond=\(value)")
            }
            if let value = metrics.promptTokenCount {
                fields.append("promptTokens=\(value)")
            }
            if let value = metrics.generationTokenCount {
                fields.append("generationTokens=\(value)")
            }
        }
        print(fields.joined(separator: " "))
    }

    private static func peakRSSBytes() -> UInt64? {
        #if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            return nil
        }
        return UInt64(usage.ru_maxrss)
        #else
        return nil
        #endif
    }

    private static func usage() {
        print(
            "usage: GGUFSmoke (--file model.gguf [--mmproj mmproj.gguf] "
                + "| --directory model-directory) [--load] "
                + "[--benchmark --image image] [--prompt text] [--tokens count] "
                + "[--gguf-group-size 32|64]"
        )
    }
}
