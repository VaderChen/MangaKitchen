import CoreGraphics
import Foundation
import MangaKitchenCore

/// 把 Agent 目測給的粗框對齊到本機偵測到的對話框。
///
/// 像素精修的前提是「粗框大致就是文字」。本機偵測給的框很緊，這個前提成立；
/// Agent 讀圖目測的框鬆得多，圈進速度線與網點之後，遮罩外框會被撐開到觸發
/// 合理性判斷，整個區域被靜靜停用 —— 結果是那段文字完全沒有被遮住。
///
/// 對齊之後兩條路徑吃到的幾何一致，遮罩自然一致。對不上的區域（無框台詞、
/// 擬聲字）保留 Agent 原本的框，因為那些本來就不是對話框。
public enum MangaAgentRegionSnapper {
    /// 兩框要有多少比例互相涵蓋才算同一個對話框。
    ///
    /// 不用 IoU，也不能只看單一方向。Agent 目測的框兩種方向都會偏：
    /// 框太大時，偵測框幾乎整個落在粗框內；框太小時（例如整條招牌只框到前半段），
    /// 反而是粗框整個落在偵測框內。只檢查其中一邊，另一邊就會漏配 —— 漏配的
    /// 後果不是「不動它」，而是遮罩只蓋住 Agent 指到的那一小段，剩下的字留在畫面上。
    private static let minimumCoverage = 0.5

    /// 讀取整頁、跑一次本機偵測，再對齊。偵測失敗時原樣回傳 —— 對齊是加分項，
    /// 不該讓整條 MCP 流程因為模型載入不了而中斷。
    public static func snapped(
        regions: [DialogueRegion],
        pageURL: URL,
        using segmenter: MangaBubbleSegmentationCoreMLRuntime?
    ) -> [DialogueRegion] {
        guard let segmenter, !regions.isEmpty else { return regions }
        guard let source = try? CGImageIO.load(from: pageURL),
              let detections = try? segmenter.detectBubbles(in: source) else { return regions }
        return snapped(regions: regions, to: detections)
    }

    public static func snapped(
        regions: [DialogueRegion],
        to detections: [BubbleDetection]
    ) -> [DialogueRegion] {
        guard !regions.isEmpty, !detections.isEmpty else { return regions }

        struct Match {
            var regionIndex: Int
            var detectionIndex: Int
            var coverage: Double
        }

        var candidates: [Match] = []
        for regionIndex in regions.indices {
            for detectionIndex in detections.indices {
                let coverage = mutualCoverage(
                    detections[detectionIndex].bounds,
                    regions[regionIndex].bounds
                )
                guard coverage >= minimumCoverage else { continue }
                candidates.append(Match(
                    regionIndex: regionIndex,
                    detectionIndex: detectionIndex,
                    coverage: coverage
                ))
            }
        }
        // 一個粗框可能罩住兩顆對話框，兩個粗框也可能指向同一顆。
        // 依覆蓋率由高到低一對一配對，避免同一顆被搶走兩次。
        candidates.sort { $0.coverage > $1.coverage }

        var usedRegions: Set<Int> = []
        var usedDetections: Set<Int> = []
        var result = regions
        for candidate in candidates {
            guard !usedRegions.contains(candidate.regionIndex),
                  !usedDetections.contains(candidate.detectionIndex) else { continue }
            usedRegions.insert(candidate.regionIndex)
            usedDetections.insert(candidate.detectionIndex)
            let detection = detections[candidate.detectionIndex]
            result[candidate.regionIndex].bounds = detection.bounds
            result[candidate.regionIndex].bubbleBounds = detection.bounds
            result[candidate.regionIndex].bubbleMaskPolygons = detection.maskPolygons
            result[candidate.regionIndex].bubbleLayoutBounds = detection.layoutBounds
        }
        return result
    }

    /// 兩框互相涵蓋比例取較大的一邊，兩種偏法都能配上。
    private static func mutualCoverage(
        _ detection: NormalizedRect,
        _ coarse: NormalizedRect
    ) -> Double {
        let detectionArea = detection.width * detection.height
        let coarseArea = coarse.width * coarse.height
        guard detectionArea > 0, coarseArea > 0 else { return 0 }
        let intersection = detection.intersection(with: coarse)
        guard intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return max(intersectionArea / detectionArea, intersectionArea / coarseArea)
    }
}
