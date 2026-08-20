import AppKit
import Foundation

/// 只向排字介面提供能實際涵蓋目標語言的字型，避免 WebKit 對缺字字型套用相同
/// 系統後備字型，造成使用者已切換字型但畫布外觀完全不變。
@MainActor
enum FontFamilyCatalog {
    private static var compatibleFamiliesByLanguage: [String: [String]] = [:]

    static func compatibleFamilies(for languageCode: String) -> [String] {
        let key = normalizedLanguageKey(languageCode)
        if let cached = compatibleFamiliesByLanguage[key] {
            return cached
        }

        let sample = coverageSample(for: key)
        let families = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && supports(sample, familyName: $0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        compatibleFamiliesByLanguage[key] = families
        return families
    }

    static func normalizedFontName(_ requestedFontName: String, for languageCode: String) -> String {
        let families = compatibleFamilies(for: languageCode)
        if let exact = families.first(where: {
            $0.caseInsensitiveCompare(requestedFontName) == .orderedSame
        }) {
            return exact
        }
        for preferredName in preferredFontNames(for: normalizedLanguageKey(languageCode)) {
            if let preferred = families.first(where: {
                $0.caseInsensitiveCompare(preferredName) == .orderedSame
            }) {
                return preferred
            }
        }
        return families.first ?? requestedFontName
    }

    private static func supports(_ sample: String, familyName: String) -> Bool {
        let fonts: [NSFont] = {
            if let font = NSFont(name: familyName, size: 16) {
                return [font]
            }
            return NSFontManager.shared.availableMembers(ofFontFamily: familyName)?.compactMap { member in
                guard let postScriptName = member.first as? String else { return nil }
                return NSFont(name: postScriptName, size: 16)
            } ?? []
        }()
        return fonts.contains { font in
            sample.unicodeScalars.allSatisfy(font.coveredCharacterSet.contains)
        }
    }

    private static func normalizedLanguageKey(_ languageCode: String) -> String {
        languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func coverageSample(for languageCode: String) -> String {
        if languageCode.hasPrefix("zh-hans") || languageCode.hasPrefix("zh-cn") {
            return "简体中文漫画对话，。！？"
        }
        if languageCode.hasPrefix("zh") {
            return "繁體中文漫畫對話，。！？"
        }
        if languageCode.hasPrefix("ja") {
            return "日本語漫画かなカナ。！？"
        }
        if languageCode.hasPrefix("ko") {
            return "한국어만화대화,.!?"
        }
        if languageCode.hasPrefix("ru") {
            return "Русскийтекст,.!?"
        }
        if languageCode.hasPrefix("th") {
            return "ภาษาไทย,.!?"
        }
        if languageCode.hasPrefix("vi") {
            return "TiếngViệtđầyđủ,.!?"
        }
        if languageCode.hasPrefix("fr") {
            return "Françaisœçéè,.!?"
        }
        if languageCode.hasPrefix("de") {
            return "DeutschÄÖÜß,.!?"
        }
        if languageCode.hasPrefix("es") {
            return "Españoláéíóú,.!?"
        }
        if languageCode.hasPrefix("pt") {
            return "Portuguêsãõç,.!?"
        }
        if languageCode.hasPrefix("it") {
            return "Italianoàèéìòù,.!?"
        }
        return "AaBbZz0123,.!?"
    }

    private static func preferredFontNames(for languageCode: String) -> [String] {
        if languageCode.hasPrefix("zh-hans") || languageCode.hasPrefix("zh-cn") {
            return ["PingFang SC", "Heiti SC", "Songti SC", "Kaiti SC"]
        }
        if languageCode.hasPrefix("zh") {
            return ["PingFang TC", "Heiti TC", "Songti TC", "Kaiti TC"]
        }
        if languageCode.hasPrefix("ja") {
            return ["Hiragino Sans", "Hiragino Mincho ProN"]
        }
        if languageCode.hasPrefix("ko") {
            return ["Apple SD Gothic Neo", "Nanum Gothic"]
        }
        return [NSFont.systemFont(ofSize: 16).familyName ?? "Helvetica", "Helvetica", "Arial"]
    }
}
