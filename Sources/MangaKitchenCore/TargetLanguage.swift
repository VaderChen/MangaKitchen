import Foundation

/// 將 UI 的 AUTO 目標語言解析成翻譯模型使用的 BCP-47 語言代碼。
///
/// AUTO 保留在 ProcessingOptions 內，不把當下的系統語言寫死，讓使用者未手動
/// 選擇目標語言時，系統語言變更後下一次處理也能跟著變更。
public enum TargetLanguageResolver {
    public static let automaticCode = "auto"

    public static func resolve(
        _ code: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.caseInsensitiveCompare(automaticCode) == .orderedSame else {
            return trimmed
        }

        let preferred = preferredLanguages.first ?? Locale.current.identifier
        let normalizedIdentifier = preferred.replacingOccurrences(of: "_", with: "-")
        let components = normalizedIdentifier.split(separator: "-").map(String.init)
        let explicitLanguage = components.first?.lowercased()

        // 不使用 Locale 對中文 script 的「推導值」。Foundation 會把只有 `zh`
        // 的識別碼自動補成 Hans，這並不代表使用者明確選擇了簡體。
        // 只有明確 Hans／CN／SG 才回簡體；資訊不足時保守回繁體。
        if explicitLanguage == "zh" {
            let subtags = components.dropFirst().map { $0.lowercased() }
            if subtags.contains("hans") || subtags.contains("chs") {
                return "zh-Hans"
            }
            if subtags.contains("hant") || subtags.contains("cht") {
                return "zh-Hant"
            }
            let region = components.dropFirst().first { component in
                (component.count == 2 && component.allSatisfy(\.isLetter))
                    || (component.count == 3 && component.allSatisfy(\.isNumber))
            }?.uppercased()
            if ["CN", "SG"].contains(region) {
                return "zh-Hans"
            }
            return "zh-Hant"
        }

        let locale = Locale(identifier: normalizedIdentifier)
        let language = locale.language.languageCode?.identifier.lowercased() ?? "en"

        switch language {
        case "ja": return "ja-JP"
        case "en": return "en-US"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        case "id": return "id-ID"
        default: return "en-US"
        }
    }
}
