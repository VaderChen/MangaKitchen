import CoreGraphics
import CoreText
import Foundation
import MangaKitchenCore

/// 先用傳統影像演算法找出封閉白色泡泡／標題框，再把候選裁成有編號的聯絡表，
/// 交由圖生文模型判斷語意並轉錄。VLM 不再負責整頁座標，因此即使模型的
/// visual-grounding 座標漂移，也不會把擬聲字或人物線稿當成遮罩位置。
public actor VLMSupplementalRegionDetector: SemanticRegionDetecting {
    /// 候選有兩個來源，語意分類一視同仁，但幾何意義不同。
    private enum CandidateSource {
        /// 封閉白區：bounds 就是對話框內緣，可當 bubbleBounds。
        /// 同時保留歸屬此框的系統 OCR 結果，供定位、文字備援與結果合併。
        case enclosure([DialogueRegion])
        /// 沒有任何白框認領的 OCR 文字塊（無框台詞、放射線上的字）。
        /// 這種沒有可信的對話框邊界，bubbleBounds 必須留空。
        case recognizedText(DialogueRegion)
    }

    private struct IndexedCandidate {
        var index: Int
        var bounds: NormalizedRect
        var source: CandidateSource
    }

    private struct ClassifiedItem: Decodable {
        var index: Int
        var text: String
        var kind: String
        var direction: String?
    }

    private static let maximumCandidatesPerRequest = 6
    private let model: any ImageToTextGenerating
    private let candidateDetector: MangaBubbleCandidateDetector

    public init(model: any ImageToTextGenerating) {
        self.model = model
        candidateDetector = MangaBubbleCandidateDetector()
    }

    public func detectRegions(
        pageURL: URL,
        existingRegions: [DialogueRegion],
        sourceLanguageCodes: [String],
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()
        let source = try CGImageIO.load(from: pageURL)
        let enclosures = try candidateDetector.detect(in: source)

        // 每個系統 OCR 區域只歸屬重疊率最高的封閉框，避免同一段文字被相鄰框
        // 重複吸收。完全沒有可信封閉框的 OCR 則自成卡片，讓無框台詞仍可辨識。
        var enclosureText = [[DialogueRegion]](repeating: [], count: enclosures.count)
        var standaloneText: [DialogueRegion] = []
        for region in existingRegions {
            let bestMatch = enclosures.enumerated()
                .map { (index: $0.offset, ratio: Self.containmentRatio(of: region.bounds, in: $0.element)) }
                .max { $0.ratio < $1.ratio }
            if let bestMatch, bestMatch.ratio >= Self.textOwnershipRatio {
                enclosureText[bestMatch.index].append(region)
            } else {
                standaloneText.append(region)
            }
        }

        var candidates: [IndexedCandidate] = []
        // 封閉白框本身就是獨立的文字候選，不可要求系統 OCR 先命中。直式 CJK
        // 經常不會產生任何 Vision 結果，仍須讓 VLM 判斷框內是台詞、空框或人物。
        for (index, enclosure) in enclosures.enumerated() {
            candidates.append(IndexedCandidate(
                index: candidates.count + 1,
                bounds: enclosure,
                source: .enclosure(enclosureText[index])
            ))
        }
        for region in standaloneText {
            candidates.append(IndexedCandidate(
                index: candidates.count + 1,
                bounds: region.bounds,
                source: .recognizedText(region)
            ))
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
            .appendingPathComponent("MangaKitchen-Bubble-Sheets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let languageHint = sourceLanguageCodes.isEmpty
            ? "unknown; infer it from the cards"
            : sourceLanguageCodes.joined(separator: ", ")
        let batchCount = max(1, batches.count)
        var classifiedByIndex: [Int: ClassifiedItem] = [:]

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let sheetCandidates = batch.enumerated().map {
                IndexedCandidate(
                    index: $0.offset + 1,
                    bounds: $0.element.bounds,
                    source: $0.element.source
                )
            }
            let sheetURL = temporaryDirectoryURL
                .appendingPathComponent(String(format: "sheet-%03d.png", batchIndex + 1))
            try Self.writeContactSheet(source: source, candidates: sheetCandidates, to: sheetURL)
            let requestIndex = batchIndex
            let response = try await model.generateText(
                imageURL: sheetURL,
                prompt: Self.prompt(
                    languageHint: languageHint,
                    expectedIndices: sheetCandidates.map(\.index)
                ),
                maximumOutputTokens: 1_536,
                progress: { value in
                    let local = min(max(value, 0), 1)
                    progress((Double(requestIndex) + local) / Double(batchCount))
                }
            )
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGAKITCHEN_DEBUG_VLM_REGIONS"] == "1" {
                let message = "[MangaKitchen bubble sheet response \(batchIndex + 1)/\(batchCount)]\n\(response)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            #endif

            let items = try Self.decode(response)
            let expected = Set(sheetCandidates.map(\.index))
            var returnedLocalIndices: Set<Int> = []
            for item in items where expected.contains(item.index) {
                returnedLocalIndices.insert(item.index)
                let globalIndex = batch[item.index - 1].index
                classifiedByIndex[globalIndex] = ClassifiedItem(
                    index: globalIndex,
                    text: item.text,
                    kind: item.kind,
                    direction: item.direction
                )
            }
            let missingCount = expected.reduce(into: 0) { count, index in
                if !returnedLocalIndices.contains(index) { count += 1 }
            }
            guard missingCount == 0 else {
                throw SupplementalRegionDetectionError.missingCandidateResults(missingCount)
            }
            progress(Double(batchIndex + 1) / Double(batchCount))
        }

        let resolved = candidates.compactMap { candidate -> DialogueRegion? in
            guard let item = classifiedByIndex[candidate.index] else { return nil }
            let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let modelAccepted = ["dialogue", "caption", "title"].contains(kind)
            guard modelAccepted else { return nil }
            let modelText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let groundingOCR: [DialogueRegion]
            switch candidate.source {
            case let .enclosure(regions):
                groundingOCR = regions
            case let .recognizedText(region):
                groundingOCR = [region]
            }
            // 只有「整個被框住」的 OCR 框才拿來定位。跨在框線上的 OCR 框可能屬於
            // 隔壁對話框或擬聲字，讓它參與聯集會把 bounds 拉向邊緣；寧可退回
            // 候選框，交由像素精修收斂。
            let containedOCR = groundingOCR.filter {
                Self.containmentRatio(of: $0.bounds, in: candidate.bounds)
                    >= Self.positioningContainmentRatio
            }
            let ocrText: String
            switch candidate.source {
            case .enclosure:
                // 有 OCR 時以其文字作備援；沒有 OCR 時直接採用 VLM 對封閉框的
                // 轉錄，讓直式文字不會因系統 OCR 漏字而整區消失。
                ocrText = groundingOCR
                    .map { $0.rawSourceText ?? $0.sourceText }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            case let .recognizedText(region):
                // 這張卡片就是這個 OCR 區塊本身，模型看不清時沿用它原本的文字。
                ocrText = (region.rawSourceText ?? region.sourceText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let text = !modelText.isEmpty ? modelText : ocrText
            guard !text.isEmpty else { return nil }
            let rawText = !ocrText.isEmpty ? ocrText : text

            // 兩個來源重疊時以 OCR 位置優先：取完全被框住的 OCR 框聯集當「文字在
            // 哪」，白區候選則退為「不得超出的框」。候選框可能是整格白底分鏡，
            // 直接拿來排版會把譯文擺到分鏡正中央；用 OCR 聯集才對得回原文位置。
            // 聯集偏小也安全：像素精修若發現粗框截斷了文字，會自動改用整個
            // bubbleBounds 重新搜尋，最後再收斂到字形級多邊形。
            let textBounds = containedOCR
                .map(\.bounds)
                .reduce(nil) { partial, bounds in
                    partial.map { $0.union(with: bounds) } ?? bounds
                }
                .map { $0.intersection(with: candidate.bounds) }
                .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            var style = groundingOCR.first?.style ?? DialogueStyle()
            style.writingDirection = item.direction
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap(WritingDirection.init(rawValue:))
                ?? .automatic

            let bounds: NormalizedRect
            let bubbleBounds: NormalizedRect?
            switch candidate.source {
            case .enclosure:
                bounds = textBounds ?? candidate.bounds
                bubbleBounds = candidate.bounds
            case let .recognizedText(region):
                // 沒有封閉白區就沒有可信的對話框邊界。bubbleBounds 留 nil，
                // 遮罩與排版才會退回「只依 maskExpansion 由文字外擴」，
                // 而不是把一個猜出來的框當成硬邊界。
                bounds = region.bounds
                bubbleBounds = nil
            }
            return DialogueRegion(
                id: groundingOCR.first?.id ?? UUID(),
                bounds: bounds,
                bubbleBounds: bubbleBounds,
                rawSourceText: rawText,
                sourceText: text,
                confidence: max(0.75, groundingOCR.map(\.confidence).max() ?? 0),
                style: style,
                // 只有像素精修成功後才開啟自動遮罩；失敗時不可把整個泡泡抹掉。
                automaticMaskEnabled: false
            )
        }
        progress(1)
        return Self.deduplicated(resolved)
    }

    /// OCR 區塊至少有此比例落在封閉框內，才歸屬該框；否則視為無框文字。
    private static let textOwnershipRatio = 0.3
    /// 允許 OCR 框決定 bounds 所需的重疊比例；OCR 粗框本來就會鬆一點，
    /// 因此不要求數學上的 100%。
    private static let positioningContainmentRatio = 0.95

    private static func containmentRatio(
        of textBounds: NormalizedRect,
        in candidateBounds: NormalizedRect
    ) -> Double {
        let overlap = candidateBounds.intersection(with: textBounds)
        let textArea = max(textBounds.width * textBounds.height, .leastNonzeroMagnitude)
        return (overlap.width * overlap.height) / textArea
    }

    /// 封閉框偵測與 OCR 粗框偶爾會對同一內容產生近似候選。幾何高度重疊，或
    /// 文字相同且有實質交集時視為同一區域；保留具有封閉框資訊與較小文字框者。
    private static func deduplicated(_ regions: [DialogueRegion]) -> [DialogueRegion] {
        var result: [DialogueRegion] = []
        for region in regions {
            guard let duplicateIndex = result.firstIndex(where: { isDuplicate($0, region) }) else {
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

    private static func prompt(languageHint: String, expectedIndices: [Int]) -> String {
        """
        You are proofreading candidate regions from one comic page. The image is a contact sheet.
        Every card has a visible REGION number. A card is a crop either around one enclosed white
        area (a balloon, caption box, or title card) or around a block of text that has no
        enclosure at all. Both kinds can hold real dialogue.
        Likely source language codes: \(languageHint).
        Expected REGION numbers: \(expectedIndices).

        For every expected REGION, return exactly one item:
        - dialogue: speech or thought, whether or not a balloon encloses it;
        - caption: narration or inner monologue, whether it sits in a caption box or is set
          directly on the artwork or on speed lines;
        - title: a chapter, episode, or panel title;
        - ignore: artwork, a face, clothing, empty decoration, sound effect, action sound, credit,
          username, watermark, publisher mark, advertisement, or page number.

        Rules:
        - Decide by WHAT THE TEXT IS, not by whether a frame encloses it. Unenclosed narration and
          unenclosed speech are still caption and dialogue.
        - Stylised onomatopoeia drawn as artwork (impact and action sounds) is always ignore, even
          when it is large and legible.
        - A numbered chapter/episode heading inside its own framed title card is title, not a page number.
        - Transcribe all text on an accepted card exactly in its original language.
        - Combine all lines or vertical columns belonging to the same card into one text value, in
          the source language's reading order.
        - direction must describe the source text in the card: vertical for top-to-bottom columns,
          horizontal for left-to-right or right-to-left rows.
        - For ignore, return an empty text string.
        - Never translate, explain, omit, duplicate, or renumber a REGION.

        Return only a syntactically valid JSON array in this exact shape:
        [{"index":1,"text":"source text","kind":"dialogue","direction":"vertical"},{"index":2,"text":"","kind":"ignore","direction":"horizontal"}]
        """
    }

    private static func writeContactSheet(
        source: CGImage,
        candidates: [IndexedCandidate],
        to outputURL: URL
    ) throws {
        let columns = min(3, max(1, candidates.count))
        let rows = Int(ceil(Double(candidates.count) / Double(columns)))
        let cellWidth = 384
        let cellHeight = 384
        let sheetWidth = columns * cellWidth
        let sheetHeight = rows * cellHeight
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: sheetWidth,
            height: sheetHeight,
            bitsPerComponent: 8,
            bytesPerRow: sheetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        context.setFillColor(gray: 0.92, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        for (offset, candidate) in candidates.enumerated() {
            let column = offset % columns
            let row = offset / columns
            let cellX = CGFloat(column * cellWidth)
            let cellTop = CGFloat(row * cellHeight)
            let cellBottom = CGFloat(sheetHeight) - cellTop - CGFloat(cellHeight)
            let cellRect = CGRect(
                x: cellX + 4,
                y: cellBottom + 4,
                width: CGFloat(cellWidth - 8),
                height: CGFloat(cellHeight - 8)
            )
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(cellRect)
            context.setStrokeColor(gray: 0.15, alpha: 1)
            context.setLineWidth(3)
            context.stroke(cellRect)

            let sourceRect = expandedPixelRect(
                for: candidate.bounds,
                sourceWidth: source.width,
                sourceHeight: source.height
            )
            if let crop = source.cropping(to: sourceRect) {
                let availableWidth = CGFloat(cellWidth - 24)
                let availableHeight = CGFloat(cellHeight - 62)
                let scale = min(
                    availableWidth / CGFloat(crop.width),
                    availableHeight / CGFloat(crop.height)
                )
                let drawWidth = CGFloat(crop.width) * scale
                let drawHeight = CGFloat(crop.height) * scale
                let contentBottom = cellBottom + 12
                let drawRect = CGRect(
                    x: cellX + (CGFloat(cellWidth) - drawWidth) / 2,
                    y: contentBottom + (availableHeight - drawHeight) / 2,
                    width: drawWidth,
                    height: drawHeight
                )
                context.draw(crop, in: drawRect)
            }

            let label = "REGION \(candidate.index)" as CFString
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil),
                kCTForegroundColorAttributeName: CGColor(gray: 0.05, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                nil,
                label,
                attributes as CFDictionary
            ))
            context.textPosition = CGPoint(
                x: cellX + 12,
                y: cellBottom + CGFloat(cellHeight - 34)
            )
            CTLineDraw(line, context)
        }

        guard let sheet = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(sheet, to: outputURL)
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

    private static func decode(_ response: String) throws -> [ClassifiedItem] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ClassifiedItem].self, from: data) {
            return decoded
        }
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ClassifiedItem].self, from: data) else {
            throw SupplementalRegionDetectionError.invalidModelResponse
        }
        return decoded
    }
}

public enum SupplementalRegionDetectionError: LocalizedError, Sendable {
    case invalidModelResponse
    case missingCandidateResults(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidModelResponse:
            "圖生文模型沒有回傳指定的泡泡分類 JSON 格式。"
        case let .missingCandidateResults(count):
            "泡泡分類缺少 \(count) 個候選區域，未寫入不完整結果。"
        }
    }
}
