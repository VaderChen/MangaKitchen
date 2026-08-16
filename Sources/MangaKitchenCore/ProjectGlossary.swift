import Foundation

/// 一個專有名詞概念：原文固定一個，譯詞以 BCP-47 語言代碼保存多個版本。
public struct GlossaryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceTerm: String
    public var translations: [String: String]
    public var note: String?

    public init(
        id: UUID = UUID(),
        sourceTerm: String,
        translations: [String: String] = [:],
        note: String? = nil
    ) {
        self.id = id
        self.sourceTerm = sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translations = Self.normalizedTranslations(translations)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmedNote?.isEmpty == false ? trimmedNote : nil
    }

    public func translation(for targetLanguageCode: String) -> String? {
        guard let normalized = ProjectGlossary.normalizedLanguageCode(targetLanguageCode) else {
            return nil
        }
        if let exact = translations.first(where: {
            $0.key.caseInsensitiveCompare(normalized) == .orderedSame
        })?.value, !exact.isEmpty {
            return exact
        }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return translations.first(where: {
            $0.key.caseInsensitiveCompare(base) == .orderedSame
        })?.value
    }

    private static func normalizedTranslations(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (languageCode, value) in values {
            guard let code = ProjectGlossary.normalizedLanguageCode(languageCode) else { continue }
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            result[code] = term
        }
        return result
    }
}

/// 實際交給翻譯器的單一目標語言詞條。
public struct ResolvedGlossaryTerm: Codable, Hashable, Sendable {
    public var sourceTerm: String
    public var preferredTranslation: String
    public var note: String?

    public init(sourceTerm: String, preferredTranslation: String, note: String? = nil) {
        self.sourceTerm = sourceTerm
        self.preferredTranslation = preferredTranslation
        self.note = note
    }
}

public struct ProjectGlossary: Codable, Hashable, Sendable {
    public var entries: [GlossaryEntry]

    public init(entries: [GlossaryEntry] = []) {
        self.entries = entries
    }

    /// 同一原詞視為同一詞條；更新時保留既有 ID 並合併多語譯詞。
    @discardableResult
    public mutating func upsert(_ entry: GlossaryEntry) -> UUID {
        let sourceTerm = entry.sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var value = entry
            value.id = entries[index].id
            for duplicate in entries where duplicate.id != value.id
                && duplicate.sourceTerm.localizedCaseInsensitiveCompare(sourceTerm) == .orderedSame {
                var merged = duplicate.translations
                merged.merge(value.translations) { _, new in new }
                value.translations = merged
                if value.note == nil { value.note = duplicate.note }
            }
            entries.removeAll {
                $0.id != value.id
                    && $0.sourceTerm.localizedCaseInsensitiveCompare(sourceTerm) == .orderedSame
            }
            if let retainedIndex = entries.firstIndex(where: { $0.id == value.id }) {
                entries[retainedIndex] = value
            }
            sortEntries()
            return value.id
        }
        if let index = entries.firstIndex(where: {
            $0.sourceTerm.localizedCaseInsensitiveCompare(sourceTerm) == .orderedSame
        }) {
            var value = entries[index]
            value.translations.merge(entry.translations) { _, new in new }
            if let note = entry.note { value.note = note }
            entries[index] = value
            sortEntries()
            return value.id
        }
        entries.append(entry)
        sortEntries()
        return entry.id
    }

    public mutating func remove(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
    }

    /// 只回傳目標語言有對照，而且本頁 OCR 文字確實出現的詞條。
    public func resolvedTerms(
        for targetLanguageCode: String,
        sourceTexts: [String]
    ) -> [ResolvedGlossaryTerm] {
        entries.compactMap { entry in
            guard !entry.sourceTerm.isEmpty,
                  sourceTexts.contains(where: {
                      $0.range(
                          of: entry.sourceTerm,
                          options: [.caseInsensitive, .diacriticInsensitive]
                      ) != nil
                  }),
                  let translation = entry.translation(for: targetLanguageCode) else {
                return nil
            }
            return ResolvedGlossaryTerm(
                sourceTerm: entry.sourceTerm,
                preferredTranslation: translation,
                note: entry.note
            )
        }
    }

    /// 將一般輸入正規化成穩定的 BCP-47 鍵值，例如 zh_hant → zh-Hant。
    public static func normalizedLanguageCode(_ rawValue: String) -> String? {
        let rawParts = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard !rawParts.isEmpty,
              rawParts.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber }
              }) else {
            return nil
        }
        return rawParts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4, part.allSatisfy(\.isLetter) {
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            if part.count == 2, part.allSatisfy(\.isLetter) { return part.uppercased() }
            return part.lowercased()
        }.joined(separator: "-")
    }

    private mutating func sortEntries() {
        entries.sort { $0.sourceTerm.localizedStandardCompare($1.sourceTerm) == .orderedAscending }
    }
}
