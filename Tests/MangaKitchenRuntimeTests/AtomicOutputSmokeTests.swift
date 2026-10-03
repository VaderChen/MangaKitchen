import CoreGraphics
import Darwin
import Foundation
import MangaKitchenCore
import XCTest
@testable import MangaKitchenRuntime

final class AtomicOutputSmokeTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testFailedWriterPreservesPreviousOutputAndCleansStaging() throws {
        let root = try temporaryRoot()
        let output = root.appendingPathComponent("page.png")
        let original = Data("previous output".utf8)
        try original.write(to: output)
        XCTAssertThrowsError(try AtomicFileWriter.write(to: output) { staged in
            try Data("partial output".utf8).write(to: staged)
            throw CancellationError()
        })
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.png"])
    }

    func testSuccessfulWriterReplacesPreviousOutput() throws {
        let root = try temporaryRoot()
        let output = root.appendingPathComponent("page.png")
        try Data([1]).write(to: output)
        try AtomicFileWriter.write(to: output) { try Data([2, 3]).write(to: $0) }
        XCTAssertEqual(try Data(contentsOf: output), Data([2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.png"])
    }

    func testCommitFailurePreservesDestinationDirectory() throws {
        let root = try temporaryRoot()
        let output = root.appendingPathComponent("page.png")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data([1]).write(to: output.appendingPathComponent("keep"))
        XCTAssertThrowsError(try AtomicFileWriter.write(to: output) { try Data([2]).write(to: $0) })
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("keep")), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.png"])
    }

    func testCopyPreservesBytesAcrossChunksAndReplacesOldOutput() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("preview.png")
        let output = root.appendingPathComponent("output.png")
        let pattern = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 31) })
        var original = Data()
        for _ in 0..<33 { original.append(pattern) }
        original.append(contentsOf: [0, 255, 1])
        try original.write(to: source)
        try Data([42]).write(to: output)

        try AtomicFileWriter.copy(from: source, to: output)

        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["preview.png", "output.png"])
    }

    func testCopyOfEmptyFileCreatesNestedOutput() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("empty")
        let output = root.appendingPathComponent("nested/output")
        try Data().write(to: source)
        try AtomicFileWriter.copy(from: source, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data())
    }

    func testCopyReadsSymbolicLinkContentsWithoutLinkingOutput() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("preview.png")
        let link = root.appendingPathComponent("link.png")
        let output = root.appendingPathComponent("output.png")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try AtomicFileWriter.copy(from: link, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3]))
        XCTAssertEqual(try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        try Data([9]).write(to: output)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testCopyToSameFileDoesNotTruncateSource() throws {
        let url = try temporaryRoot().appendingPathComponent("preview.png")
        let original = Data([1, 2, 3, 4])
        try original.write(to: url)
        try AtomicFileWriter.copy(from: url, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnreadableCopySourcePreservesOldOutputAndCleansStaging() throws {
        let root = try temporaryRoot()
        let output = root.appendingPathComponent("output.png")
        try Data([42]).write(to: output)
        for source in [root.appendingPathComponent("missing.png"), root] {
            XCTAssertThrowsError(try AtomicFileWriter.copy(from: source, to: output))
            XCTAssertEqual(try Data(contentsOf: output), Data([42]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["output.png"])
        }
    }

    func testCancelledCopyPreservesOldOutput() async throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("preview.png")
        let output = root.appendingPathComponent("output.png")
        try Data([1, 2, 3]).write(to: source)
        try Data([42]).write(to: output)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AtomicFileWriter.copy(from: source, to: output)
        }
        do { try await task.value; XCTFail("取消不得替換輸出") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: output), Data([42]))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["preview.png", "output.png"])
    }

    func testPNGOutputCanBeDecodedAfterAtomicReplacement() throws {
        let output = try temporaryRoot().appendingPathComponent("nested/page.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        try CGImageIO.writePNG(image, to: output)
        try CGImageIO.writePNG(image, to: output)
        let loaded = try CGImageIO.load(from: output)
        XCTAssertEqual(loaded.width, 8)
        XCTAssertEqual(loaded.height, 8)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), ["page.png"])
    }

    func testCancelledCallerStillAllowsWorkerTerminationGracePeriod() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo ready; exec /bin/sleep 30"]
        let ready = Pipe()
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            try? ready.fileHandleForReading.close()
        }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        let start = Date()
        let cleanup = Task { await QwenExternalImageEditRuntime.terminate(process) }
        cleanup.cancel()
        await cleanup.value
        XCTAssertFalse(process.isRunning)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.8)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }
}
