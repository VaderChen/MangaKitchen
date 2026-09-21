import Foundation
import MangaKitchenCore
import MangaKitchenRuntime
import XCTest
@testable import MangaKitchenApp

final class PersistenceBoundarySmokeTests: XCTestCase {
    private let future = Data(#"{"schemaVersion":999,"futureOnly":true}"#.utf8)

    private func fileURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(name)
    }

    private func expectUnsupported(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("新版 schema 不得回退或覆寫", file: file, line: line) }
        catch { XCTAssertTrue(error is any NonRecoverableFileError, "\(error)", file: file, line: line) }
    }

    func testFutureWorkspaceIsNotReplacedByHealthyOldBackup() async throws {
        let url = try fileURL("project.json")
        let repository = WorkspaceRepository(fileURL: url)
        let snapshot = WorkspaceSnapshot(name: "舊版", options: .init(), pages: [], selectedPageID: nil, modelDirectories: [])
        try await repository.save(snapshot)
        try await repository.save(snapshot)
        let backup = try Data(contentsOf: url.appendingPathExtension("bak"))
        try future.write(to: url)
        await expectUnsupported { _ = try await repository.load() }
        await expectUnsupported { try await repository.save(snapshot) }
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), backup)
    }

    func testFutureLibraryIsNotReplacedByHealthyOldBackup() async throws {
        let url = try fileURL("library.json")
        let repository = ProjectLibraryRepository(fileURL: url)
        let snapshot = ProjectLibrarySnapshot(activeProjectID: nil, projects: [])
        try await repository.save(snapshot)
        try await repository.save(snapshot)
        let backup = try Data(contentsOf: url.appendingPathExtension("bak"))
        try future.write(to: url)
        await expectUnsupported { _ = try await repository.load() }
        await expectUnsupported { try await repository.save(snapshot) }
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), backup)
    }

    func testFutureStringTableHeaderIsCheckedBeforeItsChangedFields() async throws {
        let url = try fileURL("page.str")
        let repository = ComicStringTableRepository()
        let table = ComicStringTable(sourceRelativePath: "page.png", pixelWidth: 8,
            pixelHeight: 8, targetLanguageCode: "zh-Hant", entries: [])
        try await repository.save(table, to: url)
        try await repository.save(table, to: url)
        let backup = try Data(contentsOf: url.appendingPathExtension("bak"))
        try future.write(to: url)
        await expectUnsupported { _ = try await repository.load(from: url) }
        await expectUnsupported { try await repository.save(table, to: url) }
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), backup)
    }

    func testMalformedSupportedSchemaStillRecoversBackup() async throws {
        let url = try fileURL("project.json")
        let repository = WorkspaceRepository(fileURL: url)
        let snapshot = WorkspaceSnapshot(name: "可復原", options: .init(), pages: [], selectedPageID: nil, modelDirectories: [])
        try await repository.save(snapshot)
        try await repository.save(snapshot)
        try Data(#"{"schemaVersion":4,"pages":"broken"}"#.utf8).write(to: url)
        let restored = try await repository.load()
        XCTAssertEqual(restored?.name, "可復原")
        try await repository.save(snapshot)
    }

    func testLegacyLibraryWithoutSchemaStillLoads() async throws {
        let url = try fileURL("library.json")
        try Data(#"{"projects":[]}"#.utf8).write(to: url)
        let restored = try await ProjectLibraryRepository(fileURL: url).load()
        XCTAssertEqual(restored?.schemaVersion, 1)
        XCTAssertEqual(restored?.projects.count, 0)
    }

    func testCancelledSaveDoesNotRotateOrOverwriteFiles() async throws {
        let url = try fileURL("data")
        try Data([1]).write(to: url)
        try Data([0]).write(to: url.appendingPathExtension("bak"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try RecoverableFile.save(Data([2]), to: url) { _ in }
        }
        do { try await task.value; XCTFail("取消不得寫入") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), Data([0]))
    }

    func testReadFailureCannotReplacePrimaryDirectory() throws {
        let url = try fileURL("data")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data([1]).write(to: url.appendingPathComponent("keep"))
        XCTAssertThrowsError(try RecoverableFile.save(Data([2]), to: url) { _ in })
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("keep")), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testCancellationDuringInstallRestoresOldVersion() async throws {
        let destination = try fileURL("installed")
        let staged = destination.deletingLastPathComponent().appendingPathComponent("staged")
        for url in [destination, staged] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data([1]).write(to: destination.appendingPathComponent("weights"))
        try Data([2]).write(to: staged.appendingPathComponent("weights"))
        let task = Task {
            try RecoverableDirectoryInstaller.install(from: staged, to: destination) { url in
                if url == destination { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await task.value; XCTFail("取消不得提交") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("weights")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("weights")), Data([2]))
    }

    func testGateHandlesMixedCancellationWithoutLeakingPermit() async throws {
        let gate = AsyncOperationGate()
        let counter = GateStressCounter()
        let tasks = (0..<100).map { _ in
            Task {
                try await gate.withPermit {
                    await counter.enter()
                    await Task.yield()
                    await counter.leave()
                }
            }
        }
        for index in tasks.indices where index.isMultiple(of: 2) { tasks[index].cancel() }
        for task in tasks {
            do { try await task.value } catch is CancellationError {} catch { XCTFail("\(error)") }
        }
        let peak = await counter.peak
        let active = await counter.active
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(active, 0)
        let result = try await gate.withPermit { 42 }
        XCTAssertEqual(result, 42)
    }
}

private actor GateStressCounter {
    private(set) var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
