import Combine
import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    static let supportedInterfaceLanguages: Set<String> = ["auto", "zh-Hant", "en", "ja", "ko"]
    static let supportedColorSchemes: Set<String> = ["auto", "light", "dark"]

    var interfaceLanguage = "auto"
    var colorScheme = "auto"
    var dataDirectoryPath: String?
    var imageToTextModelPath: String?
    var imageToImageModelPath: String?
    var mcpEnabled = false
    var mcpPort = 12_080
    var mcpAllowedClients: [String] = ["127.0.0.1"]

    mutating func normalize() {
        if !Self.supportedInterfaceLanguages.contains(interfaceLanguage) {
            interfaceLanguage = "auto"
        }
        if !Self.supportedColorSchemes.contains(colorScheme) {
            colorScheme = "auto"
        }
        dataDirectoryPath = Self.normalizedOptionalPath(dataDirectoryPath)
        imageToTextModelPath = Self.normalizedOptionalPath(imageToTextModelPath)
        imageToImageModelPath = Self.normalizedOptionalPath(imageToImageModelPath)
        if !(1...65_535).contains(mcpPort) {
            mcpPort = 12_080
        }
        mcpAllowedClients = MCPClientAllowlist.normalizedEntries(mcpAllowedClients)
    }

    private static func normalizedOptionalPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

@MainActor
final class AppPreferencesController: ObservableObject {
    @Published private(set) var settings: AppPreferences

    private static let storageKey = "MangaKitchen.AppPreferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           var decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            decoded.normalize()
            settings = decoded
        } else {
            settings = AppPreferences()
        }
    }

    func replace(with value: AppPreferences) {
        var normalized = value
        normalized.normalize()
        guard normalized != settings else { return }
        settings = normalized
        persist()
    }

    func setInterfaceLanguage(_ value: String) {
        var updated = settings
        updated.interfaceLanguage = value
        replace(with: updated)
    }

    func setMCPEnabled(_ enabled: Bool) {
        var updated = settings
        updated.mcpEnabled = enabled
        replace(with: updated)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
