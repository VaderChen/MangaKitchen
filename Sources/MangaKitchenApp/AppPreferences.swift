import Combine
import Foundation
import MangaKitchenCore

struct AppPreferences: Codable, Equatable, Sendable {
    static let supportedInterfaceLanguages: Set<String> = ["auto", "zh-Hant", "en", "ja", "ko"]
    static let supportedColorSchemes: Set<String> = ["auto", "light", "dark"]

    var interfaceLanguage = "auto"
    var colorScheme = "auto"
    var selectionColorHex = "#5B5FEF"
    var dataDirectoryPath: String?
    var defaultOutputDirectoryPath: String?
    var imageCompositingBackend: ImageCompositingBackend? = .cpu
    var imageToTextModelPath: String?
    var imageToTextModelDownloadDirectoryPath: String?
    var imageToTextModelVariant: String?
    var translationModelPath: String?
    var translationModelDownloadDirectoryPath: String?
    var translationModelVariant: String?
    var dflashEnabled = false
    var dflashBlockSize = 5
    var agentModelPath: String?
    var agentModelDownloadDirectoryPath: String?
    var agentModelVariant: String?
    var modelThinkingEnabled = false
    var imageToImageModelPath: String?
    var imageColorizationModelPath: String?
    var imageColorizationModelDownloadDirectoryPath: String?
    var imageColorizationModelVariant: String?
    var automaticSuperResolutionEnabled = false
    var superResolutionModelPath: String?
    var superResolutionModelDownloadDirectoryPath: String?
    var superResolutionModelVariant: String?
    var mcpEnabled = false
    var mcpPort = 12_080
    var mcpAllowedClients: [String] = ["127.0.0.1"]

    private enum CodingKeys: String, CodingKey {
        case interfaceLanguage
        case colorScheme
        case selectionColorHex
        case dataDirectoryPath
        case defaultOutputDirectoryPath
        case imageCompositingBackend
        case imageToTextModelPath
        case imageToTextModelDownloadDirectoryPath
        case imageToTextModelVariant
        case translationModelPath
        case translationModelDownloadDirectoryPath
        case translationModelVariant
        case dflashEnabled
        case dflashBlockSize
        case agentModelPath
        case agentModelDownloadDirectoryPath
        case agentModelVariant
        case modelThinkingEnabled
        case imageToImageModelPath
        case imageColorizationModelPath
        case imageColorizationModelDownloadDirectoryPath
        case imageColorizationModelVariant
        case automaticSuperResolutionEnabled
        case superResolutionModelPath
        case superResolutionModelDownloadDirectoryPath
        case superResolutionModelVariant
        case mcpEnabled
        case mcpPort
        case mcpAllowedClients
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case dflashDraftModelPath
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interfaceLanguage = try values.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? "auto"
        colorScheme = try values.decodeIfPresent(String.self, forKey: .colorScheme) ?? "auto"
        selectionColorHex = try values.decodeIfPresent(String.self, forKey: .selectionColorHex) ?? "#5B5FEF"
        dataDirectoryPath = try values.decodeIfPresent(String.self, forKey: .dataDirectoryPath)
        defaultOutputDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .defaultOutputDirectoryPath
        )
        imageCompositingBackend = try values.decodeIfPresent(
            ImageCompositingBackend.self,
            forKey: .imageCompositingBackend
        ) ?? .cpu
        imageToTextModelPath = try values.decodeIfPresent(String.self, forKey: .imageToTextModelPath)
        imageToTextModelDownloadDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .imageToTextModelDownloadDirectoryPath
        )
        imageToTextModelVariant = try values.decodeIfPresent(String.self, forKey: .imageToTextModelVariant)
        translationModelPath = try values.decodeIfPresent(String.self, forKey: .translationModelPath)
        translationModelDownloadDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .translationModelDownloadDirectoryPath
        )
        translationModelVariant = try values.decodeIfPresent(String.self, forKey: .translationModelVariant)
        let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyDFlashDraftModelPath = try legacyValues.decodeIfPresent(
            String.self,
            forKey: .dflashDraftModelPath
        )
        dflashEnabled = try values.decodeIfPresent(Bool.self, forKey: .dflashEnabled)
            ?? !(legacyDFlashDraftModelPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        dflashBlockSize = try values.decodeIfPresent(Int.self, forKey: .dflashBlockSize) ?? 5
        agentModelPath = try values.decodeIfPresent(String.self, forKey: .agentModelPath)
        agentModelDownloadDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .agentModelDownloadDirectoryPath
        )
        agentModelVariant = try values.decodeIfPresent(String.self, forKey: .agentModelVariant)
        modelThinkingEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .modelThinkingEnabled
        ) ?? false
        imageToImageModelPath = try values.decodeIfPresent(String.self, forKey: .imageToImageModelPath)
        imageColorizationModelPath = try values.decodeIfPresent(
            String.self,
            forKey: .imageColorizationModelPath
        )
        imageColorizationModelDownloadDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .imageColorizationModelDownloadDirectoryPath
        )
        imageColorizationModelVariant = try values.decodeIfPresent(
            String.self,
            forKey: .imageColorizationModelVariant
        )
        automaticSuperResolutionEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .automaticSuperResolutionEnabled
        ) ?? false
        superResolutionModelPath = try values.decodeIfPresent(String.self, forKey: .superResolutionModelPath)
        superResolutionModelDownloadDirectoryPath = try values.decodeIfPresent(
            String.self,
            forKey: .superResolutionModelDownloadDirectoryPath
        )
        superResolutionModelVariant = try values.decodeIfPresent(
            String.self,
            forKey: .superResolutionModelVariant
        )
        mcpEnabled = try values.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
        mcpPort = try values.decodeIfPresent(Int.self, forKey: .mcpPort) ?? 12_080
        mcpAllowedClients = try values.decodeIfPresent([String].self, forKey: .mcpAllowedClients)
            ?? ["127.0.0.1"]
    }

    mutating func normalize() {
        if !Self.supportedInterfaceLanguages.contains(interfaceLanguage) {
            interfaceLanguage = "auto"
        }
        if !Self.supportedColorSchemes.contains(colorScheme) {
            colorScheme = "auto"
        }
        selectionColorHex = DialogueStyle.normalizedHexColor(selectionColorHex, fallback: "#5B5FEF")
        dataDirectoryPath = Self.normalizedOptionalPath(dataDirectoryPath)
        defaultOutputDirectoryPath = Self.normalizedOptionalPath(defaultOutputDirectoryPath)
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
            ), DownloadableModelCatalog.isCompleteModelDirectory(storageURL, model: directlySelectedModel) {
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
        translationModelPath = Self.normalizedOptionalPath(translationModelPath)
        translationModelDownloadDirectoryPath = Self.normalizedOptionalPath(
            translationModelDownloadDirectoryPath
        )
        let selectedTranslationModel = translationModelVariant.flatMap {
            DownloadableModelCatalog.translationModel(id: $0)
        } ?? DownloadableModelCatalog.defaultTranslationModel
        translationModelVariant = selectedTranslationModel.id
        if translationModelDownloadDirectoryPath == nil,
           let translationModelPath {
            let modelURL = URL(fileURLWithPath: translationModelPath).standardizedFileURL
            if let matchedModel = DownloadableModelCatalog.translationModel(matching: modelURL) {
                translationModelDownloadDirectoryPath = modelURL.deletingLastPathComponent().path
                translationModelVariant = matchedModel.id
            }
        }
        if let translationModelDownloadDirectoryPath {
            var storageURL = URL(fileURLWithPath: translationModelDownloadDirectoryPath)
                .standardizedFileURL
            if let directlySelectedModel = DownloadableModelCatalog.translationModel(matching: storageURL),
               DownloadableModelCatalog.isCompleteModelDirectory(
                   storageURL,
                   model: directlySelectedModel
               ) {
                storageURL.deleteLastPathComponent()
                self.translationModelDownloadDirectoryPath = storageURL.path
                translationModelVariant = directlySelectedModel.id
            }
            let resolvedModel = DownloadableModelCatalog.translationModel(
                id: translationModelVariant ?? selectedTranslationModel.id
            ) ?? selectedTranslationModel
            translationModelPath = DownloadableModelCatalog.installedModelDirectory(
                storageDirectoryURL: storageURL,
                model: resolvedModel
            )?.path
        }
        dflashBlockSize = min(max(dflashBlockSize, 2), 256)
        agentModelPath = Self.normalizedOptionalPath(agentModelPath)
        agentModelDownloadDirectoryPath = Self.normalizedOptionalPath(agentModelDownloadDirectoryPath)
        let selectedAgentModel = agentModelVariant.flatMap {
            DownloadableModelCatalog.agentModel(id: $0)
        } ?? DownloadableModelCatalog.defaultAgentModel
        agentModelVariant = selectedAgentModel.id
        if agentModelDownloadDirectoryPath == nil,
           let agentModelPath {
            let modelURL = URL(fileURLWithPath: agentModelPath).standardizedFileURL
            if let matchedModel = DownloadableModelCatalog.agentModel(matching: modelURL) {
                agentModelDownloadDirectoryPath = modelURL.deletingLastPathComponent().path
                agentModelVariant = matchedModel.id
            }
        }
        if let agentModelDownloadDirectoryPath {
            var storageURL = URL(fileURLWithPath: agentModelDownloadDirectoryPath)
                .standardizedFileURL
            if let directlySelectedModel = DownloadableModelCatalog.agentModel(matching: storageURL),
               DownloadableModelCatalog.isCompleteModelDirectory(
                storageURL,
                model: directlySelectedModel
            ) {
                storageURL.deleteLastPathComponent()
                self.agentModelDownloadDirectoryPath = storageURL.path
                agentModelVariant = directlySelectedModel.id
            }
            let resolvedModel = DownloadableModelCatalog.agentModel(
                id: agentModelVariant ?? selectedAgentModel.id
            ) ?? selectedAgentModel
            agentModelPath = DownloadableModelCatalog.installedModelDirectory(
                storageDirectoryURL: storageURL,
                model: resolvedModel
            )?.path
        }
        imageToImageModelPath = Self.normalizedOptionalPath(imageToImageModelPath)
        imageColorizationModelPath = Self.normalizedOptionalPath(imageColorizationModelPath)
        imageColorizationModelDownloadDirectoryPath = Self.normalizedOptionalPath(
            imageColorizationModelDownloadDirectoryPath
        )
        let selectedImageColorizationModel = imageColorizationModelVariant.flatMap {
            DownloadableModelCatalog.model(id: $0, capability: .imageColorization)
        } ?? DownloadableModelCatalog.defaultImageColorizationModel
        imageColorizationModelVariant = selectedImageColorizationModel.id
        if let imageColorizationModelDownloadDirectoryPath {
            let storageURL = URL(fileURLWithPath: imageColorizationModelDownloadDirectoryPath)
                .standardizedFileURL
            imageColorizationModelPath = DownloadableModelCatalog.installedModelDirectory(
                storageDirectoryURL: storageURL,
                model: selectedImageColorizationModel
            )?.path
        }
        superResolutionModelPath = Self.normalizedOptionalPath(superResolutionModelPath)
        superResolutionModelDownloadDirectoryPath = Self.normalizedOptionalPath(
            superResolutionModelDownloadDirectoryPath
        )
        let selectedSuperResolutionModel = superResolutionModelVariant.flatMap {
            DownloadableModelCatalog.model(id: $0, capability: .superResolution)
        } ?? DownloadableModelCatalog.defaultSuperResolutionModel
        superResolutionModelVariant = selectedSuperResolutionModel.id
        if let superResolutionModelDownloadDirectoryPath {
            let storageURL = URL(fileURLWithPath: superResolutionModelDownloadDirectoryPath)
                .standardizedFileURL
            superResolutionModelPath = DownloadableModelCatalog.installedModelDirectory(
                storageDirectoryURL: storageURL,
                model: selectedSuperResolutionModel
            )?.path
        }
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

    var resolvedAgentModelVariant: String {
        DownloadableModelCatalog.agentModel(id: agentModelVariant ?? "")?.id
            ?? DownloadableModelCatalog.defaultAgentModel.id
    }

    var resolvedTranslationModelVariant: String {
        DownloadableModelCatalog.translationModel(id: translationModelVariant ?? "")?.id
            ?? DownloadableModelCatalog.defaultTranslationModel.id
    }

    var resolvedSuperResolutionModelVariant: String {
        DownloadableModelCatalog.model(
            id: superResolutionModelVariant ?? "",
            capability: .superResolution
        )?.id ?? DownloadableModelCatalog.defaultSuperResolutionModel.id
    }

    var resolvedImageColorizationModelVariant: String {
        DownloadableModelCatalog.model(
            id: imageColorizationModelVariant ?? "",
            capability: .imageColorization
        )?.id ?? DownloadableModelCatalog.defaultImageColorizationModel.id
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
