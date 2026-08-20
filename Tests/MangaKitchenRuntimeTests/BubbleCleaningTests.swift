import CoreGraphics
import XCTest
import MangaKitchenCore
@testable import MangaKitchenRuntime

/// 清除文字後填回去的底色必須均勻。
///
/// 取樣環若緊貼遮罩，取到的是抗鋸齒殘留而不是紙面：CPU 後端逐元件取色，
/// 每個字得到不同深淺；GPU 後端逐像素取色，得到平滑漸層。兩者都會在乾淨的
/// 對話框裡浮出一層字形鬼影。
final class BubbleCleaningTests: XCTestCase {
    private let paper: UInt8 = 200

    /// 畫一個灰底對話框，裡面若干「字」，字緣留一圈比紙面暗的抗鋸齒殘留。
    private func makePage(width: Int, height: Int) throws -> (source: URL, mask: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let glyphs = (0..<4).map { CGRect(x: 20, y: 16 + $0 * 22, width: 40, height: 14) }

        let source = try makeImage(width: width, height: height) { context in
            context.setFillColor(gray: CGFloat(paper) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for glyph in glyphs {
                // 抗鋸齒殘留：比紙面暗一階，位在字的外緣一圈。
                context.setFillColor(gray: CGFloat(paper - 40) / 255, alpha: 1)
                context.fill(glyph.insetBy(dx: -2, dy: -2))
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(glyph)
            }
        }
        let mask = try makeImage(width: width, height: height) { context in
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 1, alpha: 1)
            // 遮罩只蓋住字本身，殘留那一圈刻意留在外面。
            for glyph in glyphs { context.fill(glyph) }
        }
        let sourceURL = directory.appendingPathComponent("source.png")
        let maskURL = directory.appendingPathComponent("mask.png")
        try CGImageIO.writePNG(source, to: sourceURL)
        try CGImageIO.writePNG(mask, to: maskURL)
        return (sourceURL, maskURL, directory)
    }

    func testFilledAreaIsUniformPaperColour() async throws {
        let (sourceURL, maskURL, directory) = try makePage(width: 120, height: 120)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("cleaned.png")

        try await CPUBubbleCleaner().clean(
            sourceURL: sourceURL,
            maskURL: maskURL,
            outputURL: outputURL,
            progress: { _ in }
        )

        let cleaned = try CGImageIO.load(from: outputURL)
        let maskImage = try CGImageIO.load(from: maskURL)
        let filled = try filledLuminances(cleaned: cleaned, mask: maskImage)
        XCTAssertFalse(filled.isEmpty)

        let unique = Set(filled)
        // 每個字都要填成同一個顏色，否則就是鬼影。
        XCTAssertEqual(unique.count, 1, "填色不一致：\(unique.sorted())")
        let fill = Int(filled[0])
        XCTAssertEqual(fill, Int(paper), accuracy: 2, "填色應為紙面底色而非抗鋸齒殘留")
    }

    func testDisconnectedGlyphsInOneRegionUseOneFillColour() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Clean-Region-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeImage(width: 160, height: 100) { context in
            context.setFillColor(gray: 200.0 / 255.0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
            context.setFillColor(gray: 220.0 / 255.0, alpha: 1)
            context.fill(CGRect(x: 80, y: 0, width: 80, height: 100))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 30, y: 35, width: 16, height: 30))
            context.fill(CGRect(x: 114, y: 35, width: 16, height: 30))
        }
        let mask = try makeImage(width: 160, height: 100) { context in
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 30, y: 35, width: 16, height: 30))
            context.fill(CGRect(x: 114, y: 35, width: 16, height: 30))
        }
        let sourceURL = directory.appendingPathComponent("source.png")
        let maskURL = directory.appendingPathComponent("mask.png")
        let outputURL = directory.appendingPathComponent("cleaned.png")
        try CGImageIO.writePNG(source, to: sourceURL)
        try CGImageIO.writePNG(mask, to: maskURL)

        let region = DialogueRegion(
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            sourceText: "AB",
            confidence: 1
        )
        try await CPUBubbleCleaner().clean(
            sourceURL: sourceURL,
            maskURL: maskURL,
            regions: [region],
            outputURL: outputURL,
            progress: { _ in }
        )

        let filled = try filledLuminances(
            cleaned: try CGImageIO.load(from: outputURL),
            mask: try CGImageIO.load(from: maskURL)
        )
        XCTAssertEqual(Set(filled).count, 1, "同一文字區域不得因局部紙紋而產生多種填色")
    }

    func testConfiguredWhiteFillAlsoRemovesPaleHaloOutsideOriginalMask() async throws {
        let (sourceURL, maskURL, directory) = try makePage(width: 120, height: 120)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("cleaned-fixed-white.png")

        try await CPUBubbleCleaner().clean(
            sourceURL: sourceURL,
            maskURL: maskURL,
            fillColorHex: "#FFFFFF",
            outputURL: outputURL,
            progress: { _ in }
        )

        let cleaned = try CGImageIO.load(from: outputURL)
        let pixels = try grayscalePixels(cleaned)
        XCTAssertFalse(
            pixels.contains(where: { $0 < paper }),
            "固定白底除了原遮罩，也必須清除外圍淡灰抗鋸齒殘影"
        )
        XCTAssertTrue(pixels.contains(255), "原遮罩與淡灰 halo 應填成指定的純白色")
    }

    /// Metal kernel 是執行期以原始碼編譯的，建置成功不代表它編得起來。
    /// 這個測試同時涵蓋「shader 能編譯」與「取色不再取到抗鋸齒殘留」。
    func testGPUFilledAreaIsUniformPaperColour() async throws {
        guard let metal = try? MetalContext() else {
            throw XCTSkip("這台機器沒有可用的 Metal 裝置。")
        }
        let cleaner = try MetalBubbleCleaner(metal: metal)
        let (sourceURL, maskURL, directory) = try makePage(width: 120, height: 120)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("cleaned-gpu.png")

        try await cleaner.clean(
            sourceURL: sourceURL,
            maskURL: maskURL,
            outputURL: outputURL,
            progress: { _ in }
        )

        let filled = try filledLuminances(
            cleaned: try CGImageIO.load(from: outputURL),
            mask: try CGImageIO.load(from: maskURL)
        )
        XCTAssertFalse(filled.isEmpty)
        let low = Int(filled.min() ?? 0)
        let high = Int(filled.max() ?? 0)
        XCTAssertLessThanOrEqual(high - low, 4, "填色深淺不一（\(low)...\(high)）就是字形鬼影")
        XCTAssertEqual((low + high) / 2, Int(paper), accuracy: 4,
                       "填色應為紙面底色而非抗鋸齒殘留")
    }

    private func filledLuminances(cleaned: CGImage, mask: CGImage) throws -> [UInt8] {
        let cleanedPixels = try grayscalePixels(cleaned)
        let maskPixels = try grayscalePixels(mask)
        return zip(cleanedPixels, maskPixels).filter { $0.1 > 127 }.map(\.0)
    }

    private func grayscalePixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageProcessingError.cannotCreateBitmap }
        return pixels
    }

    private func makeImage(
        width: Int,
        height: Int,
        drawing: (CGContext) -> Void
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw ImageProcessingError.cannotCreateBitmap }
        context.setShouldAntialias(false)
        drawing(context)
        guard let image = context.makeImage() else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        return image
    }
}
