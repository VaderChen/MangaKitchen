import AppKit
import Foundation
import ImageIO
import XCTest
@testable import MangaKitchenApp

final class PSDExporterTests: XCTestCase {
    private func outputURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("page.psd")
    }

    func testOutputMatchesLegacyBytesIncludingAlphaLayerOrderAndNames() throws {
        let output = try outputURL()
        let bottom = try image(width: 2, height: 3, seed: 0)
        let top = try image(width: 2, height: 3, seed: 1)
        try PSDExporter().write(layers: [
            PSDLayer(name: "底圖", image: bottom, opacity: 255, visible: true),
            PSDLayer(name: "Ink 1", image: top, opacity: 137, visible: false),
        ], mergedImage: bottom, to: output)

        // 519ebc2 的原始 exporter 產生；涵蓋透明／半透明像素、非正方形與 UTF-8 圖層名。
        let expected = try XCTUnwrap(Data(base64Encoded:
            "OEJQUwABAAAAAAAAAAQAAAADAAAAAgAIAAMAAAAAAAAAAAAAAN4AAADWAAIAAAAAAAAAAAAAAAMAAAACAAQAAAAAAAgAAQAAAAgAAgAAAAj//wAAAAg4QklNbm9ybYkAAgAAAAAQAAAAAAAAAAAFSW5rIDEAAAAAAAAAAAAAAAAAAwAAAAIABAAAAAAACAABAAAACAACAAAACP//AAAACDhCSU1ub3Jt/wAAAAAAABAAAAAAAAAAAAblupXlnJYAAABRACBfCycAAHMAJFMHFAAAGwAKSQMhAAD/AID/QIAAABFBBBgABwAAK2EKGwACAAAHQwEeAA0AAID/QIAAQAAAAAAAABFBBBgABythChsAAgdDAR4ADYD/QIAAQA=="))
        XCTAssertEqual(try Data(contentsOf: output), expected)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 3)
    }

    func testLargeChannelBoundaryAndFinalPartialChunkPreserveEveryPixel() throws {
        let output = try outputURL()
        let width = 257
        let height = 257
        let source = try image(width: width, height: height, seed: 0)
        try PSDExporter().write(layers: [PSDLayer(name: "A", image: source, opacity: 255, visible: true)],
            mergedImage: source, to: output)
        let data = try Data(contentsOf: output)
        func uint32(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let mergedStart = 38 + uint32(at: 34)
        let pixelCount = width * height
        XCTAssertEqual(data.count, mergedStart + 2 + pixelCount * 4)
        XCTAssertEqual(Array(data[mergedStart..<(mergedStart + 2)]), [0, 0])
        let layerInfoEnd = 42 + uint32(at: 38)
        let layerChannelsStart = layerInfoEnd - 4 * (pixelCount + 2)
        for channel in 0..<4 {
            let layerChannel = layerChannelsStart + channel * (pixelCount + 2)
            XCTAssertEqual(Array(data[layerChannel..<(layerChannel + 2)]), [0, 0])
            let expected = Data((0..<pixelCount).map { offset in
                let x = offset % width
                let y = height - 1 - offset / width
                return pixel(x: x, y: y, seed: 0)[channel]
            })
            XCTAssertEqual(data[(layerChannel + 2)..<(layerChannel + 2 + pixelCount)], expected)
            let mergedChannel = mergedStart + 2 + channel * pixelCount
            XCTAssertEqual(data[mergedChannel..<(mergedChannel + pixelCount)], expected)
        }
    }

    func testInvalidLayersPreservePreviousOutput() throws {
        let output = try outputURL()
        let original = Data([1, 2, 3])
        try original.write(to: output)
        let source = try image(width: 2, height: 3, seed: 0)
        let mismatch = try image(width: 3, height: 2, seed: 0)
        XCTAssertThrowsError(try PSDExporter().write(layers: [], mergedImage: source, to: output))
        XCTAssertThrowsError(try PSDExporter().write(layers: [
            PSDLayer(name: "A", image: mismatch, opacity: 255, visible: true),
        ], mergedImage: source, to: output))
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testCancelledExportPreservesPreviousOutputAndCleansStaging() async throws {
        let output = try outputURL()
        try Data([42]).write(to: output)
        let source = try image(width: 2, height: 3, seed: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PSDExporter().write(layers: [PSDLayer(name: "A", image: source, opacity: 255, visible: true)],
                mergedImage: source, to: output)
        }
        do { try await task.value; XCTFail("取消不得替換輸出") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: output), Data([42]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path),
            ["page.psd"])
    }

    private func pixel(x: Int, y: Int, seed: Int) -> [UInt8] {
        let alpha = [0, 64, 128, 255][(x + y + seed) % 4]
        return [
            UInt8((x * 31 + y * 17 + seed * 47) % 256 * alpha / 255),
            UInt8((x * 11 + y * 43 + seed * 29) % 256 * alpha / 255),
            UInt8((x * 53 + y * 7 + seed * 13) % 256 * alpha / 255),
            UInt8(alpha),
        ]
    }

    private func image(width: Int, height: Int, seed: Int) throws -> CGImage {
        var bytes = Data()
        for y in 0..<height {
            for x in 0..<width { bytes.append(contentsOf: pixel(x: x, y: y, seed: seed)) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
