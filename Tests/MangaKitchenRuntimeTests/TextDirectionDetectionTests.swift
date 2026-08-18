import CoreGraphics
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

final class TextDirectionDetectionTests: XCTestCase {
    /// 依格線排出字形方塊。`columns` 是橫向字數，`rows` 是縱向字數。
    private func glyphGrid(
        columns: Int,
        rows: Int,
        glyph: Double = 20,
        columnSpacing: Double,
        rowSpacing: Double
    ) -> [CGRect] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGRect(
                    x: Double(column) * columnSpacing,
                    y: Double(row) * rowSpacing,
                    width: glyph,
                    height: glyph
                )
            }
        }
    }

    func testSingleColumnIsVertical() {
        let boxes = glyphGrid(columns: 1, rows: 5, columnSpacing: 0, rowSpacing: 22)
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .vertical)
    }

    func testSingleLineIsHorizontal() {
        let boxes = glyphGrid(columns: 5, rows: 1, columnSpacing: 22, rowSpacing: 0)
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .horizontal)
    }

    /// 多欄直排的整體外框比高還寬，長寬比規則會誤判成橫排。
    func testWideMultiColumnBlockIsStillVertical() {
        let boxes = glyphGrid(columns: 4, rows: 3, columnSpacing: 24, rowSpacing: 22)
        let bounds = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        XCTAssertLessThan(bounds.height / bounds.width, 0.8, "這個排列正是長寬比規則會判錯的形狀")
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .vertical)
    }

    /// 多行橫排的整體外框接近正方，長寬比規則會誤判成直排。
    func testTallMultiLineBlockIsStillHorizontal() {
        let boxes = glyphGrid(columns: 4, rows: 3, columnSpacing: 22, rowSpacing: 26)
        let bounds = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        XCTAssertGreaterThan(bounds.height / bounds.width, 0.8, "這個排列正是長寬比規則會判錯的形狀")
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .horizontal)
    }

    /// 偏旁被拆成兩個元件時仍要先併回同一個字，否則會投出方向相反的票。
    func testSplitRadicalsDoNotFlipDirection() {
        let boxes = (0..<5).flatMap { row -> [CGRect] in
            let y = Double(row) * 22
            return [
                CGRect(x: 0, y: y, width: 9, height: 20),
                CGRect(x: 11, y: y, width: 9, height: 20)
            ]
        }
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .vertical)
    }

    func testSingleGlyphIsUndecided() {
        let boxes = [CGRect(x: 0, y: 0, width: 20, height: 20)]
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: boxes), .automatic)
    }

    func testEmptyInputIsUndecided() {
        XCTAssertEqual(MangaTextDirectionDetector.direction(forGlyphBoxes: []), .automatic)
    }
}
