import CoreGraphics
import Foundation
import XCTest
@testable import MangaKitchenCore
@testable import MangaKitchenRuntime

final class RegionDetectionSafetyTests: XCTestCase {
    func testLargeRectangularPanelIsNotBubbleCandidate() throws {
        let image = try makeImage(width: 600, height: 600) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 180, y: 180, width: 240, height: 180))
        }

        let candidates = try MangaBubbleCandidateDetector().detect(in: image)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testCurvedClosedBubbleRemainsCandidate() throws {
        let image = try makeImage(width: 600, height: 600) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: CGRect(x: 220, y: 240, width: 160, height: 110))
        }

        let candidates = try MangaBubbleCandidateDetector().detect(in: image)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertLessThan(candidates[0].width * candidates[0].height, 0.08)
    }

    func testIncompleteRefinedMaskStillRendersSafePolygons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-MaskSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let outputURL = directory.appendingPathComponent("mask.png")
        let source = try makeImage(width: 128, height: 128) { _ in }
        try CGImageIO.writePNG(source, to: sourceURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            sourceText: "test",
            confidence: 1,
            automaticMaskEnabled: true,
            maskPolygons: [[
                NormalizedPoint(x: 0.2, y: 0.2),
                NormalizedPoint(x: 0.25, y: 0.2),
                NormalizedPoint(x: 0.25, y: 0.25),
                NormalizedPoint(x: 0.2, y: 0.25)
            ]],
            maskRefinementApplied: true,
            maskCoverageRatio: 0.95,
            maskCoverageComplete: false
        )

        try await DialogueMaskGenerator().generateMask(
            sourceURL: sourceURL,
            regions: [region],
            expansion: 0.035,
            outputURL: outputURL
        )

        let mask = try CGImageIO.load(from: outputURL)
        XCTAssertEqual(Set(try grayscalePixels(from: mask)), Set([UInt8(0), UInt8(255)]))
    }

    func testBoundaryDiagnosticDoesNotDisablePlausibleMask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-MaskBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let source = try makeImage(width: 128, height: 128) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 56, width: 8, height: 8))
        }
        try CGImageIO.writePNG(source, to: sourceURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            sourceText: "test",
            confidence: 1,
            automaticMaskEnabled: false
        )
        let refined = try await MangaTextMaskRefiner().refineMasks(
            sourceURL: sourceURL,
            regions: [region]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertFalse(refined[0].maskPolygons.isEmpty)
        XCTAssertFalse(refined[0].maskCoverageComplete)
        XCTAssertTrue(refined[0].automaticMaskEnabled)
    }

    func testVLMGroundingMapsCropCoordinatesBackToPage() {
        let bounds = VLMTextGrounding.pageBounds(
            modelBoxes: [[250, 250, 750, 750]],
            cropRect: CGRect(x: 100, y: 200, width: 400, height: 200),
            imageWidth: 1_000,
            imageHeight: 1_000,
            clippingBounds: nil,
            paddingFraction: 0
        )

        XCTAssertEqual(bounds?.x ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.y ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.width ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(bounds?.height ?? -1, 0.1, accuracy: 0.000_001)
    }

    func testVLMGroundingBoxAcceptsArrayAndQwenObjectFormats() throws {
        let data = Data(#"[[250,250,750,750],{"bbox_2d":[100,200,300,400]}]"#.utf8)
        let boxes = try JSONDecoder().decode([VLMGroundingBox].self, from: data)

        XCTAssertEqual(boxes.map(\.coordinates), [
            [250, 250, 750, 750],
            [100, 200, 300, 400]
        ])
    }

    func testStructuredResponseDecoderAcceptsSingleJSONObject() {
        struct Item: Decodable {
            var index: Int
        }

        let decoded = VLMStructuredResponseDecoder.decodeArrays(
            Item.self,
            from: """
            ```json
            {"index":1}
            ```
            """
        )

        XCTAssertEqual(decoded.first?.first?.index, 1)
    }

    func testLocalMaskExpansionDoesNotScanEntireBubble() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-MaskLocality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let source = try makeImage(width: 256, height: 256) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(gray: 0, alpha: 1)
            // 粗框右緣的字形，會觸發局部擴張。
            context.fill(CGRect(x: 58, y: 120, width: 9, height: 8))
            // 同一氣泡內遠處的插畫線條，不可被精修搜尋。
            context.fill(CGRect(x: 200, y: 120, width: 12, height: 12))
        }
        try CGImageIO.writePNG(source, to: sourceURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0.2, y: 0.45, width: 0.05, height: 0.05),
            bubbleBounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6),
            sourceText: "abcdefghijklmnopqrst",
            confidence: 1,
            automaticMaskEnabled: false
        )
        let refined = try await MangaTextMaskRefiner().refineMasks(
            sourceURL: sourceURL,
            regions: [region]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertFalse(refined[0].maskPolygons.isEmpty)
        let maximumX = refined[0].maskPolygons.flatMap { $0 }.map(\.x).max() ?? 1
        XCTAssertLessThan(maximumX, 0.4)
    }

    func testWidePanelLineIsRejectedAsTextMask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-MaskWideLine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let source = try makeImage(width: 256, height: 256) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 18, y: 122, width: 220, height: 10))
        }
        try CGImageIO.writePNG(source, to: sourceURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0.05, y: 0.4, width: 0.9, height: 0.2),
            sourceText: "short",
            confidence: 1,
            automaticMaskEnabled: false
        )
        let refined = try await MangaTextMaskRefiner().refineMasks(
            sourceURL: sourceURL,
            regions: [region]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertTrue(refined[0].maskPolygons.isEmpty)
        XCTAssertFalse(refined[0].automaticMaskEnabled)
    }

    func testLargeSpokenAttackTextRemainsMaskable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-MaskSpokenAttack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let source = try makeImage(width: 400, height: 400) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            context.setFillColor(gray: 0, alpha: 1)
            for offset in 0..<10 {
                context.fill(CGRect(x: 80 + offset * 20, y: 185, width: 12, height: 24))
            }
        }
        try CGImageIO.writePNG(source, to: sourceURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0.18, y: 0.44, width: 0.55, height: 0.12),
            sourceText: "超精密溶接アタック!",
            confidence: 1,
            automaticMaskEnabled: false
        )
        let refined = try await MangaTextMaskRefiner().refineMasks(
            sourceURL: sourceURL,
            regions: [region]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertFalse(refined[0].maskPolygons.isEmpty)
        XCTAssertTrue(refined[0].automaticMaskEnabled)
    }

    func testDefaultWritingDirectionIsAutomatic() {
        XCTAssertEqual(ProcessingOptions().defaultStyle.writingDirection, .automatic)
    }

    private func makeImage(
        width: Int,
        height: Int,
        drawing: (CGContext) -> Void
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawing(context)
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
    }

    private func grayscalePixels(from image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }
}
