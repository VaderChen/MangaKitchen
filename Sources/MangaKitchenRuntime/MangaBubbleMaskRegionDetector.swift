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
        let detections: [BubbleDetection]
        if let bubbleSegmenter {
            do {
                detections = try bubbleSegmenter.detectBubbles(in: source)
            } catch {
                detections = try fallbackCandidateDetector.detect(in: source).map {
                    BubbleDetection(bounds: $0)
                }
            }
        } else {
            detections = try fallbackCandidateDetector.detect(in: source).map {
                BubbleDetection(bounds: $0)
            }
        }
        progress(0.7)
        let regions = detections.map { detection in
            DialogueRegion(
                bounds: detection.bounds,
                bubbleBounds: detection.bounds,
                bubbleMaskPolygons: detection.maskPolygons,
                bubbleLayoutBounds: detection.layoutBounds,
                sourceText: "",
                confidence: 0.5,
                automaticMaskEnabled: false
            )
        }
        progress(1)
        return regions
    }
}
