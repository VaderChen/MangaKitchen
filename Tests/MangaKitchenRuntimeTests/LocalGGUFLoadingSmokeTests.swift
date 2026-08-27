import Foundation
import XCTest
@testable import MangaKitchenRuntime

final class LocalGGUFLoadingSmokeTests: XCTestCase {
    func testLocalQwen38Q4_0Inspection() throws {
        let directoryURL = try localModelDirectory()
        let modelURL = directoryURL.appendingPathComponent("Qwen3.8-27B-Q4_0.gguf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "指定目錄缺少 Qwen3.8-27B Q4_0 GGUF。")

        let inspection = try MLXNativeGGUFBackend().inspect(fileURL: modelURL)
        XCTAssertTrue(inspection.tensorCount > 0)
        XCTAssertTrue(inspection.unsupportedTypes.isEmpty)
        XCTAssertTrue(MLXNativeGGUFBackend().canMaterialize(inspection))
        XCTAssertEqual(inspection.storageTypeCounts[.int4], 360)
        XCTAssertEqual(inspection.storageTypeCounts[.int8], 50)
        XCTAssertEqual(inspection.storageTypeCounts[.fp32], 456)
        XCTAssertEqual(inspection.conversionTensorCount, 49)
    }

    func testQwen38GGUFWithMMProjLoads() async throws {
        let directoryURL = try localModelDirectory()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("Qwen3.8-27B-Q4_0.gguf").path),
            "指定目錄缺少 Qwen3.8-27B Q4_0 GGUF。"
        )
        let container = try await MLXGGUFModelLoader.loadVLMContainer(
            from: directoryURL,
            weightURL: directoryURL.appendingPathComponent("Qwen3.8-27B-Q4_0.gguf"),
            mmprojURL: directoryURL.appendingPathComponent("mmproj-F16.gguf")
        )
        XCTAssertNotNil(container)
    }

    private func localModelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MANGAKITCHEN_GGUF_MODEL_DIR"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("設定 MANGAKITCHEN_GGUF_MODEL_DIR 後才執行真模型 smoke 測試。")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
