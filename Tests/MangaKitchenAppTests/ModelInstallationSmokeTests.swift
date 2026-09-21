import Foundation
import MangaKitchenCore
import XCTest
@testable import MangaKitchenApp

final class ModelInstallationSmokeTests: XCTestCase {
    private func directories(existing: Bool = true) throws -> (root: URL, staged: URL, installed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staged = root.appendingPathComponent("staged")
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("weights"))
        if existing {
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: installed.appendingPathComponent("weights"))
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, staged, installed)
    }

    func testInstallNewDirectory() throws {
        let paths = try directories(existing: false)
        try RecoverableDirectoryInstaller.install(from: paths.staged, to: paths.installed) { _ in }
        XCTAssertEqual(try Data(contentsOf: paths.installed.appendingPathComponent("weights")), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.root.path), ["installed"])
    }

    func testReplacementCleansOldDirectoryOnlyAfterValidation() throws {
        let paths = try directories()
        try RecoverableDirectoryInstaller.install(from: paths.staged, to: paths.installed) { directory in
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("weights")), Data("new".utf8))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.root.path), ["installed"])
    }

    func testInvalidCandidateNeverRemovesOldDirectory() throws {
        let paths = try directories()
        XCTAssertThrowsError(try RecoverableDirectoryInstaller.install(from: paths.staged, to: paths.installed) { _ in
            throw CancellationError()
        })
        XCTAssertEqual(try Data(contentsOf: paths.installed.appendingPathComponent("weights")), Data("old".utf8))
    }

    func testPostInstallFailureRestoresBothDirectories() throws {
        let paths = try directories()
        XCTAssertThrowsError(try RecoverableDirectoryInstaller.install(from: paths.staged, to: paths.installed) { directory in
            if directory == paths.installed { throw CancellationError() }
        })
        XCTAssertEqual(try Data(contentsOf: paths.installed.appendingPathComponent("weights")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.staged.appendingPathComponent("weights")), Data("new".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: paths.root.path)), ["staged", "installed"])
    }

    func testCancelledInstallDoesNotModifyEitherVersion() async throws {
        let paths = try directories()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try RecoverableDirectoryInstaller.install(from: paths.staged, to: paths.installed) { _ in }
        }
        do { try await task.value; XCTFail("取消不得安裝") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: paths.installed.appendingPathComponent("weights")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.staged.appendingPathComponent("weights")), Data("new".utf8))
    }

    func testOverlappingDirectoryInstallationIsRejected() throws {
        let paths = try directories()
        for target in [paths.staged, paths.staged.appendingPathComponent("child"), paths.root] {
            XCTAssertThrowsError(try RecoverableDirectoryInstaller.install(from: paths.staged, to: target) { _ in })
        }
        XCTAssertEqual(try Data(contentsOf: paths.staged.appendingPathComponent("weights")), Data("new".utf8))
    }

    func testRevisionMustBePinnedAndConsistent() throws {
        let commit = String(repeating: "a", count: 40)
        XCTAssertEqual(try ModelDownloadValidation.pinnedRevision(commit), commit)
        XCTAssertEqual(try ModelDownloadValidation.pinnedRevision(commit, previous: commit), commit)
        for value in [nil, "main", "../main", String(repeating: "g", count: 40)] {
            XCTAssertThrowsError(try ModelDownloadValidation.pinnedRevision(value))
        }
        XCTAssertThrowsError(try ModelDownloadValidation.pinnedRevision(String(repeating: "b", count: 40), previous: commit))
    }

    func testTotalSizeRejectsNegativeAndOverflowingMetadata() throws {
        XCTAssertEqual(try ModelDownloadValidation.totalByteCount([0, 2, 3]), 5)
        XCTAssertEqual(try ModelDownloadValidation.totalByteCount([Int64.max]), Int64.max)
        XCTAssertThrowsError(try ModelDownloadValidation.totalByteCount([Int64.max, 1]))
        XCTAssertThrowsError(try ModelDownloadValidation.totalByteCount([-1, 2]))
    }

    func testContentRangeRequiresExactOffsetsAndTotal() {
        XCTAssertTrue(ModelDownloadValidation.acceptsResponse(statusCode: 206, contentRange: "bytes 0-3/8", start: 0, end: 3, total: 8, usesRange: true))
        for range in [nil, "bytes 0-3/9", "bytes 0-3/*", "bytes 0-3/8junk", "bytes 1-4/8"] {
            XCTAssertFalse(ModelDownloadValidation.acceptsResponse(statusCode: 206, contentRange: range, start: 0, end: 3, total: 8, usesRange: true))
        }
        XCTAssertFalse(ModelDownloadValidation.acceptsResponse(statusCode: 200, contentRange: "bytes 0-3/8", start: 0, end: 3, total: 8, usesRange: true))
    }

    func testWholeFileRequiresSuccessfulCompleteResponse() {
        XCTAssertTrue(ModelDownloadValidation.acceptsResponse(statusCode: 200, contentRange: nil, start: 0, end: 7, total: 8, usesRange: false))
        XCTAssertFalse(ModelDownloadValidation.acceptsResponse(statusCode: 206, contentRange: "bytes 0-7/8", start: 0, end: 7, total: 8, usesRange: false))
        XCTAssertFalse(ModelDownloadValidation.acceptsResponse(statusCode: 200, contentRange: nil, start: 0, end: 3, total: 8, usesRange: false))
    }
}
