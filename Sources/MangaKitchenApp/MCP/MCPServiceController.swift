import Foundation

@MainActor
final class MCPServiceController: ObservableObject {
    enum ServiceState: Equatable {
        case disabled
        case starting
        case running(URL)
        case stopping
        case failed(String)
    }

    @Published private(set) var state: ServiceState

    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int

    private var host: MangaKitchenMCPHTTPHost?
    private var serviceTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var allowedClients: [String]
    private let portOverride: Int?
    private let dataDirectoryPath: String?

    init(
        enabled: Bool,
        port: Int,
        portOverride: Int?,
        allowedClients: [String],
        dataDirectoryPath: String?
    ) {
        self.enabled = enabled
        self.port = port
        self.portOverride = portOverride
        self.allowedClients = allowedClients
        self.dataDirectoryPath = dataDirectoryPath
        state = enabled ? .starting : .disabled
    }

    func configure(enabled: Bool, port: Int, allowedClients: [String]) {
        let effectivePort = portOverride ?? port
        let normalizedClients = MCPClientAllowlist.normalizedEntries(allowedClients)
        guard enabled != self.enabled
                || effectivePort != self.port
                || normalizedClients != self.allowedClients else { return }
        self.enabled = enabled
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            guard let self else { return }
            await self.stop()
            guard !Task.isCancelled else { return }
            self.port = effectivePort
            self.allowedClients = normalizedClients
            if enabled { self.start() }
            self.configurationTask = nil
        }
    }

    func statusText(languageCode: String) -> String {
        switch state {
        case .disabled:
            NativeLocalization.text("mcpDisabled", languageCode: languageCode)
        case .starting:
            NativeLocalization.text("mcpStarting", languageCode: languageCode)
        case .running:
            NativeLocalization.text("mcpRunning", languageCode: languageCode)
        case .stopping:
            NativeLocalization.text("mcpStopping", languageCode: languageCode)
        case let .failed(message):
            NativeLocalization.text("mcpFailed", languageCode: languageCode) + message
        }
    }

    var endpointURL: URL? {
        guard case let .running(url) = state else { return nil }
        return url
    }

    func start() {
        guard enabled, serviceTask == nil else { return }
        state = .starting
        serviceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let host = try MangaKitchenMCPServer.makeHTTPHost(
                    port: port,
                    allowedClients: allowedClients,
                    dataDirectoryPath: dataDirectoryPath
                )
                self.host = host
                try await host.run { [weak self] endpointURL in
                    Task { @MainActor in
                        self?.state = .running(endpointURL)
                    }
                }
                self.host = nil
                if !Task.isCancelled {
                    state = .disabled
                }
            } catch is CancellationError {
                self.host = nil
                state = .disabled
            } catch {
                self.host = nil
                state = .failed(error.localizedDescription)
            }
            serviceTask = nil
        }
    }

    func stop() async {
        guard let serviceTask else {
            state = .disabled
            return
        }
        state = .stopping
        await host?.stop()
        serviceTask.cancel()
        _ = await serviceTask.result
        self.serviceTask = nil
        host = nil
        state = .disabled
    }
}
