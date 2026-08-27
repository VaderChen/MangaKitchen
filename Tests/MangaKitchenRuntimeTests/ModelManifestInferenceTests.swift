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

    func testQwen38MultimodalModelIsInferredAsImageToText() throws {
        let directory = try makeModelDirectory(config: [
            "_name_or_path": "lmstudio-community/Qwen3.8-27B-MLX-4bit",
            "architectures": ["Qwen3_5ForConditionalGeneration"],
            "model_type": "qwen3_5",
            "vision_config": [
                "model_type": "qwen3_5",
                "hidden_size": 1152,
                "out_hidden_size": 5120
            ]
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try ModelManifest.load(from: directory)

        XCTAssertEqual(manifest.capability, .imageToText)
        XCTAssertEqual(manifest.backend, .mlxSwift)
    }

    func testMixedCheckpointDirectoryDefaultsToSafetensors() throws {
        let directory = try makeModelDirectory(config: [
            "_name_or_path": "mixed-qwen-model",
            "architectures": ["Qwen3ForCausalLM"],
            "model_type": "qwen3"
        ])
        try Data([0]).write(to: directory.appendingPathComponent("model-q4.gguf"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try ModelManifest.load(from: directory)

        XCTAssertNil(manifest.weightsFile)
        XCTAssertNil(manifest.weightsFormat)
        XCTAssertNil(manifest.mmprojFile)
    }

    func testUnsupportedGGUFManifestInferenceFailsBeforeRuntimeLoading() throws {
        let directory = try makeModelDirectory(
            config: [
                "_name_or_path": "unsupported-q8-k",
                "architectures": ["Qwen3ForCausalLM"],
                "model_type": "qwen3"
            ],
            includeSafetensors: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try GGUFFixture.write(
            type: 15,
            payloadSize: 256,
            to: directory.appendingPathComponent("model-Q8_K.gguf")
        )

        XCTAssertThrowsError(try ModelManifest.load(from: directory)) { error in
            guard case let GGUFBackendError.unsupportedMaterialization(types) = error else {
                return XCTFail("非預期錯誤：\(error)")
            }
            XCTAssertEqual(types, ["Q8_K"])
        }
    }

    func testExplicitGGUFManifestValidatesStorageSupportBeforeRuntimeLoading() throws {
        let directory = try makeModelDirectory(
            config: [
                "_name_or_path": "unsupported-explicit-q8-k",
                "architectures": ["Qwen3ForCausalLM"],
                "model_type": "qwen3"
            ],
            includeSafetensors: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let weightURL = directory.appendingPathComponent("model-Q8_K.gguf")
        try GGUFFixture.write(type: 15, payloadSize: 256, to: weightURL)
        try writeManifest(
            ModelManifest(
                id: "unsupported-explicit-q8-k",
                displayName: "Unsupported Explicit Q8_K",
                capability: .textToText,
                backend: .mlxSwift,
                weightsFile: weightURL.lastPathComponent,
                weightsFormat: .gguf
            ),
            to: directory
        )

        XCTAssertThrowsError(try ModelManifest.load(from: directory)) { error in
            guard case let GGUFBackendError.unsupportedMaterialization(types) = error else {
                return XCTFail("非預期錯誤：\(error)")
            }
            XCTAssertEqual(types, ["Q8_K"])
        }
    }

    func testExplicitMultimodalGGUFManifestRequiresMMProj() throws {
        let directory = try makeModelDirectory(
            config: [
                "_name_or_path": "qwen-gguf-without-mmproj",
                "architectures": ["Qwen3_5ForConditionalGeneration"],
                "model_type": "qwen3_5",
                "vision_config": ["hidden_size": 1_024]
            ],
            includeSafetensors: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let weightURL = directory.appendingPathComponent("model-Q4_0.gguf")
        try GGUFFixture.write(type: 2, payloadSize: 18, to: weightURL)
        try writeManifest(
            ModelManifest(
                id: "qwen-gguf-without-mmproj",
                displayName: "Qwen GGUF Without MMProj",
                capability: .imageToText,
                backend: .mlxSwift,
                weightsFile: weightURL.lastPathComponent,
                weightsFormat: .gguf
            ),
            to: directory
        )

        XCTAssertThrowsError(try ModelManifest.load(from: directory)) { error in
            guard case MLXGGUFLoaderError.missingMultimodalProjector = error else {
                return XCTFail("非預期錯誤：\(error)")
            }
        }
    }

    func testBareGGUFDirectoryReportsMissingRuntimeAssets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Bare-GGUF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GGUFFixture.write(
            type: 2,
            payloadSize: 18,
            to: directory.appendingPathComponent("model-Q4_0.gguf")
        )

        XCTAssertThrowsError(try ModelManifest.load(from: directory)) { error in
            guard case let ModelRuntimeError.ggufRuntimeAssetsMissing(url, assets) = error else {
                return XCTFail("非預期錯誤：\(error)")
            }
            XCTAssertEqual(url, directory)
            XCTAssertEqual(assets, ["config.json", "tokenizer.json"])
        }
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

    private func makeModelDirectory(
        config: [String: Any],
        includeSafetensors: Bool = true
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try configData.write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        if includeSafetensors {
            try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        return directory
    }

    private func writeManifest(_ manifest: ModelManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("mangakitchen-model.json"),
            options: .atomic
        )
    }
}
