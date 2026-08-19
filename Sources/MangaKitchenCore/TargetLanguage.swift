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
        let locale = Locale(identifier: preferred.replacingOccurrences(of: "_", with: "-"))
        let language = locale.language.languageCode?.identifier.lowercased() ?? "en"
        let region = locale.region?.identifier.uppercased()
        let script = locale.language.script?.identifier.lowercased()

        switch language {
        case "zh":
            if script == "hans" || ["CN", "SG"].contains(region) {
                return "zh-Hans"
            }
            return "zh-Hant"
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
