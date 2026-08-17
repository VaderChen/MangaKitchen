import Combine
import Foundation
import MangaKitchenCore

struct AppPreferences: Codable, Equatable, Sendable {
    static let supportedInterfaceLanguages: Set<String> = ["auto", "zh-Hant", "en", "ja", "ko"]
    static let supportedColorSchemes: Set<String> = ["auto", "light", "dark"]

    var interfaceLanguage = "auto"
    var colorScheme = "auto"
    var dataDirectoryPath: String?
    var imageCompositingBackend: ImageCompositingBackend? = .cpu
    var imageToTextModelPath: String?
    var imageToTextModelDownloadDirectoryPath: String?
    var imageToTextModelVariant: String?
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
        imageCompositingBackend = imageCompositingBackend ?? .cpu
        imageToTextModelPath = Self.normalizedOptionalPath(imageToTextModelPath)
        imageToTextModelDownloadDirectoryPath = Self.normalizedOptionalPath(
            imageToTextModelDownloadDirectoryPath
        )
        let selectedModel = imageToTextModelVariant.flatMap {
            DownloadableModelCatalog.model(id: $0, capability: .imageToText)
        } ?? DownloadableModelCatalog.defaultImageToTextModel
        imageToTextModelVariant = selectedModel.id
        if imageToTextModelDownloadDirectoryPath == nil,
           let imageToTextModelPath {
            let modelURL = URL(fileURLWithPath: imageToTextModelPath).standardizedFileURL
            if let matchedModel = DownloadableModelCatalog.model(
                matching: modelURL,
                capability: .imageToText
            ) {
                imageToTextModelDownloadDirectoryPath = modelURL.deletingLastPathComponent().path
                imageToTextModelVariant = matchedModel.id
            }
        }
        if let imageToTextModelDownloadDirectoryPath,
           let model = DownloadableModelCatalog.model(
            id: imageToTextModelVariant ?? "",
            capability: .imageToText
           ) {
            var storageURL = URL(fileURLWithPath: imageToTextModelDownloadDirectoryPath)
                .standardizedFileURL
            if let directlySelectedModel = DownloadableModelCatalog.model(
                matching: storageURL,
                capability: .imageToText
            ), DownloadableModelCatalog.isCompleteModelDirectory(storageURL) {
                storageURL.deleteLastPathComponent()
                self.imageToTextModelDownloadDirectoryPath = storageURL.path
                imageToTextModelVariant = directlySelectedModel.id
            }
            let resolvedModel = DownloadableModelCatalog.model(
                id: imageToTextModelVariant ?? model.id,
                capability: .imageToText
            ) ?? model
            imageToTextModelPath = DownloadableModelCatalog.installedModelDirectory(
                storageDirectoryURL: storageURL,
                model: resolvedModel
            )?.path
        }
        imageToImageModelPath = Self.normalizedOptionalPath(imageToImageModelPath)
        if !(1...65_535).contains(mcpPort) {
            mcpPort = 12_080
        }
        mcpAllowedClients = MCPClientAllowlist.normalizedEntries(mcpAllowedClients)
    }

    var resolvedImageCompositingBackend: ImageCompositingBackend {
        imageCompositingBackend ?? .cpu
    }

    var resolvedImageToTextModelVariant: String {
        DownloadableModelCatalog.model(
            id: imageToTextModelVariant ?? "",
            capability: .imageToText
        )?.id ?? DownloadableModelCatalog.defaultImageToTextModel.id
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
