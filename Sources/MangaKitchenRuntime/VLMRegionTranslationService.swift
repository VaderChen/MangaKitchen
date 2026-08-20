import Foundation
import MangaKitchenCore

public actor VLMRegionTranslationService: RegionTranslating {
    private struct PromptRegion: Codable {
        var index: Int
        var id: UUID
        var sourceText: String
        var existingTranslation: String?
        var approximateCharacterLimit: Int
    }

    private struct TranslationItem: Codable {
        var id: UUID
        var literalTranslation: String?
        var displayTranslation: String?
        var translatedText: String?
        var speakerID: String?
        var tone: String?
        var confidence: Double?
        var qaFlags: [String]?

        var resolvedDisplayTranslation: String? {
            let value = displayTranslation ?? translatedText
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    private let model: any ImageToTextGenerating

    public init(model: any ImageToTextGenerating) {
        self.model = model
    }

    public func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        readingDirection: ReadingDirection,
        qualityOptions: TranslationQualityOptions,
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }

        let glossaryJSON = try Self.json(glossaryTerms)
        let promptRegions = regions.enumerated().map { index, region in
            PromptRegion(
                index: index + 1,
                id: region.id,
                sourceText: region.sourceText,
                existingTranslation: region.translatedText.isEmpty ? nil : region.translatedText,
                approximateCharacterLimit: Self.characterLimit(
                    sourceText: region.sourceText,
                    mode: qualityOptions.lengthMode
                )
            )
        }
        let promptRegionsJSON = try Self.json(promptRegions)
        let draftEnd = qualityOptions.reviewPassEnabled ? 0.55 : 0.9

        var drafts: [UUID: TranslationItem]
        if qualityOptions.usePageContext {
            // 整頁回覆偶爾只含部分 UUID。大部分結果仍可保留，只針對遺漏區域
            // 個別補翻；同時為補翻預留一小段單調遞增的進度範圍。
            let pageDraftEnd = draftEnd * 0.85
            do {
                drafts = try await generateItems(
                    pageURL: pageURL,
                    prompt: Self.draftPrompt(
                        targetLanguageCode: targetLanguageCode,
                        readingDirection: readingDirection,
                        glossaryJSON: glossaryJSON,
                        regionsJSON: promptRegionsJSON,
                        qualityOptions: qualityOptions
                    ),
                    expectedRegions: regions,
                    progress: { value in progress(value * pageDraftEnd) }
                )
                let missingRegions = regions.filter {
                    drafts[$0.id]?.resolvedDisplayTranslation == nil
                }
                if missingRegions.isEmpty {
                    progress(draftEnd)
                } else {
                    let recovered = try await generateIndividually(
                        regions: missingRegions,
                        pageURL: pageURL,
                        targetLanguageCode: targetLanguageCode,
                        glossaryJSON: glossaryJSON,
                        qualityOptions: qualityOptions,
                        regionProgress: regionProgress,
                        progress: { value in
                            progress(pageDraftEnd + value * (draftEnd - pageDraftEnd))
                        }
                    )
                    drafts.merge(recovered) { _, recoveredValue in recoveredValue }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                drafts = try await generateIndividually(
                    regions: regions,
                    pageURL: pageURL,
                    targetLanguageCode: targetLanguageCode,
                    glossaryJSON: glossaryJSON,
                    qualityOptions: qualityOptions,
                    regionProgress: regionProgress,
                    progress: { value in
                        progress(pageDraftEnd + value * (draftEnd - pageDraftEnd))
                    }
                )
            }
        } else {
            drafts = try await generateIndividually(
                regions: regions,
                pageURL: pageURL,
                targetLanguageCode: targetLanguageCode,
                glossaryJSON: glossaryJSON,
                qualityOptions: qualityOptions,
                regionProgress: regionProgress,
                progress: { value in progress(value * draftEnd) }
            )
        }
        regionProgress(0, 0)

        var reviewed = drafts
        if qualityOptions.reviewPassEnabled, !drafts.isEmpty {
            let reviewPayload = regions.compactMap { drafts[$0.id] }
            if let reviewJSON = try? Self.json(reviewPayload),
               let values = try? await generateItems(
                   pageURL: pageURL,
                   prompt: Self.reviewPrompt(
                       targetLanguageCode: targetLanguageCode,
                       readingDirection: readingDirection,
                       glossaryJSON: glossaryJSON,
                       regionsJSON: promptRegionsJSON,
                       draftsJSON: reviewJSON,
                       qualityOptions: qualityOptions
                   ),
                   expectedRegions: regions,
                   progress: { value in progress(draftEnd + value * (0.9 - draftEnd)) }
               ) {
                reviewed.merge(values) { _, new in new }
            }
        }

        var translatedRegions: [DialogueRegion] = []
        translatedRegions.reserveCapacity(regions.count)
        for region in regions {
            try Task.checkCancellation()
            var translated = region
            if let item = reviewed[region.id], let display = item.resolvedDisplayTranslation {
                let literal = item.literalTranslation?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                translated.literalTranslatedText = qualityOptions.preserveLiteralTranslation
                    ? (literal?.isEmpty == false ? literal : display)
                    : nil
                translated.translatedText = display
                translated.speakerID = Self.nonEmpty(item.speakerID)
                translated.tone = Self.nonEmpty(item.tone)
                translated.translationConfidence = item.confidence.map { min(max($0, 0), 1) }
                var flags = Set((item.qaFlags ?? []).compactMap(TranslationQAFlag.init(rawValue:)))
                if qualityOptions.reviewPassEnabled,
                   drafts[region.id]?.resolvedDisplayTranslation != display {
                    flags.insert(.reviewAdjusted)
                }
                if qualityOptions.qualityCheckEnabled {
                    flags.formUnion(Self.qualityFlags(
                        region: translated,
                        glossaryTerms: glossaryTerms,
                        lengthMode: qualityOptions.lengthMode
                    ))
                }
                translated.translationQAFlags = flags.sorted { $0.rawValue < $1.rawValue }
            } else {
                var flags = Set(translated.translationQAFlags)
                flags.insert(.missingTranslation)
                translated.translationQAFlags = flags.sorted { $0.rawValue < $1.rawValue }
            }
            translatedRegions.append(translated)
        }

        progress(1)
        return translatedRegions
    }

    private func generateIndividually(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryJSON: String,
        qualityOptions: TranslationQualityOptions,
        regionProgress: @escaping PageRegionProgress,
        progress: @escaping InferenceProgress
    ) async throws -> [UUID: TranslationItem] {
        var result: [UUID: TranslationItem] = [:]
        regionProgress(0, regions.count)
        for (index, region) in regions.enumerated() {
            try Task.checkCancellation()
            let payload = [PromptRegion(
                index: index + 1,
                id: region.id,
                sourceText: region.sourceText,
                existingTranslation: region.translatedText.isEmpty ? nil : region.translatedText,
                approximateCharacterLimit: Self.characterLimit(
                    sourceText: region.sourceText,
                    mode: qualityOptions.lengthMode
                )
            )]
            do {
                let values = try await generateItems(
                    pageURL: pageURL,
                    prompt: Self.draftPrompt(
                        targetLanguageCode: targetLanguageCode,
                        readingDirection: .topToBottom,
                        glossaryJSON: glossaryJSON,
                        regionsJSON: try Self.json(payload),
                        qualityOptions: qualityOptions
                    ),
                    expectedRegions: [region],
                    progress: { value in
                        progress((Double(index) + value) / Double(regions.count))
                    }
                )
                result.merge(values) { _, new in new }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 單區失敗時保留既有譯文，其他區域繼續。
            }
            regionProgress(index + 1, regions.count)
            progress(Double(index + 1) / Double(regions.count))
        }
        return result
    }

    private func generateItems(
        pageURL: URL,
        prompt: String,
        expectedRegions: [DialogueRegion],
        progress: @escaping InferenceProgress
    ) async throws -> [UUID: TranslationItem] {
        for attempt in 0..<VLMStructuredResponseDecoder.maximumAttempts {
            try Task.checkCancellation()
            let response = try await model.generateText(
                imageURL: pageURL,
                prompt: prompt + "\n" + VLMStructuredResponseDecoder.retryInstruction(attempt: attempt),
                maximumOutputTokens: min(16_384, max(2_048, expectedRegions.count * 384)),
                progress: { value in
                    progress(VLMStructuredResponseDecoder.mappedProgress(attempt: attempt, value: value))
                }
            )
            let expectedIDs = Set(expectedRegions.map(\.id))
            let candidates = VLMStructuredResponseDecoder.decodeArrays(TranslationItem.self, from: response)
            for candidate in candidates {
                let items = candidate.filter { expectedIDs.contains($0.id) && $0.resolvedDisplayTranslation != nil }
                guard !items.isEmpty else { continue }
                return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            }
        }
        throw TranslationRuntimeError.invalidModelResponse
    }

    private static func draftPrompt(
        targetLanguageCode: String,
        readingDirection: ReadingDirection,
        glossaryJSON: String,
        regionsJSON: String,
        qualityOptions: TranslationQualityOptions
    ) -> String {
        """
        You are producing the first translation draft for one complete comic page.
        Translate every sourceText into BCP-47 language "\(targetLanguageCode)".
        Read all regions together in index order using reading direction "\(readingDirection.rawValue)".
        Use the page image for speaker identity, relationships, gender, tone, ambiguity and visual context.
        Keep the same speakerID for the same visible speaker. Use stable descriptive IDs when names are unknown.
        literalTranslation must preserve the complete meaning. displayTranslation must sound natural and fit
        approximateCharacterLimit without dropping plot facts, names, numbers, negation or emotional intent.
        Length strategy: \(qualityOptions.lengthMode.rawValue).
        Project style guide: \(qualityOptions.styleGuide.isEmpty ? "No additional style guide." : qualityOptions.styleGuide)
        Terminology is authoritative; whenever sourceTerm occurs, use preferredTranslation exactly:
        \(glossaryJSON)
        Return only one valid JSON array with every UUID unchanged, in this exact shape:
        [{"id":"UUID","literalTranslation":"...","displayTranslation":"...","speakerID":"...","tone":"...","confidence":0.0,"qaFlags":[]}]
        confidence is 0...1. qaFlags may only contain missingTranslation, glossaryMismatch, numberMismatch,
        excessiveLength, modelUncertain or sourceTextLeak. Do not add explanations.
        Input regions:
        \(regionsJSON)
        """
    }

    private static func reviewPrompt(
        targetLanguageCode: String,
        readingDirection: ReadingDirection,
        glossaryJSON: String,
        regionsJSON: String,
        draftsJSON: String,
        qualityOptions: TranslationQualityOptions
    ) -> String {
        """
        You are the senior editor reviewing a complete comic-page translation into "\(targetLanguageCode)".
        Compare every draft against its sourceText and the page image. Review in "\(readingDirection.rawValue)"
        reading order. Correct mistranslation, omitted meaning, pronouns, negation, numbers, terminology,
        inconsistent speaker IDs, forms of address, register, tone and unnatural dialogue.
        Keep literalTranslation semantically complete. Make displayTranslation natural and concise for the balloon,
        but never shorten by deleting story information. Length strategy: \(qualityOptions.lengthMode.rawValue).
        Project style guide: \(qualityOptions.styleGuide.isEmpty ? "No additional style guide." : qualityOptions.styleGuide)
        Authoritative terminology:
        \(glossaryJSON)
        Source regions:
        \(regionsJSON)
        Drafts:
        \(draftsJSON)
        Return only the complete corrected JSON array in the same shape as the drafts. Keep every UUID.
        """
    }

    private static func qualityFlags(
        region: DialogueRegion,
        glossaryTerms: [ResolvedGlossaryTerm],
        lengthMode: TranslationLengthMode
    ) -> Set<TranslationQAFlag> {
        var flags: Set<TranslationQAFlag> = []
        let translated = region.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if translated.isEmpty { flags.insert(.missingTranslation) }
        if let confidence = region.translationConfidence, confidence < 0.65 {
            flags.insert(.modelUncertain)
        }
        for term in glossaryTerms where region.sourceText.localizedCaseInsensitiveContains(term.sourceTerm) {
            if !translated.localizedCaseInsensitiveContains(term.preferredTranslation) {
                flags.insert(.glossaryMismatch)
            }
        }
        if numberTokens(in: region.sourceText) != numberTokens(in: translated) {
            flags.insert(.numberMismatch)
        }
        let threshold: Double = switch lengthMode {
        case .faithful: 2.4
        case .balanced: 1.8
        case .compact: 1.35
        }
        if Double(translated.count) > Double(max(1, region.sourceText.count)) * threshold {
            flags.insert(.excessiveLength)
        }
        return flags
    }

    private static func numberTokens(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func characterLimit(sourceText: String, mode: TranslationLengthMode) -> Int {
        let multiplier: Double = switch mode {
        case .faithful: 2.0
        case .balanced: 1.55
        case .compact: 1.2
        }
        return max(8, Int((Double(max(1, sourceText.count)) * multiplier).rounded(.up)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum TranslationRuntimeError: LocalizedError, Sendable {
    case promptEncodingFailed
    case invalidModelResponse
    case noMatchingTranslation
    case missingTranslations(Int)

    public var errorDescription: String? {
        switch self {
        case .promptEncodingFailed: "無法建立漫畫翻譯 Prompt。"
        case .invalidModelResponse: "圖生文模型沒有回傳指定的翻譯 JSON 格式。"
        case .noMatchingTranslation: "模型回傳內容未包含任何相符的對話區域。"
        case let .missingTranslations(count): "模型缺少 \(count) 個對話區域的翻譯，未寫入不完整結果。"
        }
    }
}
