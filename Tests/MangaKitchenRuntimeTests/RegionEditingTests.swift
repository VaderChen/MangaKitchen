import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

/// App 與 MCP 共用同一份「套用欄位 → 要不要重新精修」的判斷。
/// 這些測試鎖住的就是那份判斷 —— 兩邊過去各有一份，漂移後同一張圖會得到不同遮罩。
final class RegionEditingTests: XCTestCase {
    private func makeRegion() -> DialogueRegion {
        DialogueRegion(
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            bubbleBounds: NormalizedRect(x: 0.09, y: 0.09, width: 0.22, height: 0.22),
            sourceText: "原文",
            confidence: 1,
            maskPolygons: [[
                NormalizedPoint(x: 0.11, y: 0.11), NormalizedPoint(x: 0.2, y: 0.11),
                NormalizedPoint(x: 0.2, y: 0.2), NormalizedPoint(x: 0.11, y: 0.2)
            ]],
            maskRefinementApplied: true,
            maskCoverageComplete: true
        )
    }

    /// 粗框改變後，舊的像素遮罩已經不代表現況，必須作廢並重新精修。
    func testChangingBoundsInvalidatesMask() {
        var region = makeRegion()
        var edit = RegionEdit()
        edit.bounds = NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)

        XCTAssertTrue(PageRegionEditor.apply(edit, to: &region))
        XCTAssertTrue(region.maskPolygons.isEmpty)
        XCTAssertFalse(region.maskRefinementApplied)
        XCTAssertFalse(region.maskCoverageComplete)
    }

    /// 原文會決定「每字面積」的合理性判斷，改了同樣要重算。
    func testChangingSourceTextInvalidatesMask() {
        var region = makeRegion()
        var edit = RegionEdit()
        edit.sourceText = "換成完全不同的一段台詞"

        XCTAssertTrue(PageRegionEditor.apply(edit, to: &region))
        XCTAssertTrue(region.maskPolygons.isEmpty)
        XCTAssertEqual(region.rawSourceText, "原文", "原始原文要保留供還原")
        XCTAssertEqual(region.translatedText, "", "原文改了就清掉舊譯文")
    }

    /// 清掉對話框代表沒有硬邊界，搜尋範圍改變，一樣要重算。
    func testClearingBubbleBoundsInvalidatesMask() {
        var region = makeRegion()
        var edit = RegionEdit()
        edit.bubbleBounds = .clear

        XCTAssertTrue(PageRegionEditor.apply(edit, to: &region))
        XCTAssertNil(region.bubbleBounds)
        XCTAssertTrue(region.maskPolygons.isEmpty)
    }

    /// 純排版欄位不影響遮罩，不可害整個區域重跑精修。
    func testStyleOnlyEditKeepsMask() {
        var region = makeRegion()
        var edit = RegionEdit()
        edit.fontName = "Noto Sans TC"
        edit.writingDirection = .vertical
        edit.translatedText = "譯文"

        XCTAssertFalse(PageRegionEditor.apply(edit, to: &region))
        XCTAssertEqual(region.maskPolygons.count, 1)
        XCTAssertTrue(region.maskRefinementApplied)
        XCTAssertEqual(region.style.writingDirection, .vertical)
    }

    /// 字級要夾在可用範圍內，automatic 則還原成自動配適。
    func testFontSizeClampingAndReset() {
        var region = makeRegion()
        var edit = RegionEdit()
        edit.fontSize = .set(9_999)
        PageRegionEditor.apply(edit, to: &region)
        XCTAssertEqual(region.style.fontSize, 512)

        var reset = RegionEdit()
        reset.useAutomaticFontSize = true
        PageRegionEditor.apply(reset, to: &region)
        XCTAssertNil(region.style.fontSize)
    }
}
