import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class AgentRegionSnappingTests: XCTestCase {
    private func region(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DialogueRegion {
        DialogueRegion(
            bounds: NormalizedRect(x: x, y: y, width: w, height: h),
            sourceText: "台詞",
            confidence: 1
        )
    }

    private func detection(
        _ x: Double, _ y: Double, _ w: Double, _ h: Double
    ) -> BubbleDetection {
        BubbleDetection(
            bounds: NormalizedRect(x: x, y: y, width: w, height: h),
            maskPolygons: [[
                NormalizedPoint(x: x, y: y), NormalizedPoint(x: x + w, y: y),
                NormalizedPoint(x: x + w, y: y + h), NormalizedPoint(x: x, y: y + h)
            ]],
            layoutBounds: NormalizedRect(
                x: x + w * 0.1, y: y + h * 0.1, width: w * 0.8, height: h * 0.8
            )
        )
    }

    /// Agent 的鬆框要收斂到偵測框，並帶回氣泡形狀與排版框。
    func testLooseAgentBoundsSnapToDetection() {
        let loose = region(0.40, 0.58, 0.55, 0.12)
        let tight = detection(0.454, 0.627, 0.469, 0.036)
        let snapped = MangaAgentRegionSnapper.snapped(regions: [loose], to: [tight])

        XCTAssertEqual(snapped[0].bounds.width, 0.469, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].bounds.height, 0.036, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].bubbleBounds?.width ?? 0, 0.469, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].bubbleMaskPolygons.count, 1)
        XCTAssertNotNil(snapped[0].bubbleLayoutBounds)
        XCTAssertEqual(snapped[0].sourceText, "台詞", "原文不可被覆寫")
    }

    /// Agent 只框到整條招牌的前半段時，也要收斂到完整的偵測框。
    /// 漏配的後果不是「維持原樣」，而是遮罩只蓋住前半段，後面的字留在畫面上。
    func testUndersizedAgentBoundsAlsoSnap() {
        let partial = region(0.45, 0.62, 0.27, 0.05)
        let whole = detection(0.431, 0.609, 0.502, 0.090)
        let snapped = MangaAgentRegionSnapper.snapped(regions: [partial], to: [whole])

        XCTAssertEqual(snapped[0].bounds.width, 0.502, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].bounds.x, 0.431, accuracy: 1e-9)
        XCTAssertFalse(snapped[0].bubbleMaskPolygons.isEmpty)
    }

    /// 無框台詞與擬聲字不會有對應的偵測框，必須原樣保留。
    func testUnmatchedRegionKeepsAgentBounds() {
        let sfx = region(0.05, 0.05, 0.1, 0.1)
        let elsewhere = detection(0.7, 0.7, 0.2, 0.2)
        let snapped = MangaAgentRegionSnapper.snapped(regions: [sfx], to: [elsewhere])

        XCTAssertEqual(snapped[0].bounds.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].bounds.width, 0.1, accuracy: 1e-9)
        XCTAssertTrue(snapped[0].bubbleMaskPolygons.isEmpty)
    }

    /// 一個粗框罩住兩顆對話框時，只能配走其中一顆，不可兩個區域都搶到同一顆。
    func testEachDetectionIsClaimedOnce() {
        let left = region(0.05, 0.05, 0.5, 0.3)
        let right = region(0.30, 0.05, 0.5, 0.3)
        let onlyOne = detection(0.32, 0.08, 0.1, 0.1)
        let snapped = MangaAgentRegionSnapper.snapped(regions: [left, right], to: [onlyOne])

        let claimed = snapped.filter { !$0.bubbleMaskPolygons.isEmpty }
        XCTAssertEqual(claimed.count, 1)
    }

    /// 粗框只框住對話框一小角時不算同一顆，不可硬套。
    func testPartialOverlapDoesNotSnap() {
        let sliver = region(0.0, 0.0, 0.32, 0.32)
        let bubble = detection(0.3, 0.3, 0.3, 0.3)
        let snapped = MangaAgentRegionSnapper.snapped(regions: [sliver], to: [bubble])

        XCTAssertTrue(snapped[0].bubbleMaskPolygons.isEmpty)
        XCTAssertEqual(snapped[0].bounds.width, 0.32, accuracy: 1e-9)
    }
}
