import Foundation
import MangaKitchenCore
import MangaKitchenRuntime

/// 管理模型偏好、延遲載入、身分比對與記憶體壓力釋放。
@MainActor
final class AppModelLifecycleCoordinator {
    typealias LoadedModelsDidChange = ([LoadedModelInfo]) -> Void
    typealias LoadingStateDidChange = (ModelLoadingState?) -> Void
    typealias StatusDidChange = (String) -> Void
    typealias MetricsDidChange = (SystemMetricsSnapshot) -> Void
    typealias Log = (RuntimeLogLevel, String) -> Void

    private static let memoryPressureThreshold = 0.80
    private static let largeModelWeightThresholdBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    private let models: ModelRuntimeHub?
    private let loadedModelsDidChange: LoadedModelsDidChange
    private let loadingStateDidChange: LoadingStateDidChange
    private let statusDidChange: StatusDidChange
    private let metricsDidChange: MetricsDidChange
    private let log: Log
    private var preferredPaths: [ModelCapability: String] = [:]
    private var loadedModels: [LoadedModelInfo] = []
    private var loadingState: ModelLoadingState? {
        didSet { loadingStateDidChange(loadingState) }
    }

    var isAvailable: Bool { models != nil }

    init(
        models: ModelRuntimeHub?,
        loadedModelsDidChange: @escaping LoadedModelsDidChange,
        loadingStateDidChange: @escaping LoadingStateDidChange,
        statusDidChange: @escaping StatusDidChange,
        metricsDidChange: @escaping MetricsDidChange,
        log: @escaping Log
    ) {
        self.models = models
        self.loadedModelsDidChange = loadedModelsDidChange
        self.loadingStateDidChange = loadingStateDidChange
        self.statusDidChange = statusDidChange
        self.metricsDidChange = metricsDidChange
        self.log = log
    }

    func replaceLoadedModels(_ values: [LoadedModelInfo]) {
        loadedModels = values
        loadedModelsDidChange(values)
    }

    func hasConfiguredModel(_ capability: ModelCapability) -> Bool {
        loadedModels.contains(where: { $0.capability == capability })
            || preferredPaths[capability] != nil
    }

    func effectiveTranslationModelMethod() -> TranslationModelMethod? {
        hasConfiguredModel(.imageToText) ? .imageToText : nil
    }

    func setThinkingEnabled(_ enabled: Bool) async {
        guard let models else { return }
        await models.setThinkingEnabled(enabled)
        await refreshLoadedModels()
    }

    func configurePreferredModel(
        capability: ModelCapability,
        path: String?
    ) async -> Bool {
        guard let models else { return false }
        let normalizedPath = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if preferredPaths[capability] == normalizedPath { return true }
        await models.unloadModel(capability: capability)
        await refreshLoadedModels()
        guard let normalizedPath else {
            preferredPaths.removeValue(forKey: capability)
            log(.info, "Cleared lazy \(capability.rawValue) model configuration.")
            return true
        }
        do {
            let directoryURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
            let manifest = try ModelManifest.load(from: directoryURL)
            guard manifest.capability == capability else {
                throw PreferredModelError.capabilityMismatch(expected: capability)
            }
            preferredPaths[capability] = normalizedPath
            log(.info, "Configured \(manifest.displayName) for lazy loading.")
            return true
        } catch {
            preferredPaths.removeValue(forKey: capability)
            statusDidChange(error.localizedDescription)
            log(.error, error.localizedDescription)
            return false
        }
    }

    func ensureLoaded(_ capability: ModelCapability, purpose: String) async throws {
        guard let models else { throw ModelLifecycleError.runtimeUnavailable }
        let path = preferredPaths[capability].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if let loaded = await models.loadedModels().first(where: { $0.capability == capability }) {
            if let path,
               let manifest = try? ModelManifest.load(from: path),
               loaded.matchesModel(id: manifest.id, capability: capability, at: path) {
                await refreshLoadedModels()
                return
            }
            await models.unloadModel(capability: capability)
            await refreshLoadedModels()
        }
        guard let path else { throw ModelRuntimeError.capabilityNotLoaded(capability) }
        log(.info, "Lazy-loading \(capability.rawValue) model for \(purpose).")
        _ = try await loadModel(
            from: path,
            sessionID: UUID(),
            currentIndex: 1,
            totalCount: 1
        )
        await refreshLoadedModels()
    }

    func loadModel(
        from directoryURL: URL,
        sessionID: UUID = UUID(),
        currentIndex: Int = 1,
        totalCount: Int = 1
    ) async throws -> LoadedModelInfo {
        guard let models else { throw ModelLifecycleError.runtimeUnavailable }
        let safeTotalCount = max(1, totalCount)
        let safeCurrentIndex = min(max(1, currentIndex), safeTotalCount)
        let canonicalDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try ModelManifest.load(from: canonicalDirectoryURL)
        guard manifest.capability != .textToText else {
            throw ModelLifecycleError.textToTextUnsupported
        }
        let displayName = manifest.displayName
        if let loaded = await models.loadedModels().first(where: {
            $0.matchesModel(
                id: manifest.id,
                capability: manifest.capability,
                at: canonicalDirectoryURL
            )
        }) {
            await refreshLoadedModels()
            log(.debug, "Skipped loading \(loaded.displayName) because it is already active.")
            return loaded
        }

        loadingState = ModelLoadingState(
            id: sessionID,
            phase: .loading,
            displayName: displayName,
            currentIndex: safeCurrentIndex,
            totalCount: safeTotalCount,
            progress: Double(safeCurrentIndex - 1) / Double(safeTotalCount),
            errorMessage: nil
        )
        statusDidChange("正在載入模型：\(displayName)…")

        do {
            if shouldReleaseModelsBeforeLoad(modelDirectoryURL: canonicalDirectoryURL) {
                await releaseModelsForMemoryPressure(
                    reason: displayName,
                    preservingModelID: manifest.id,
                    preservingCapability: manifest.capability,
                    preservingLocation: canonicalDirectoryURL
                )
            }

            let info: LoadedModelInfo
            do {
                info = try await models.loadModel(at: canonicalDirectoryURL)
            } catch {
                guard isLikelyMemoryLoadError(error) else { throw error }
                await releaseModelsForMemoryPressure(
                    reason: displayName,
                    preservingModelID: manifest.id,
                    preservingCapability: manifest.capability,
                    preservingLocation: canonicalDirectoryURL
                )
                info = try await models.loadModel(at: canonicalDirectoryURL)
            }
            await refreshLoadedModels()
            guard loadingState?.id == sessionID else { return info }
            loadingState?.displayName = info.displayName
            loadingState?.progress = Double(safeCurrentIndex) / Double(safeTotalCount)
            if safeCurrentIndex == safeTotalCount {
                loadingState?.phase = .completed
                try? await Task.sleep(for: .milliseconds(450))
                if loadingState?.id == sessionID, loadingState?.phase == .completed {
                    loadingState = nil
                }
            }
            return info
        } catch {
            loadingState = ModelLoadingState(
                id: sessionID,
                phase: .failed,
                displayName: displayName,
                currentIndex: safeCurrentIndex,
                totalCount: safeTotalCount,
                progress: Double(safeCurrentIndex - 1) / Double(safeTotalCount),
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private func refreshLoadedModels() async {
        guard let models else { return }
        replaceLoadedModels(await models.loadedModels())
    }

    private func releaseModelsForMemoryPressure(
        reason: String,
        preservingModelID: String? = nil,
        preservingCapability: ModelCapability? = nil,
        preservingLocation: URL? = nil
    ) async {
        guard let models else { return }
        let loaded = await models.loadedModels()
        guard !loaded.isEmpty else { return }
        var releasedCount = 0
        for model in loaded {
            if let preservingModelID,
               let preservingCapability,
               let preservingLocation,
               model.matchesModel(
                   id: preservingModelID,
                   capability: preservingCapability,
                   at: preservingLocation
               ) {
                continue
            }
            await models.unloadModel(capability: model.capability)
            releasedCount += 1
        }
        guard releasedCount > 0 else { return }
        await refreshLoadedModels()
        metricsDidChange(SystemMetricsReader.read())
        log(
            .warning,
            "Released \(releasedCount) loaded model runtime(s) before loading \(reason) because RAM usage was high."
        )
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func shouldReleaseModelsBeforeLoad(modelDirectoryURL: URL) -> Bool {
        if let usage = SystemMetricsReader.read().ramUsage,
           usage >= Self.memoryPressureThreshold {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: modelDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var totalWeightBytes: UInt64 = 0
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension.lowercased() == "safetensors" {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else { continue }
            totalWeightBytes += UInt64(max(fileSize, 0))
            if totalWeightBytes >= Self.largeModelWeightThresholdBytes { return true }
        }
        return false
    }

    private func isLikelyMemoryLoadError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("memory")
            || description.contains("allocation")
            || description.contains("out of") && description.contains("resource")
            || description.contains("metal") && description.contains("buffer")
    }
}

private enum PreferredModelError: LocalizedError {
    case capabilityMismatch(expected: ModelCapability)

    var errorDescription: String? {
        switch self {
        case let .capabilityMismatch(expected):
            "所選模型類型不符，預期為 \(expected.rawValue)。"
        }
    }
}

private enum ModelLifecycleError: LocalizedError {
    case runtimeUnavailable
    case textToTextUnsupported

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "漫畫處理 Runtime 尚未就緒。"
        case .textToTextUnsupported: "目前只支援多模態模型，無法載入文生文模型。"
        }
    }
}
