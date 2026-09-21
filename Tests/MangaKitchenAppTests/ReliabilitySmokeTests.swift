import Foundation
import XCTest
import MangaKitchenCore
import MangaKitchenApplication
import MangaKitchenRuntime
@testable import MangaKitchenApp

final class ReliabilitySmokeTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testStringTableRecoveryDoesNotOverwriteHealthyBackup() async throws {
        let url = try temporaryRoot().appendingPathComponent("page.str")
        let repository = ComicStringTableRepository()
        let table = ComicStringTable(sourceRelativePath: "page.png", pixelWidth: 100,
            pixelHeight: 100, targetLanguageCode: "zh-Hant", entries: [])
        try await repository.save(table, to: url)
        try await repository.save(table, to: url)
        let backup = url.appendingPathExtension("bak")
        let healthyData = try Data(contentsOf: backup)
        try Data("broken".utf8).write(to: url)
        let recovered = try await repository.load(from: url)
        XCTAssertEqual(recovered?.sourceRelativePath, "page.png")
        try await repository.save(table, to: url)
        XCTAssertEqual(try Data(contentsOf: backup), healthyData)
        try FileManager.default.removeItem(at: url)
        let missingPrimary = try await repository.load(from: url)
        XCTAssertEqual(missingPrimary?.sourceRelativePath, "page.png")
    }

    func testWorkspaceAndLibraryRecoverMissingPrimary() async throws {
        let root = try temporaryRoot()
        let projectURL = root.appendingPathComponent("project.json")
        let libraryURL = root.appendingPathComponent("library.json")
        let project = WorkspaceSnapshot(name: "保留專案", options: .init(), pages: [],
            selectedPageID: nil, modelDirectories: [])
        let library = ProjectLibrarySnapshot(activeProjectID: project.projectID, projects: [])
        let repository = WorkspaceRepository(fileURL: projectURL)
        let index = ProjectLibraryRepository(fileURL: libraryURL)
        try await repository.save(project)
        try await repository.save(project)
        try await index.save(library)
        try await index.save(library)
        try FileManager.default.removeItem(at: projectURL)
        try FileManager.default.removeItem(at: libraryURL)
        let restored = try await repository.load()
        let restoredLibrary = try await index.load()
        XCTAssertEqual(restored?.name, project.name)
        XCTAssertEqual(restoredLibrary?.activeProjectID, project.projectID)
    }

    func testInvalidSnapshotCannotReplaceValidFile() async throws {
        let url = try temporaryRoot().appendingPathComponent("library.json")
        let repository = ProjectLibraryRepository(fileURL: url)
        try await repository.save(.init(activeProjectID: nil, projects: []))
        let previous = try Data(contentsOf: url)
        do {
            try await repository.save(.init(schemaVersion: 999, activeProjectID: nil, projects: []))
            XCTFail("不支援的 schema 不應覆寫主檔")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), previous)
    }

    func testColorizationOutputStaysBesideTranslation() throws {
        let root = try temporaryRoot()
        let resolver = WorkflowPathResolver()
        let translated = try resolver.outputURL(relativeSourcePath: "chapter/001.jpg", outputDirectoryURL: root)
        let colorized = try resolver.colorizationOutputURL(relativeSourcePath: "chapter/001.jpg", outputDirectoryURL: root)
        XCTAssertEqual(colorized.deletingLastPathComponent(), translated.deletingLastPathComponent())
        XCTAssertEqual(colorized.lastPathComponent, "001-colorized.png")
        XCTAssertNotNil(FilePathBoundary.canonicalURL(root))
        XCTAssertTrue(FilePathBoundary.contains(translated, in: root))
        for path in ["../escape.png", "/absolute.png", "chapter/../escape.png", "bad\0.png"] {
            XCTAssertThrowsError(try resolver.outputURL(relativeSourcePath: path, outputDirectoryURL: root))
        }
    }

    func testOutputPolicyResolvesSymlinksAndBlocksEscape() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertTrue(OutputDirectoryPolicy.isInsideSource(alias, source: source))
        XCTAssertTrue(OutputDirectoryPolicy.wouldOverwriteSource(alias.appendingPathComponent("page.png"), source: source.appendingPathComponent("page.png")))
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("chapter"), withDestinationURL: source)
        XCTAssertThrowsError(try WorkflowPathResolver().outputURL(relativeSourcePath: "chapter/001.png", outputDirectoryURL: output))
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("future"),
            withDestinationURL: source.appendingPathComponent("not-created"))
        XCTAssertThrowsError(try WorkflowPathResolver().outputURL(relativeSourcePath: "future/001.png", outputDirectoryURL: output))
        try FileManager.default.createSymbolicLink(atPath: output.appendingPathComponent("loop").path,
            withDestinationPath: "loop")
        XCTAssertThrowsError(try WorkflowPathResolver().outputURL(relativeSourcePath: "loop/001.png", outputDirectoryURL: output))
    }

    func testPartialAndMissingShardModelsAreNotInstalled() throws {
        let root = try temporaryRoot()
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        let weights = root.appendingPathComponent("model-00001.safetensors")
        try Data([1]).write(to: weights)
        XCTAssertTrue(DownloadableModelCatalog.isCompleteModelDirectory(root))
        let marker = root.appendingPathComponent(HuggingFaceModelDownloader.inProgressMarker)
        try Data().write(to: marker)
        XCTAssertFalse(DownloadableModelCatalog.isCompleteModelDirectory(root))
        try FileManager.default.removeItem(at: marker)
        try Data(#"{"weight_map":{"a":"model-00001.safetensors","b":"model-00002.safetensors"}}"#.utf8)
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertFalse(DownloadableModelCatalog.isCompleteModelDirectory(root))
        try Data([2]).write(to: root.appendingPathComponent("model-00002.safetensors"))
        XCTAssertTrue(DownloadableModelCatalog.isCompleteModelDirectory(root))
        try Data().write(to: weights)
        XCTAssertFalse(DownloadableModelCatalog.isCompleteModelDirectory(root))
    }

    func testDraftWeightsCannotStandInForMainModel() throws {
        let root = try temporaryRoot()
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        let draft = root.appendingPathComponent("DFlashDraftModel")
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        try Data([1]).write(to: draft.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(DownloadableModelCatalog.isCompleteModelDirectory(root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fake.safetensors"), withIntermediateDirectories: true)
        XCTAssertFalse(DownloadableModelCatalog.isCompleteModelDirectory(root))
    }

    func testInstalledMainAndDraftCompleteWithoutNetwork() async throws {
        let root = try temporaryRoot()
        let model = DownloadableModelDescriptor(id: "offline", displayName: "離線測試",
            repositoryID: "invalid/offline", capability: .imageToText,
            dflashDraft: .init(repositoryID: "invalid/offline-draft"))
        let directory = DownloadableModelCatalog.modelDirectory(storageDirectoryURL: root, model: model)
        let draft = directory.appendingPathComponent("DFlashDraftModel")
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
        try Data(#"{"architectures":["DFlashDraftModel"]}"#.utf8).write(to: draft.appendingPathComponent("config.json"))
        try Data([2]).write(to: draft.appendingPathComponent("model.safetensors"))
        let progress = ProgressRecorder()
        let result = try await HuggingFaceModelDownloader().download(model: model, storageDirectoryURL: root) {
            progress.record($0.fraction)
        }
        XCTAssertEqual(result, directory)
        XCTAssertEqual(progress.last, 1)
    }

    func testFailedImportRemovesOnlyNewManagedDirectory() throws {
        let root = try temporaryRoot()
        let existing = root.appendingPathComponent("keep.txt")
        try Data([1]).write(to: existing)
        XCTAssertThrowsError(try ManagedImportService().materialize([], under: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.txt"])
    }

    func testBridgeRejectsNonFiniteAndOutOfRangeNumbers() {
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, "NaN", "inf"] {
            XCTAssertNil(WebBridgeParameterDecoder.double(value))
            XCTAssertNil(WebBridgeParameterDecoder.integer(value))
        }
        XCTAssertNil(WebBridgeParameterDecoder.integer(NSNumber(value: UInt64.max)))
        XCTAssertNil(WebBridgeParameterDecoder.integer(42.5))
        XCTAssertEqual(WebBridgeParameterDecoder.integer(NSNumber(value: Int.max)), Int.max)
        XCTAssertEqual(WebBridgeParameterDecoder.integer(42.0), 42)
        XCTAssertEqual(WebBridgeParameterDecoder.integer("42"), 42)
        XCTAssertEqual(WebBridgeParameterDecoder.double("42.5"), 42.5)
    }

    func testArchiveDiagnosticsAreDrainedAndBounded() throws {
        let result = try ArchiveProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 20000; i++) print \"archive diagnostic output\" > \"/dev/stderr\"; exit 7 }"]
        )
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertTrue(result.diagnostic.hasPrefix("archive diagnostic output"))
        XCTAssertLessThanOrEqual(result.diagnostic.utf8.count, 64 * 1024)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func record(_ value: Double) { lock.withLock { self.value = value } }
    var last: Double? { lock.withLock { value } }
}
