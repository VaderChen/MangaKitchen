import CoreGraphics
import Foundation
import MangaKitchenCore
import XCTest
@testable import MangaKitchenApp
@testable import MangaKitchenRuntime

final class ScanMergeSmokeTests: XCTestCase {
    private func scan(_ path: String, root: String = "/fixture") -> ScannedComicPage {
        ScannedComicPage(sourceURL: URL(fileURLWithPath: root).appendingPathComponent(path),
            relativePath: path, pixelWidth: 8, pixelHeight: 8)
    }

    private func page(_ path: String, title: String? = nil) -> ComicPage {
        let item = scan(path)
        return ComicPage(index: 1, title: title ?? item.sourceURL.deletingPathExtension().lastPathComponent,
            sourceURL: item.sourceURL, relativeSourcePath: path, pixelWidth: 8, pixelHeight: 8)
    }

    func testExcludedPagesAndManualOrderSurviveRescan() {
        let first = page("002.png", title: "封面")
        let second = page("001.png")
        let result = ComicPageScanMerger.merge([scan("001.png"), scan("002.png"), scan("003.png"), scan("004.png")],
            previousPages: [first, second], excludedRelativePaths: ["003.png"])
        XCTAssertEqual(result.map(\.relativeSourcePath), ["002.png", "001.png", "004.png"])
        XCTAssertEqual(result.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.first?.title, "封面")
    }

    func testNewLookalikeCannotStealExactPageIdentity() {
        let existing = page("z/001.png", title: "人工名稱")
        let result = ComicPageScanMerger.merge([scan("a/001.png"), scan("z/001.png")], previousPages: [existing])
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertEqual(result.first?.id, existing.id)
        XCTAssertEqual(result.first?.relativeSourcePath, "z/001.png")
        XCTAssertEqual(result.first?.title, "人工名稱")
    }

    func testRelativePathPreservesIdentityAfterRootRelocation() {
        let existing = page("chapter/001.png", title: "人工名稱")
        let result = ComicPageScanMerger.merge([scan("chapter/001.png", root: "/moved")], previousPages: [existing])
        XCTAssertEqual(result.first?.id, existing.id)
        XCTAssertEqual(result.first?.title, existing.title)
        XCTAssertEqual(result.first?.sourceURL.path, "/moved/chapter/001.png")
    }

    func testUniqueMoveUsesFilenameRatherThanEditedTitle() {
        let existing = page("old/001.png", title: "人工名稱")
        let result = ComicPageScanMerger.merge([scan("new/001.png")], previousPages: [existing])
        XCTAssertEqual(result.first?.id, existing.id)
        XCTAssertEqual(result.first?.title, existing.title)
    }

    func testAmbiguousMovesDoNotTransferEditsArbitrarily() {
        let existing = page("old/001.png", title: "不可任意複製")
        let result = ComicPageScanMerger.merge([scan("a/001.png"), scan("b/001.png")], previousPages: [existing])
        XCTAssertFalse(result.contains { $0.id == existing.id })
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }

    func testDuplicateInputCannotCrashOrProduceDuplicateIDs() {
        let existing = page("001.png")
        let result = ComicPageScanMerger.merge([scan("001.png"), scan("001.png")], previousPages: [existing, existing])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, existing.id)
    }

    @MainActor
    func testMCPOpenAndRescanHonorGUIExclusionsAndOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for name in ["001.png", "002.png", "003.png"] {
            try CGImageIO.writePNG(image, to: source.appendingPathComponent(name))
        }
        var first = page("002.png", title: "封面")
        first.sourceURL = source.appendingPathComponent("002.png")
        var second = page("001.png")
        second.sourceURL = source.appendingPathComponent("001.png")
        let snapshot = WorkspaceSnapshot(name: "測試", options: .init(), pages: [first, second],
            selectedPageID: first.id, modelDirectories: [], sourceDirectoryURL: source,
            excludedSourceRelativePaths: ["003.png"])
        let environment = try MangaKitchenRuntimeEnvironment(applicationRoot: root.appendingPathComponent("app"),
            imageCompositingBackend: .cpu, modelThinkingEnabled: false, dflashEnabled: false,
            dflashBlockSize: 5, log: { _, _, _ in }, reasoningStream: { _ in })
        let service = MCPWorkflowService(runtimeEnvironment: environment, stateProvider: { _ in snapshot })
        let opened = try await service.openWorkspace(sourceDirectoryURL: source, outputDirectoryURL: nil, targetLanguageCode: nil)
        XCTAssertEqual(opened.pages.map(\.id), [first.id, second.id])
        let rescanned = try await service.rescanWorkspace(workspaceID: snapshot.projectID)
        XCTAssertEqual(rescanned.pages.map(\.id), [first.id, second.id])
        XCTAssertEqual(rescanned.pages.first?.title, "封面")
    }
}
