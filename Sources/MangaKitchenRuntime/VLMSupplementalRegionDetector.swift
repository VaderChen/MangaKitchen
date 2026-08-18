import CoreGraphics
import Foundation
import MangaKitchenCore

/// 以封閉區域或整頁字形筆畫找出候選，交由圖生文模型分類、轉錄與粗定位。
///
/// 主訊號是「字」而不是「封閉白區」：白底頁面上，開口氣泡與無框台詞的內部會
/// 直接連到整頁背景（實測 flood fill 得到 100% 頁面積，任何門檻皆然），封閉
/// 白區在原理上就看不見它們，文字會在進入 VLM 之前就消失。改以文字定位後，
/// 有沒有外框只影響 bubbleBounds 精不精確，不再決定能否被偵測到。
///
/// 氣泡模型的 BBOX 限定後續像素精修的搜尋區；真正遮罩仍由圖像連通元件產生。
public actor VLMSupplementalRegionDetector: SemanticRegionDetecting {
    private struct IndexedCandidate {
        var index: Int
        /// 文字塊範圍，決定卡片裁切與最終 bounds。
        var bounds: NormalizedRect
        /// 包住這個文字塊的封閉白區；沒有就是無框台詞，維持 nil。
        var bubbleBounds: NormalizedRect?
        /// 沒有氣泡 BBOX 的補充候選以本機字形群集作為後備。
        var fallbackTextBounds: NormalizedRect?
    }

    private struct ClassifiedItem: Decodable {
        var index: Int
        var text: String
        var kind: String
        var direction: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case text
            case kind
            case direction
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            index = try values.decodeIfPresent(Int.self, forKey: .index) ?? 1
            text = try values.decode(String.self, forKey: .text)
            kind = try values.decode(String.self, forKey: .kind)
            direction = try values.decodeIfPresent(String.self, forKey: .direction)
        }
    }

    private struct ResolvedClassifiedItem {
        var text: String
        var kind: String
        var direction: String?
    }

    /// 文字塊要幾乎整個落在封閉白區內，才算那個對話框的內容。
    /// 字形群集被封閉白區覆蓋到這個比例，就視為已由主來源處理。
    private static let coveredByEnclosureRatio = 0.6
    /// 補洞卡片的數量上限，避免線稿多的頁面把推論成本放大。
    private static let maximumSupplementalCards = 12
    /// 精細掃描的卡片上限；比快速模式寬，因為它的目的就是不漏字。
    private static let maximumFineScanCards = 36

    /// 在單一格子內找出所有字形群集，換算回整頁座標。
    private static func textClusters(
        within tile: NormalizedRect,
        of source: CGImage,
        using detector: MangaTextClusterDetector
    ) -> [NormalizedRect] {
        let width = Double(source.width)
        let height = Double(source.height)
        let cropRect = CGRect(
            x: (tile.minX * width).rounded(.down),
            y: (tile.minY * height).rounded(.down),
            width: (tile.width * width).rounded(.up),
            height: (tile.height * height).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard cropRect.width > 8, cropRect.height > 8,
              let crop = source.cropping(to: cropRect),
              let clusters = try? detector.detect(in: crop) else { return [] }

        return clusters.map { cluster in
            let local = cluster.bounds
            return NormalizedRect(
                x: (cropRect.minX + local.minX * cropRect.width) / width,
                y: (cropRect.minY + local.minY * cropRect.height) / height,
                width: local.width * cropRect.width / width,
                height: local.height * cropRect.height / height
            ).clamped()
        }
    }

    /// 精細掃描用的規則網格。重疊 20% 讓跨格的對話不會被切成兩半。
    private static func gridTiles(columns: Int = 3, rows: Int = 4) -> [NormalizedRect] {
        let overlap = 0.2
        let width = 1.0 / Double(columns)
        let height = 1.0 / Double(rows)
        var tiles: [NormalizedRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = Double(column) * width - width * overlap / 2
                let y = Double(row) * height - height * overlap / 2
                tiles.append(NormalizedRect(
                    x: x, y: y,
                    width: width * (1 + overlap),
                    height: height * (1 + overlap)
                ).clamped())
            }
        }
        return tiles
    }

    private static func containmentRatio(
        of inner: NormalizedRect,
        in outer: NormalizedRect
    ) -> Double {
        let overlap = outer.intersection(with: inner)
        let innerArea = max(inner.width * inner.height, .leastNonzeroMagnitude)
        return (overlap.width * overlap.height) / innerArea
    }

    private static func enclosure(
        containing textBounds: NormalizedRect,
        in enclosures: [NormalizedRect]
    ) -> NormalizedRect? {
        var best: NormalizedRect?
        var bestArea = Double.greatestFiniteMagnitude
        for enclosure in enclosures {
            let overlap = enclosure.intersection(with: textBounds)
            let textArea = max(textBounds.width * textBounds.height, .leastNonzeroMagnitude)
            guard (overlap.width * overlap.height) / textArea >= 0.9 else { continue }
            let area = enclosure.width * enclosure.height
            // 巢狀時取最小的那個，才不會拿到整格分鏡當對話框。
            if area < bestArea { bestArea = area; best = enclosure }
        }
        return best
    }

    /// 小型 VLM 同時看多個候選時，容易把轉錄或座標向前錯配。
    /// 單卡推論雖增加呼叫次數，但可讓文字、粗框與原圖裁切維持一對一。
    private static let maximumCandidatesPerRequest = 1
    /// 防止短文字被配到整格分鏡：候選正規化面積除以可見字元數不得超過此值。
    private static let maximumAreaPerTranscriptCharacter = 0.008
    private let model: any ImageToTextGenerating
    private let textClusterDetector = MangaTextClusterDetector()
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?
    private let fallbackCandidateDetector: MangaBubbleCandidateDetector

    public init(
        model: any ImageToTextGenerating,
        bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime? = nil
    ) {
        self.model = model
        self.bubbleSegmenter = bubbleSegmenter
        fallbackCandidateDetector = MangaBubbleCandidateDetector()
    }

    public func detectRegions(
        pageURL: URL,
        sourceLanguageCodes: [String],
        fineScanEnabled: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        let source = try CGImageIO.load(from: pageURL)
        let enclosures: [NormalizedRect]
        if let bubbleSegmenter {
            do {
                enclosures = try bubbleSegmenter.detect(in: source)
            } catch {
                enclosures = try fallbackCandidateDetector.detect(in: source)
            }
        } else {
            enclosures = try fallbackCandidateDetector.detect(in: source)
        }
        let pageTextClusters = fineScanEnabled
            ? []
            : ((try? textClusterDetector.detect(in: source)) ?? [])
        var candidates: [IndexedCandidate] = []

        if fineScanEnabled {
            // 精細掃描：整頁切 3×3，每格當成一張 grounding 卡片送給 VLM。
            //
            // 為什麼是格子而不是幾何候選：開放式台詞沒有封閉框、也不見得能靠
            // 字形群集穩定抓到（實測結構化條件在真實頁面上分不開文字與線稿），
            // 但規則網格覆蓋整頁、沒有死角。位置由「哪一格」提供，模型只需在
            // 一張 1/9 大小的圖裡指位置 —— 實測單格 grounding 可用（「ふふ…」
            // 這顆每個幾何方法都抓不到的，單格一次就讀出來且位置正確），而
            // 整頁 grounding 不可用（不同台詞會拿到同一組座標）。
            //
            // 模型漏回座標時，退回該格內字形最多的群集當安全後備，
            // 絕不退回整格 —— 整格會讓像素精修把線稿一起收進遮罩。
            for tile in Self.gridTiles(columns: 3, rows: 3) {
                let fallback = Self.textClusters(
                    within: tile, of: source, using: textClusterDetector
                ).max { lhs, rhs in
                    lhs.width * lhs.height < rhs.width * rhs.height
                }
                candidates.append(IndexedCandidate(
                    index: candidates.count + 1,
                    bounds: tile,
                    // 網格不代表對話框邊界；這個後備模式僅依本機文字群集限縮範圍。
                    bubbleBounds: nil,
                    fallbackTextBounds: fallback
                ))
            }
        } else {
            for enclosure in enclosures {
                let fallbackTextBounds = pageTextClusters
                    .filter {
                        Self.containmentRatio(of: $0.bounds, in: enclosure)
                            >= Self.coveredByEnclosureRatio
                    }
                    .max { $0.glyphCount < $1.glyphCount }?
                    .bounds
                candidates.append(IndexedCandidate(
                    index: candidates.count + 1,
                    bounds: enclosure,
                    bubbleBounds: enclosure,
                    fallbackTextBounds: fallbackTextBounds
                ))
            }
            // 補洞：白底上的開口氣泡與無框台詞，其內部直接連到整頁背景
            // （實測 flood fill 得到 100% 頁面積），封閉白區永遠看不見。
            // 群集會夾帶線稿誤判，交給 VLM 判 ignore —— 實測它能正確擋掉。
            let uncovered = pageTextClusters.filter { cluster in
                !enclosures.contains {
                    Self.containmentRatio(of: cluster.bounds, in: $0) >= Self.coveredByEnclosureRatio
                }
            }.prefix(Self.maximumSupplementalCards)
            for cluster in uncovered {
                candidates.append(IndexedCandidate(
                    index: candidates.count + 1,
                    bounds: cluster.bounds,
                    bubbleBounds: Self.enclosure(containing: cluster.bounds, in: enclosures),
                    fallbackTextBounds: cluster.bounds
                ))
            }
        }

        guard !candidates.isEmpty else {
            progress(1)
            return []
        }
        let batches = stride(
            from: 0,
            to: candidates.count,
            by: Self.maximumCandidatesPerRequest
        ).map {
            Array(candidates[$0..<min($0 + Self.maximumCandidatesPerRequest, candidates.count)])
        }
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Grounded-Crops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let languageHint = sourceLanguageCodes.isEmpty
            ? "unknown; infer it from the cards"
            : sourceLanguageCodes.joined(separator: ", ")
        let batchCount = max(1, batches.count)
        var classifiedByIndex: [Int: ResolvedClassifiedItem] = [:]

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let requestCandidates = batch.enumerated().map {
                IndexedCandidate(
                    index: $0.offset + 1,
                    bounds: $0.element.bounds,
                    bubbleBounds: $0.element.bubbleBounds,
                    fallbackTextBounds: $0.element.fallbackTextBounds
                )
            }
            guard let requestCandidate = requestCandidates.first else { continue }
            let cropURL = temporaryDirectoryURL
                .appendingPathComponent(String(format: "crop-%03d.png", batchIndex + 1))
            try Self.writeCandidateCrop(
                source: source,
                candidate: requestCandidate,
                to: cropURL
            )
            let requestIndex = batchIndex
            let expected = Set(requestCandidates.map(\.index))
            var items: [ClassifiedItem]?

            for attempt in 0..<VLMStructuredResponseDecoder.maximumAttempts {
                try Task.checkCancellation()
                let response = try await model.generateText(
                    imageURL: cropURL,
                    prompt: Self.prompt(
                        languageHint: languageHint,
                        expectedIndices: requestCandidates.map(\.index),
                        attempt: attempt
                    ),
                    maximumOutputTokens: 512,
                    progress: { value in
                        let local = VLMStructuredResponseDecoder.mappedProgress(
                            attempt: attempt,
                            value: value
                        )
                        progress((Double(requestIndex) + local) / Double(batchCount))
                    }
                )
                #if DEBUG
                if ProcessInfo.processInfo.environment["MANGAKITCHEN_DEBUG_VLM_REGIONS"] == "1" {
                    let message = "[MangaKitchen grounded crop response \(batchIndex + 1)/\(batchCount), attempt \(attempt + 1)]\n\(response)\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
                #endif

                for candidateItems in VLMStructuredResponseDecoder.decodeArrays(
                    ClassifiedItem.self,
                    from: response
                ) {
                    let returnedIndices = Set(candidateItems.map(\.index)).intersection(expected)
                    let missingCount = expected.subtracting(returnedIndices).count
                    if missingCount == 0 {
                        items = candidateItems
                        break
                    }
                }
                if items != nil { break }
            }

            guard let items else {
                // 單一卡片的模型輸出不完整時，只略過該候選。不能因為一個候選失敗，
                // 就丟棄同一頁其他已成功分類的區域。空文字與未知 kind 會在下方統一過濾，
                // 仍不會被寫成不完整的對話區域。
                progress(Double(batchIndex + 1) / Double(batchCount))
                continue
            }

            for item in items where expected.contains(item.index) {
                let localIndex = item.index - 1
                guard batch.indices.contains(localIndex) else { continue }
                let candidate = batch[localIndex]
                classifiedByIndex[candidate.index] = ResolvedClassifiedItem(
                    text: item.text,
                    kind: item.kind,
                    direction: item.direction
                )
            }
            progress(Double(batchIndex + 1) / Double(batchCount))
        }

        let resolved = candidates.compactMap { candidate -> DialogueRegion? in
            guard let item = classifiedByIndex[candidate.index] else { return nil }
            let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.isModelAcceptedKind(kind) else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = candidate.bubbleBounds
                ?? candidate.fallbackTextBounds
                ?? candidate.bounds
            guard !text.isEmpty,
                  !Self.isSoundEffectTranscript(text),
                  candidate.bubbleBounds != nil || Self.isPlausibleTranscript(text, in: bounds) else {
                return nil
            }
            var style = DialogueStyle()
            style.writingDirection = item.direction
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap(WritingDirection.init(rawValue:))
                ?? .automatic
            let bubbleBounds = candidate.bubbleBounds
            return DialogueRegion(
                bounds: bounds,
                bubbleBounds: bubbleBounds,
                rawSourceText: text,
                sourceText: text,
                ocrTextRefined: true,
                confidence: 0.75,
                style: style,
                // 只有像素精修成功後才開啟自動遮罩；失敗時不可把整個泡泡抹掉。
                automaticMaskEnabled: false
            )
        }
        progress(1)
        return Self.deduplicated(resolved)
    }

    /// 封閉框偵測偶爾會對同一內容產生近似候選。幾何高度重疊，或文字相同且有
    /// 實質交集時視為同一區域。
    private static func deduplicated(_ regions: [DialogueRegion]) -> [DialogueRegion] {
        var result: [DialogueRegion] = []
        for region in regions {
            guard let duplicateIndex = result.firstIndex(where: {
                isDuplicate($0, region) || isTranscriptionEcho($0, region)
            }) else {
                result.append(region)
                continue
            }
            result[duplicateIndex] = preferredRegion(result[duplicateIndex], region)
        }
        return result
    }

    private static func isDuplicate(_ lhs: DialogueRegion, _ rhs: DialogueRegion) -> Bool {
        let overlap = lhs.bounds.intersection(with: rhs.bounds)
        let overlapArea = overlap.width * overlap.height
        guard overlapArea > 0 else { return false }
        let minimumArea = max(
            min(lhs.bounds.width * lhs.bounds.height, rhs.bounds.width * rhs.bounds.height),
            .leastNonzeroMagnitude
        )
        if overlapArea / minimumArea >= 0.82 { return true }
        let lhsText = normalizedText(lhs.sourceText)
        let rhsText = normalizedText(rhs.sourceText)
        return !lhsText.isEmpty && lhsText == rhsText && overlapArea / minimumArea >= 0.25
    }

    /// 轉錄回聲：兩個位置完全不重疊，文字卻幾乎一樣。這是無框候選從鄰近卡片
    /// 把同一段台詞再讀一次造成的，幾何去重看不到（重疊為零就直接放行）。
    ///
    /// 只在其中一邊沒有 bubbleBounds 時才判定重複 —— 同一頁本來就可能有兩顆
    /// 內容相同的氣泡（003 就有兩個「ここだ…！」），兩邊都有封閉框佐證時不能合併。
    private static func isTranscriptionEcho(_ lhs: DialogueRegion, _ rhs: DialogueRegion) -> Bool {
        guard lhs.bubbleBounds == nil || rhs.bubbleBounds == nil else { return false }
        let lhsText = normalizedText(lhs.sourceText)
        let rhsText = normalizedText(rhs.sourceText)
        guard lhsText.count >= 4, rhsText.count >= 4 else { return false }
        return characterOverlapRatio(lhsText, rhsText) >= 0.7
    }

    /// 較短那串有多少比例的字元也出現在較長那串裡（以出現次數計）。
    /// 模型重讀同一段時常有錯字與省略，因此不用完全相等比對。
    private static func characterOverlapRatio(_ lhs: String, _ rhs: String) -> Double {
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        var pool: [Character: Int] = [:]
        for character in longer { pool[character, default: 0] += 1 }
        var shared = 0
        for character in shorter where (pool[character] ?? 0) > 0 {
            pool[character]! -= 1
            shared += 1
        }
        return Double(shared) / Double(max(shorter.count, 1))
    }

    private static func preferredRegion(_ lhs: DialogueRegion, _ rhs: DialogueRegion) -> DialogueRegion {
        let prefersLeft: Bool
        if (lhs.bubbleBounds != nil) != (rhs.bubbleBounds != nil) {
            prefersLeft = lhs.bubbleBounds != nil
        } else {
            let lhsArea = lhs.bounds.width * lhs.bounds.height
            let rhsArea = rhs.bounds.width * rhs.bounds.height
            prefersLeft = lhsArea <= rhsArea
        }
        var value = prefersLeft ? lhs : rhs
        value.confidence = max(lhs.confidence, rhs.confidence)
        if value.style.writingDirection == .automatic {
            let alternative = prefersLeft ? rhs : lhs
            value.style.writingDirection = alternative.style.writingDirection
        }
        return value
    }

    private static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private static func isSoundEffectTranscript(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        return normalized.hasPrefix("sfx:")
            || normalized.hasPrefix("sfx：")
            || normalized.hasPrefix("soundeffect:")
    }

    private static func isModelAcceptedKind(_ kind: String) -> Bool {
        ["dialogue", "caption", "title"].contains(
            kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func isPlausibleTranscript(
        _ text: String,
        in bounds: NormalizedRect
    ) -> Bool {
        let visibleCharacterCount = text.reduce(into: 0) { count, character in
            guard !character.isWhitespace, !character.isNewline else { return }
            count += 1
        }
        guard visibleCharacterCount > 0 else { return false }
        let areaPerCharacter = bounds.width * bounds.height / Double(visibleCharacterCount)
        return areaPerCharacter <= maximumAreaPerTranscriptCharacter
    }

    private static func prompt(languageHint: String, expectedIndices: [Int], attempt: Int) -> String {
        """
        You are proofreading one cropped candidate region from a comic page. It may contain
        enclosed or unenclosed text, an empty panel, artwork, or another non-text area.
        Likely source language codes: \(languageHint).
        Expected REGION numbers: \(expectedIndices).

        For every expected REGION, return exactly one item:
        - dialogue: speech or thought, with or without a closed balloon;
        - caption: narration or inner monologue, with or without a closed caption box;
        - title: a chapter, episode, or panel title;
        - ignore: artwork, a face, clothing, empty decoration, sound effect, action sound, credit,
          username, watermark, publisher mark, advertisement, or page number.

        Rules:
        - Decide by the visible text and its semantic role, not by whether an outline encloses it.
        - Stylised onomatopoeia drawn as artwork (impact and action sounds) is always ignore, even
          when it is large and legible. Do not confuse it with words spoken by a character.
        - A spoken attack name or emphatic phrase is dialogue when it appears in a speech balloon
          or is visibly uttered by a character, even when its lettering is large, bold or stylised.
        - title is only for an explicit chapter or episode heading, not a spoken attack name.
        - Transcribe all text on an accepted card exactly in its original language.
        - Combine all lines or vertical columns belonging to the same card into one text value, in
          the source language's reading order.
        - direction must describe the source text in the card: vertical for top-to-bottom columns,
          horizontal for left-to-right or right-to-left rows.
        - Do not return coordinates, bounding boxes, masks, explanations, or Markdown.
        - For ignore, return an empty text string.
        - Never translate, explain, omit, duplicate, or renumber a REGION.

        Return only a syntactically valid JSON array in this exact shape:
        [{"index":1,"text":"source text","kind":"dialogue","direction":"vertical"}]
        \(VLMStructuredResponseDecoder.retryInstruction(attempt: attempt))
        """
    }

    private static func writeCandidateCrop(
        source: CGImage,
        candidate: IndexedCandidate,
        to outputURL: URL
    ) throws {
        let visibleBounds = candidate.bubbleBounds
            .map { $0.union(with: candidate.bounds) }
            ?? candidate.bounds
        let sourceRect = expandedPixelRect(
            for: visibleBounds,
            sourceWidth: source.width,
            sourceHeight: source.height
        )
        guard let crop = source.cropping(to: sourceRect) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(crop, to: outputURL)
    }

    private static func expandedPixelRect(
        for bounds: NormalizedRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let x = bounds.x * Double(sourceWidth)
        let y = bounds.y * Double(sourceHeight)
        let width = bounds.width * Double(sourceWidth)
        let height = bounds.height * Double(sourceHeight)
        let padding = max(8, min(width, height) * 0.1)
        return CGRect(
            x: floor(max(0, x - padding)),
            y: floor(max(0, y - padding)),
            width: ceil(min(Double(sourceWidth), x + width + padding) - max(0, x - padding)),
            height: ceil(min(Double(sourceHeight), y + height + padding) - max(0, y - padding))
        ).intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
    }

}

public enum SupplementalRegionDetectionError: LocalizedError, Sendable {
    case invalidModelResponse
    case incompleteCandidateResults(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidModelResponse:
            "圖生文模型沒有回傳指定的泡泡分類 JSON 格式。"
        case let .incompleteCandidateResults(count):
            "泡泡分類有 \(count) 個候選缺少結果或有效文字內容，未寫入不完整結果。"
        }
    }
}
