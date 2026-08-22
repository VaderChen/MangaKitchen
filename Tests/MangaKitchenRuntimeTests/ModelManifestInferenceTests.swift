import XCTest
@testable import MangaKitchenCore
@testable import MangaKitchenRuntime

final class ModelManifestInferenceTests: XCTestCase {
    func testPlainMLXLanguageModelIsInferredAsTextToText() throws {
        let directory = try makeModelDirectory(config: [
            "_name_or_path": "mlx-community/Qwen3-1.7B-4bit",
            "architectures": ["Qwen3ForCausalLM"],
            "model_type": "qwen3"
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try ModelManifest.load(from: directory)

        XCTAssertEqual(manifest.capability, .textToText)
        XCTAssertEqual(manifest.backend, .mlxSwift)
    }

    func testMLXVisionLanguageModelRemainsImageToText() throws {
        let directory = try makeModelDirectory(config: [
            "_name_or_path": "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            "architectures": ["Qwen3VLForConditionalGeneration"],
            "model_type": "qwen3_vl",
            "vision_config": ["hidden_size": 1024]
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try ModelManifest.load(from: directory)

        XCTAssertEqual(manifest.capability, .imageToText)
        XCTAssertEqual(manifest.backend, .mlxSwift)
    }

    func testLoadedModelIdentityResolvesEquivalentSymlinkPaths() throws {
        let directory = try makeModelDirectory(config: [
            "_name_or_path": "mlx-community/Qwen3.5-4B-4bit",
            "architectures": ["Qwen3ForCausalLM"],
            "model_type": "qwen3_5"
        ])
        let alias = directory.deletingLastPathComponent()
            .appendingPathComponent("MangaKitchen-Manifest-Alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: directory)
        }
        let info = LoadedModelInfo(
            id: "qwen-3.5-4b",
            displayName: "Qwen3.5 4B",
            capability: .textToText,
            backend: .mlxSwift,
            location: alias
        )

        XCTAssertTrue(info.matchesModel(
            id: "qwen-3.5-4b",
            capability: .textToText,
            at: directory
        ))
        XCTAssertFalse(info.matchesModel(
            id: "another-model",
            capability: .textToText,
            at: directory
        ))
    }

    private func makeModelDirectory(config: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try configData.write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
        return directory
    }
}
