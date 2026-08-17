import Foundation
import MangaKitchenCore
import Vision

public actor VisionOCRService: PageTextRecognizing {
    public init() {}

    public func recognizeText(
        in imageURL: URL,
        languageCodes: [String],
        readingDirection: ReadingDirection
    ) async throws -> [DialogueRegion] {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.008
        if !languageCodes.isEmpty {
            request.recognitionLanguages = languageCodes
        }

        let handler = VNImageRequestHandler(url: imageURL)
        try handler.perform([request])
        try Task.checkCancellation()

        let regions = (request.results ?? []).compactMap { observation -> DialogueRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let visionBounds = observation.boundingBox
            let topLeftBounds = NormalizedRect(
                x: visionBounds.minX,
                y: 1 - visionBounds.maxY,
                width: visionBounds.width,
                height: visionBounds.height
            ).clamped()
            return DialogueRegion(
                bounds: topLeftBounds,
                rawSourceText: text,
                sourceText: text,
                confidence: Double(candidate.confidence),
                automaticMaskEnabled: false
            )
        }

        let dialogueBlocks = TextRegionGrouper.merge(regions)
        return ReadingOrderResolver.sorted(dialogueBlocks, direction: readingDirection)
    }
}
