import Foundation
import MangaKitchenCore

/// 讓既有的整頁翻譯服務可複用純文字模型。`imageURL` 只是舊協定的
/// 相容參數，純文字 runtime 不會讀取圖片。
public actor TextOnlyImageToTextAdapter: ImageToTextGenerating {
    private let model: any TextGenerating

    public init(model: any TextGenerating) {
        self.model = model
    }

    public func generateText(
        imageURL _: URL,
        prompt: String,
        maximumOutputTokens: Int?,
        progress: @escaping InferenceProgress
    ) async throws -> String {
        try await model.generateText(
            prompt: prompt,
            maximumOutputTokens: maximumOutputTokens,
            progress: progress
        )
    }
}

public actor VLMRegionTranslationService: DraftRegionTranslating {
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
    private let usesImageContext: Bool
    private let log: RuntimeLogHandler

    public init(
        model: any ImageToTextGenerating,
        usesImageContext: Bool = true,
        log: @escaping RuntimeLogHandler = { _, _, _ in }
    ) {
        self.model = model
        self.usesImageContext = usesImageContext
        self.log = log
    }

    public func translate(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        readingDirection: ReadingDirection,
        qualityOptions: TranslationQualityOptions,
        activity: @escaping PagePipelineActivity = { _ in },
        regionProgress: @escaping PageRegionProgress,
        draftsReady: @escaping TranslationDraftHandler,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        guard !regions.isEmpty else {
            progress(1)
            return []
        }

        log(
            .info,
            "Translation",
            "Starting \(usesImageContext ? "image-to-text" : "text-to-text") translation for \(regions.count) region(s) into \(targetLanguageCode)."
        )

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
        activity(.translatingRegions)
        regionProgress(0, regions.count)

        var drafts: [UUID: TranslationItem]
        if qualityOptions.usePageContext {
            // 整頁回覆偶爾只含部分 UUID。保留已成功的結果，缺漏部分最多再
            // 送出一次批次補翻；不得逐區各自多次 retry，否則 UI 會反覆從
            // 第 1 區開始，看起來像同一頁被翻譯很多次。
            let pageDraftEnd = draftEnd * 0.85
            var pageDraftSucceeded = false
            do {
                drafts = try await generateItems(
                    pageURL: pageURL,
                    prompt: Self.draftPrompt(
                        targetLanguageCode: targetLanguageCode,
                        readingDirection: readingDirection,
                        glossaryJSON: glossaryJSON,
                        regionsJSON: promptRegionsJSON,
                        qualityOptions: qualityOptions,
                        usesImageContext: usesImageContext
                    ),
                    expectedRegions: regions,
                    regionProgress: regionProgress,
                    progress: { value in progress(value * pageDraftEnd) }
                )
                pageDraftSucceeded = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(
                    .warning,
                    "Translation",
                    "Page translation failed; running one bounded batch recovery: \(error.localizedDescription)"
                )
                drafts = try await generateRecoveryBatch(
                    regions: regions,
                    pageURL: pageURL,
                    targetLanguageCode: targetLanguageCode,
                    glossaryJSON: glossaryJSON,
                    readingDirection: readingDirection,
                    qualityOptions: qualityOptions,
                    progress: { value in
                        progress(pageDraftEnd + value * (draftEnd - pageDraftEnd))
                    }
                )
            }
            if pageDraftSucceeded {
                let missingRegions = regions.filter {
                    drafts[$0.id]?.resolvedDisplayTranslation == nil
                }
                if missingRegions.isEmpty {
                    progress(draftEnd)
                } else {
                    log(
                        .warning,
                        "Translation",
                        "Page response omitted \(missingRegions.count) region(s); running one bounded batch recovery."
                    )
                    let recovered = try await generateRecoveryBatch(
                        regions: missingRegions,
                        pageURL: pageURL,
                        targetLanguageCode: targetLanguageCode,
                        glossaryJSON: glossaryJSON,
                        readingDirection: readingDirection,
                        qualityOptions: qualityOptions,
                        progress: { value in
                            progress(pageDraftEnd + value * (draftEnd - pageDraftEnd))
                        }
                    )
                    drafts.merge(recovered) { _, recoveredValue in recoveredValue }
                }
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
        var reviewed = drafts
        if qualityOptions.reviewPassEnabled, !drafts.isEmpty {
            let draftRegions = regions.map { region in
                Self.applyingTranslation(
                    drafts[region.id],
                    draft: nil,
                    to: region,
                    targetLanguageCode: targetLanguageCode,
                    glossaryTerms: glossaryTerms,
                    qualityOptions: qualityOptions,
                    detectsReviewAdjustment: false
                )
            }
            try await draftsReady(draftRegions)
            try Task.checkCancellation()
            log(.info, "Translation", "Starting second-pass review for \(drafts.count) draft(s).")
            activity(.reviewingTranslations)
            // 校稿是單次整頁編輯，不是逐區 OCR／重翻；清除區域計數，UI 只顯示整頁階段。
            regionProgress(0, 0)
            let reviewPayload = regions.compactMap { drafts[$0.id] }
            do {
                let reviewJSON = try Self.json(reviewPayload)
                let values = try await generateItems(
                    pageURL: pageURL,
                    prompt: Self.reviewPrompt(
                        targetLanguageCode: targetLanguageCode,
                        readingDirection: readingDirection,
                        glossaryJSON: glossaryJSON,
                        regionsJSON: promptRegionsJSON,
                        draftsJSON: reviewJSON,
                        qualityOptions: qualityOptions,
                        usesImageContext: usesImageContext
                    ),
                    expectedRegions: regions,
                    progress: { value in progress(draftEnd + value * (0.9 - draftEnd)) }
                )
                reviewed.merge(values) { _, new in new }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(
                    .warning,
                    "Translation",
                    "Second-pass review failed; keeping committed drafts: \(error.localizedDescription)"
                )
            }
        }
        regionProgress(0, 0)

        var translatedRegions: [DialogueRegion] = []
        translatedRegions.reserveCapacity(regions.count)
        for region in regions {
            try Task.checkCancellation()
            translatedRegions.append(Self.applyingTranslation(
                reviewed[region.id],
                draft: drafts[region.id],
                to: region,
                targetLanguageCode: targetLanguageCode,
                glossaryTerms: glossaryTerms,
                qualityOptions: qualityOptions,
                detectsReviewAdjustment: qualityOptions.reviewPassEnabled
            ))
        }

        progress(1)
        return translatedRegions
    }

    private static func applyingTranslation(
        _ item: TranslationItem?,
        draft: TranslationItem?,
        to region: DialogueRegion,
        targetLanguageCode: String,
        glossaryTerms: [ResolvedGlossaryTerm],
        qualityOptions: TranslationQualityOptions,
        detectsReviewAdjustment: Bool
    ) -> DialogueRegion {
        var translated = region
        guard let item, let rawDisplay = item.resolvedDisplayTranslation else {
            var flags = Set(translated.translationQAFlags)
            flags.insert(.missingTranslation)
            translated.translationQAFlags = flags.sorted { $0.rawValue < $1.rawValue }
            return translated
        }
        let display = normalizedTranslation(
            removingEditorialAnnotations(rawDisplay),
            targetLanguageCode: targetLanguageCode
        )
        let literal = item.literalTranslation.map {
            normalizedTranslation(
                removingEditorialAnnotations($0),
                targetLanguageCode: targetLanguageCode
            )
        }
        translated.literalTranslatedText = qualityOptions.preserveLiteralTranslation
            ? (literal?.isEmpty == false ? literal : display)
            : nil
        translated.translatedText = display
        translated.speakerID = nonEmpty(item.speakerID)
        translated.tone = nonEmpty(item.tone.map {
            normalizedTranslation($0, targetLanguageCode: targetLanguageCode)
        })
        translated.translationConfidence = item.confidence.map { min(max($0, 0), 1) }
        var flags = Set((item.qaFlags ?? []).compactMap(TranslationQAFlag.init(rawValue:)))
        if detectsReviewAdjustment,
           draft?.resolvedDisplayTranslation.map({
               normalizedTranslation(
                   removingEditorialAnnotations($0),
                   targetLanguageCode: targetLanguageCode
               )
           }) != display {
            flags.insert(.reviewAdjusted)
        }
        if qualityOptions.qualityCheckEnabled {
            flags.formUnion(qualityFlags(
                region: translated,
                glossaryTerms: glossaryTerms,
                lengthMode: qualityOptions.lengthMode
            ))
        }
        translated.translationQAFlags = flags.sorted { $0.rawValue < $1.rawValue }
        return translated
    }

    /// 整頁回覆失敗或缺漏時的唯一自動 fallback。所有待補區域合併成一次請求，
    /// 不再逐區循環，也不在這個 fallback 內再次 retry。
    private func generateRecoveryBatch(
        regions: [DialogueRegion],
        pageURL: URL,
        targetLanguageCode: String,
        glossaryJSON: String,
        readingDirection: ReadingDirection,
        qualityOptions: TranslationQualityOptions,
        progress: @escaping InferenceProgress
    ) async throws -> [UUID: TranslationItem] {
        let payload = regions.enumerated().map { index, region in
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
        return try await generateItems(
            pageURL: pageURL,
            prompt: Self.draftPrompt(
                targetLanguageCode: targetLanguageCode,
                readingDirection: readingDirection,
                glossaryJSON: glossaryJSON,
                regionsJSON: try Self.json(payload),
                qualityOptions: qualityOptions,
                usesImageContext: usesImageContext
            ),
            expectedRegions: regions,
            progress: progress
        )
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
                        qualityOptions: qualityOptions,
                        usesImageContext: usesImageContext
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
        regionProgress: PageRegionProgress? = nil,
        progress: @escaping InferenceProgress
    ) async throws -> [UUID: TranslationItem] {
        try Task.checkCancellation()
        let response = try await model.generateText(
            imageURL: pageURL,
            prompt: prompt,
            maximumOutputTokens: min(16_384, max(2_048, expectedRegions.count * 384)),
            progress: { value in
                regionProgress?(
                    Self.estimatedRegionIndex(
                        inferenceProgress: value,
                        total: expectedRegions.count
                    ),
                    expectedRegions.count
                )
                progress(min(max(value, 0), 1))
            }
        )
        let expectedIDs = Set(expectedRegions.map(\.id))
        let candidates = VLMStructuredResponseDecoder.decodeArrays(TranslationItem.self, from: response)
        log(
            .debug,
            "Translation Response",
            "characters=\(response.count), decodedCandidates=\(candidates.count), rawOutput=omitted"
        )
        for candidate in candidates {
            let items = candidate.filter {
                expectedIDs.contains($0.id) && $0.resolvedDisplayTranslation != nil
            }
            guard !items.isEmpty else { continue }
            log(
                .info,
                "Translation",
                "Accepted \(items.count) / \(expectedRegions.count) translated region(s)."
            )
            regionProgress?(expectedRegions.count, expectedRegions.count)
            return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        }
        log(.error, "Translation", "The structured translation response was invalid; automatic retry is disabled.")
        throw TranslationRuntimeError.invalidModelResponse
    }

    /// MLX VLM 在約 55% 前仍在載入與準備輸入，之後才開始串流輸出。整頁語境
    /// 翻譯沒有逐區 request，因此以輸出串流比例和固定輸入順序估算目前生成區域；
    /// 回覆解碼成功時會再明確回報 total / total。
    static func estimatedRegionIndex(
        inferenceProgress: Double,
        total: Int
    ) -> Int {
        guard total > 0 else { return 0 }
        let generationStart = 0.55
        let value = min(max(inferenceProgress, 0), 1)
        guard value > generationStart else { return 0 }
        let fraction = (value - generationStart) / (1 - generationStart)
        return min(total, max(1, Int(ceil(fraction * Double(total)))))
    }

    private static func draftPrompt(
        targetLanguageCode: String,
        readingDirection: ReadingDirection,
        glossaryJSON: String,
        regionsJSON: String,
        qualityOptions: TranslationQualityOptions,
        usesImageContext: Bool
    ) -> String {
        let contextInstruction = usesImageContext
            ? "Use the page image for speaker identity, relationships, gender, tone, ambiguity and visual context."
            : "No page image is available. Infer continuity, tone and ambiguity only from the ordered source text; never invent visual facts."
        return """
        You are producing the first translation draft for one complete comic page.
        \(VLMStructuredResponseDecoder.finalJSONInstruction)
        Translate every sourceText into BCP-47 language "\(targetLanguageCode)".
        Target-language script rule: \(targetLanguageRequirement(for: targetLanguageCode))
        Read all regions together in index order using reading direction "\(readingDirection.rawValue)".
        \(contextInstruction)
        Keep the same speakerID for the same visible speaker. Use stable descriptive IDs when names are unknown.
        literalTranslation must preserve the complete meaning. displayTranslation must sound natural and fit
        approximateCharacterLimit without dropping plot facts, names, numbers, negation or emotional intent.
        \(translationContentRule)
        Length strategy: \(qualityOptions.lengthMode.rawValue).
        Project style guide: \(qualityOptions.styleGuide.isEmpty ? "No additional style guide." : qualityOptions.styleGuide)
        Terminology is authoritative; whenever sourceTerm occurs, use preferredTranslation exactly:
        \(glossaryJSON)
        Return only one valid JSON array in the same index order, with every UUID unchanged,
        in this exact shape:
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
        qualityOptions: TranslationQualityOptions,
        usesImageContext: Bool
    ) -> String {
        let comparisonInstruction = usesImageContext
            ? "Use the page image only as whole-page context for speakers, relationships, tone and ambiguity."
            : "Use the ordered page context for speakers, relationships, tone and ambiguity; no page image is available."
        return """
        You are the senior editor reviewing a complete comic-page translation into "\(targetLanguageCode)".
        \(VLMStructuredResponseDecoder.finalJSONInstruction)
        Target-language script rule: \(targetLanguageRequirement(for: targetLanguageCode))
        Perform exactly one whole-page editorial pass; do not process regions as independent OCR or translation jobs.
        Treat every supplied sourceText as authoritative. Do not re-transcribe, re-extract or replace sourceText.
        \(comparisonInstruction) Review all drafts together in "\(readingDirection.rawValue)"
        reading order. Correct mistranslation, omitted meaning, pronouns, negation, numbers, terminology,
        inconsistent speaker IDs, forms of address, register, tone and unnatural dialogue.
        Keep literalTranslation semantically complete. Make displayTranslation natural and concise for the balloon,
        but never shorten by deleting story information. Length strategy: \(qualityOptions.lengthMode.rawValue).
        \(translationContentRule)
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

    private static let translationContentRule = """
    Translation fields must contain only the words that will actually be printed in the comic.
    Never prepend or append editorial annotations, role labels, speaker labels, delivery directions,
    scene descriptions or content-type labels. Forbidden examples include 「主角驚呼」,
    「旁白/內心獨白」, 「角色：…」, [Narrator], (inner monologue), "Speaker:", and "Tone:".
    Put identity and delivery metadata only in speakerID and tone; never copy them into
    literalTranslation or displayTranslation. Do not add explanations outside the JSON either.
    """

    /// 即使模型忽略 Prompt，也不能把編輯註記排進漫畫。只移除開頭、且內容
    /// 明確符合角色／語氣／旁白 metadata 的括號標籤或冒號標籤；一般引號正文保留。
    static func removingEditorialAnnotations(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketPairs: [Character: Character] = [
            "「": "」", "『": "』", "【": "】", "[": "]", "（": "）", "(": ")"
        ]

        for _ in 0..<3 {
            guard let opening = value.first,
                  let closing = bracketPairs[opening] else { break }
            let contentStart = value.index(after: value.startIndex)
            guard let closingIndex = value[contentStart...].firstIndex(of: closing) else { break }
            let annotation = String(value[contentStart..<closingIndex])
            guard annotation.count <= 48, isEditorialAnnotation(annotation) else { break }
            value = String(value[value.index(after: closingIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = value.first, "：:-—–".contains(first) {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let separator = value.firstIndex(where: { $0 == ":" || $0 == "：" }),
           value.distance(from: value.startIndex, to: separator) <= 48 {
            let annotation = String(value[..<separator])
            if isEditorialAnnotation(annotation) {
                value = String(value[value.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    private static func isEditorialAnnotation(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let keywords = [
            "主角", "男主", "女主", "角色", "旁白", "內心", "内心", "獨白", "独白",
            "心聲", "心声", "驚呼", "惊呼", "喊道", "大喊", "小聲", "小声", "低語", "低语",
            "語氣", "语气", "主人公", "ナレーション", "モノローグ", "心の声", "叫ぶ",
            "주인공", "내레이션", "독백", "속마음", "narrator", "narration", "protagonist",
            "inner monologue", "inner thought", "speaker", "character", "tone", "exclaims",
            "shouts", "whispers", "caption"
        ]
        return keywords.contains { normalized.contains($0) }
    }

    /// 模型即使收到 zh-Hant 仍可能混入簡體字；以 Foundation／ICU 在寫入專案前
    /// 做最後一道 script 正規化。明確指定 zh-Hans 時也採對稱處理。
    static func normalizedTranslation(
        _ text: String,
        targetLanguageCode: String
    ) -> String {
        let normalizedCode = targetLanguageCode
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let transformName: String
        if normalizedCode == "zh-hant" || normalizedCode.hasPrefix("zh-hant-") {
            transformName = "Simplified-Traditional"
        } else if normalizedCode == "zh-hans" || normalizedCode.hasPrefix("zh-hans-") {
            transformName = "Traditional-Simplified"
        } else {
            return text
        }
        return text.applyingTransform(StringTransform(transformName), reverse: false) ?? text
    }

    private static func targetLanguageRequirement(for targetLanguageCode: String) -> String {
        let normalizedCode = targetLanguageCode
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalizedCode == "zh-hant" || normalizedCode.hasPrefix("zh-hant-") {
            return "Use Traditional Chinese characters only. Never output Simplified Chinese characters."
        }
        if normalizedCode == "zh-hans" || normalizedCode.hasPrefix("zh-hans-") {
            return "Use Simplified Chinese characters only. Never output Traditional Chinese characters."
        }
        return "Follow the script and regional form specified by the BCP-47 target language code."
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
