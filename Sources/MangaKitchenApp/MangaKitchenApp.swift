import AppKit
import Combine
import SwiftUI

@MainActor
private final class MangaKitchenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reopenMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "MangaKitchen.AppPreferences.v1"),
              let settings = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return true
        }
        return !settings.mcpEnabled
    }
}

@main
@MainActor
private struct MangaKitchenApplication: App {
    @NSApplicationDelegateAdaptor(MangaKitchenAppDelegate.self) private var appDelegate
    @StateObject private var preferences: AppPreferencesController
    @StateObject private var bridge: HybridBridgeController
    @StateObject private var mcpController: MCPServiceController

    private let launchConfiguration: MangaKitchenLaunchConfiguration

    init() {
        let configuration: MangaKitchenLaunchConfiguration
        let launchError: String?
        do {
            configuration = try MangaKitchenLaunchConfiguration(arguments: CommandLine.arguments)
            launchError = nil
        } catch {
            configuration = .fallback
            launchError = error.localizedDescription
        }
        launchConfiguration = configuration
        let preferences = AppPreferencesController()
        if let enabled = configuration.mcpEnabled {
            preferences.setMCPEnabled(enabled)
        }
        let settings = preferences.settings
        let store = AppStore(
            dataDirectoryPath: settings.dataDirectoryPath,
            defaultOutputDirectoryPath: settings.defaultOutputDirectoryPath,
            imageCompositingBackend: settings.resolvedImageCompositingBackend,
            textToTextModelPath: settings.textToTextModelPath,
            imageToTextModelPath: settings.imageToTextModelPath,
            modelThinkingEnabled: settings.modelThinkingEnabled,
            imageToImageModelPath: settings.imageToImageModelPath,
            automaticSuperResolutionEnabled: settings.automaticSuperResolutionEnabled,
            superResolutionModelPath: settings.superResolutionModelPath
        )
        let mcpController = MCPServiceController(
            enabled: settings.mcpEnabled,
            port: configuration.mcpPort ?? settings.mcpPort,
            portOverride: configuration.mcpPort,
            allowedClients: settings.mcpAllowedClients,
            dataDirectoryPath: settings.dataDirectoryPath,
            imageCompositingBackend: settings.resolvedImageCompositingBackend,
            store: store
        )
        _preferences = StateObject(wrappedValue: preferences)
        _bridge = StateObject(
            wrappedValue: HybridBridgeController(
                preferences: preferences,
                mcpController: mcpController,
                store: store
            )
        )
        _mcpController = StateObject(wrappedValue: mcpController)
        if let launchError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NativeLocalization.text(
                    "launchArgumentError",
                    languageCode: NativeLocalization.automaticLanguageCode
                )
                alert.informativeText = launchError
                alert.runModal()
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            HybridWebView(controller: bridge)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    mcpController.start()
                }
                .onReceive(preferences.$settings.dropFirst()) { settings in
                    mcpController.configure(
                        enabled: settings.mcpEnabled,
                        port: settings.mcpPort,
                        allowedClients: settings.mcpAllowedClients,
                        imageCompositingBackend: settings.resolvedImageCompositingBackend
                    )
                }
        }
        .defaultSize(width: 1_280, height: 800)

        MenuBarExtra(
            NativeLocalization.text(
                "mcpMenuTitle",
                languageCode: bridge.interfaceLanguageCode
            ),
            systemImage: "bubble.left.and.bubble.right",
            isInserted: Binding(
                get: { mcpController.enabled },
                set: { preferences.setMCPEnabled($0) }
            )
        ) {
            MCPStatusMenu(
                controller: mcpController,
                languageCode: bridge.interfaceLanguageCode
            )
        }
    }
}

@MainActor
private struct MCPStatusMenu: View {
    @ObservedObject var controller: MCPServiceController
    let languageCode: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusText(languageCode: languageCode))

        if let endpointURL = controller.endpointURL {
            Text(endpointURL.absoluteString)
                .font(.caption)
            Button(NativeLocalization.text("copyEndpoint", languageCode: languageCode)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpointURL.absoluteString, forType: .string)
            }
        }

        Divider()

        Button(NativeLocalization.text("openApp", languageCode: languageCode)) {
            openWindow(id: "main")
            reopenMainWindow()
        }

        Button(NativeLocalization.text("quitApp", languageCode: languageCode)) {
            Task {
                await controller.stop()
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
private func reopenMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}

private struct MangaKitchenLaunchConfiguration {
    static let fallback = MangaKitchenLaunchConfiguration(mcpEnabled: nil, mcpPort: nil)

    var mcpEnabled: Bool? = nil
    var mcpPort: Int?

    private init(mcpEnabled: Bool?, mcpPort: Int?) {
        self.mcpEnabled = mcpEnabled
        self.mcpPort = mcpPort
    }

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--mcp" {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    mcpEnabled = try Self.boolean(arguments[index + 1])
                    index += 1
                } else {
                    mcpEnabled = true
                }
            } else if argument.hasPrefix("--mcp=") {
                mcpEnabled = try Self.boolean(String(argument.dropFirst("--mcp=".count)))
            } else if argument == "--mcp-port" {
                guard index + 1 < arguments.count else {
                    throw MangaKitchenLaunchError.missingMCPPort
                }
                mcpPort = try Self.port(arguments[index + 1])
                index += 1
            } else if argument.hasPrefix("--mcp-port=") {
                mcpPort = try Self.port(String(argument.dropFirst("--mcp-port=".count)))
            }
            index += 1
        }
    }

    private static func boolean(_ rawValue: String) throws -> Bool {
        switch rawValue.lowercased() {
        case "on", "true", "1", "yes": true
        case "off", "false", "0", "no": false
        default: throw MangaKitchenLaunchError.invalidMCPValue(rawValue)
        }
    }

    private static func port(_ rawValue: String) throws -> Int {
        guard let value = Int(rawValue), (1...65_535).contains(value) else {
            throw MangaKitchenLaunchError.invalidMCPPort(rawValue)
        }
        return value
    }
}

private enum MangaKitchenLaunchError: LocalizedError {
    case invalidMCPValue(String)
    case invalidMCPPort(String)
    case missingMCPPort

    var errorDescription: String? {
        switch self {
        case let .invalidMCPValue(value):
            "--mcp 僅接受 on 或 off，目前收到：\(value)"
        case let .invalidMCPPort(value):
            "--mcp-port 必須是 1 至 65535，目前收到：\(value)"
        case .missingMCPPort:
            "--mcp-port 後方缺少連接埠號碼"
        }
    }
}
