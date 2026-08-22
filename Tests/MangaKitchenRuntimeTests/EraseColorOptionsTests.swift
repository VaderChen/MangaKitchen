import Foundation
import XCTest
import MangaKitchenCore

final class EraseColorOptionsTests: XCTestCase {
    func testAutomaticEraseColorIsTheDefaultAndSurvivesDecoding() throws {
        XCTAssertEqual(
            ProcessingOptions().eraseColorHex,
            ProcessingOptions.automaticEraseColor
        )

        let decoded = try JSONDecoder().decode(
            ProcessingOptions.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(decoded.eraseColorHex, ProcessingOptions.automaticEraseColor)
    }

    func testAutomaticSentinelDoesNotReplaceExplicitPaperColors() {
        XCTAssertEqual(
            ProcessingOptions(eraseColorHex: " auto ").eraseColorHex,
            ProcessingOptions.automaticEraseColor
        )
        XCTAssertEqual(ProcessingOptions(eraseColorHex: "#fff").eraseColorHex, "#FFFFFF")
        XCTAssertEqual(ProcessingOptions(eraseColorHex: "#E8DFC8").eraseColorHex, "#E8DFC8")
    }
}
