import Foundation
import MangaKitchenCore

public actor MangaBubbleMaskRegionDetector: SemanticRegionDetecting {
    private let bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime?
    private let fallbackCandidateDetector = MangaBubbleCandidateDetector()

    public init(bubbleSegmenter: MangaBubbleSegmentationCoreMLRuntime? = nil) {
        self.bubbleSegmenter = bubbleSegmenter
    }

    public func detectRegions(
        pageURL: URL,
        sourceLanguageCodes _: [String],
        fineScanEnabled _: Bool,
        progress: @escaping InferenceProgress
    ) async throws -> [DialogueRegion] {
        progress(0.05)
        let source = try CGImageIO.load(from: pageURL)
        let bounds: [NormalizedRect]
        if let bubbleSegmenter {
            do {
                bounds = try bubbleSegmenter.detect(in: source)
            } catch {
                bounds = try fallbackCandidateDetector.detect(in: source)
            }
        } else {
            bounds = try fallbackCandidateDetector.detect(in: source)
        }
        progress(0.7)
        let regions = bounds.map { bounds in
            DialogueRegion(
                bounds: bounds,
                bubbleBounds: bounds,
                sourceText: "",
                confidence: 0.5,
                automaticMaskEnabled: false
            )
        }
        progress(1)
        return regions
    }
}
