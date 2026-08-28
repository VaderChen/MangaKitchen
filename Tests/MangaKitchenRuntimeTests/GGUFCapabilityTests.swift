import Foundation
import MLX
import XCTest
@testable import MangaKitchenRuntime

final class GGUFCapabilityTests: XCTestCase {
    func testStoragePolicyListsOnlyLoaderSupportedTypes() {
        XCTAssertEqual(
            GGUFStoragePolicy.materializableTypes,
            [
                "F32", "F16", "BF16", "I8", "I16", "I32", "Q1_0", "Q2_0", "Q2_K", "Q3_K",
                "Q4_0", "Q4_1", "Q8_0", "MXFP4", "Q4_K", "Q5_K", "Q6_K"
            ]
        )
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q4_0"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q8_0"), .int8)
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "Q4_0")?.materialization,
            .quantized4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "Q4_1")?.materialization,
            .quantized4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "Q8_0")?.materialization,
            .quantized8
        )
        XCTAssertTrue(GGUFStoragePolicy.preservesSourceQuantization(for: "Q4_0"))
        XCTAssertTrue(GGUFStoragePolicy.preservesSourceQuantization(for: "Q8_0"))
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q1_0"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q2_0"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q2_K"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q3_K"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q4_K"), .int4)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q5_K"), .int8)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "Q6_K"), .int8)
        XCTAssertEqual(GGUFStoragePolicy.storageType(for: "MXFP4"), .int4)
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "MXFP4")?.materialization,
            .quantizedMXFP4
        )
        XCTAssertTrue(GGUFStoragePolicy.preservesSourceQuantization(for: "MXFP4"))
        XCTAssertTrue(GGUFStoragePolicy.requiresConversion(for: "MXFP4"))
        XCTAssertNil(GGUFStoragePolicy.storageType(for: "Q8_K"))
    }

    func testGPTOSSWeightNamesMapToMLXModules() throws {
        let normalized = try MLXGGUFWeightNameNormalizer.normalize([
            "blk.0.attn_sinks.weight": MLXArray.zeros([64]),
            "blk.0.ffn_gate_exps.weight": MLXArray.zeros([32, 2880, 2880]),
            "blk.0.ffn_down_exps.bias": MLXArray.zeros([32, 2880]),
            "blk.0.ffn_up_exps.weight": MLXArray.zeros([32, 2880, 2880]),
            "blk.0.ffn_gate_inp.bias": MLXArray.zeros([32])
        ])

        XCTAssertNotNil(normalized["model.layers.0.self_attn.sinks"])
        XCTAssertNotNil(normalized["model.layers.0.mlp.experts.gate_proj.weight"])
        XCTAssertNotNil(normalized["model.layers.0.mlp.experts.down_proj.bias"])
        XCTAssertNotNil(normalized["model.layers.0.mlp.experts.up_proj.weight"])
        XCTAssertNotNil(normalized["model.layers.0.mlp.router.bias"])
    }

    func testSpeedProfileRequantizesQ5KAndQ6KToInt4() {
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "Q5_K", profile: .speed)?.materialization,
            .requantized4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.support(for: "Q6_K", profile: .speed)?.materialization,
            .requantized4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.storageType(for: "Q5_K", profile: .speed),
            .int4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.storageType(for: "Q6_K", profile: .speed),
            .int4
        )
        XCTAssertEqual(
            GGUFStoragePolicy.storageType(for: "Q4_0", profile: .speed),
            .int4
        )
    }

    func testGGUFFloatWeightsUseBF16ExceptQwenSSMA() throws {
        let ssmA = try makeFixture(
            type: 0,
            payloadSize: 4,
            tensorName: "blk.0.ssm_a",
            dimensions: [1]
        )
        let norm = try makeFixture(
            type: 0,
            payloadSize: 4,
            tensorName: "blk.0.ssm_dt.bias",
            dimensions: [1]
        )
        defer {
            try? FileManager.default.removeItem(at: ssmA)
            try? FileManager.default.removeItem(at: norm)
        }

        XCTAssertEqual(
            try MLXGGUFLoader.loadWeights(
                from: ssmA,
                convertQwen35StateSpaceParameters: true
            )["blk.0.ssm_a"]?.dtype,
            .float32
        )
        XCTAssertEqual(
            try MLXGGUFLoader.loadWeights(from: norm)["blk.0.ssm_dt.bias"]?.dtype,
            .bfloat16
        )
    }

    func testFP8TargetPolicyUsesInt8WithoutClaimingUnsupportedGGUFMaterialization() {
        for sourceType in [
            "FP8", "FP8_E4M3", "FP8_E4M3FN", "FP8_E5M2", "F8", "F8_E4M3",
            "F8_E4M3FN", "F8_E5M2",
            "FLOAT8_E4M3FN", "FLOAT8_E5M2"
        ] {
            XCTAssertEqual(
                GGUFStoragePolicy.targetStorageType(for: sourceType),
                .int8,
                sourceType
            )
            XCTAssertFalse(GGUFStoragePolicy.isMaterializable(sourceType))
        }
    }

    func testEmbeddedMetadataProvidesConfigurationAndTokenizerFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-Embedded-GGUF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let weightURL = directory.appendingPathComponent("model.gguf")
        try GGUFFixture.write(
            type: 2,
            payloadSize: 18,
            to: weightURL,
            dimensions: [32],
            metadata: [
                ("general.architecture", .string("qwen35")),
                ("qwen35.block_count", .uint32(2)),
                ("qwen35.context_length", .uint32(4_096)),
                ("qwen35.embedding_length", .uint32(64)),
                ("qwen35.feed_forward_length", .uint32(128)),
                ("qwen35.attention.head_count", .uint32(4)),
                ("qwen35.attention.head_count_kv", .uint32(2)),
                ("qwen35.attention.key_length", .uint32(16)),
                ("qwen35.attention.layer_norm_rms_epsilon", .float32(1e-6)),
                ("qwen35.rope.freq_base", .float32(10_000)),
                ("qwen35.rope.dimension_sections", .arrayUInt32([2, 2, 2])),
                ("qwen35.ssm.conv_kernel", .uint32(4)),
                ("qwen35.ssm.state_size", .uint32(8)),
                ("qwen35.ssm.group_count", .uint32(2)),
                ("qwen35.ssm.inner_size", .uint32(16)),
                ("qwen35.full_attention_interval", .uint32(2)),
                ("tokenizer.ggml.model", .string("gpt2")),
                ("tokenizer.ggml.tokens", .arrayString(["a", "b", "<|im_end|>"])),
                ("tokenizer.ggml.token_type", .arrayUInt32([1, 1, 3])),
                ("tokenizer.ggml.merges", .arrayString([])),
                ("tokenizer.ggml.eos_token_id", .uint32(2)),
                ("tokenizer.ggml.padding_token_id", .uint32(0)),
                ("tokenizer.chat_template", .string("{{ messages[0].content }}"))
            ]
        )
        try Data("not json".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("tokenizer_config.json")
        )

        XCTAssertEqual(MLXGGUFModelSource.missingRuntimeAssetNames(in: directory), [])
        _ = try MLXGGUFEmbeddedAssets.configurationData(weightURL: weightURL, mmprojURL: nil)
        let manifest = try ModelManifest.load(from: directory)
        XCTAssertEqual(manifest.capability, .textToText)
        XCTAssertEqual(manifest.weightsFormat, .gguf)
        XCTAssertEqual(manifest.weightsFile, "model.gguf")
        XCTAssertEqual(manifest.id, directory.lastPathComponent)

        let configurationData = try MLXGGUFEmbeddedAssets.configurationData(
            weightURL: weightURL,
            mmprojURL: nil
        )
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configurationData) as? [String: Any]
        )
        XCTAssertEqual(configuration["model_type"] as? String, "qwen3_5_text")
        XCTAssertEqual(configuration["vocab_size"] as? Int, 3)

        let tokenizer = try await MLXGGUFEmbeddedAssets.tokenizer(
            directoryURL: directory,
            weightURL: weightURL
        )
        XCTAssertEqual(tokenizer.encode(text: "a", addSpecialTokens: false), [0])
        XCTAssertEqual(tokenizer.eosToken, "<|im_end|>")
        XCTAssertEqual(tokenizer.unknownToken, "a")
        let unknownTextTokens = tokenizer.encode(text: "🚫", addSpecialTokens: false)
        XCTAssertFalse(unknownTextTokens.isEmpty)
        XCTAssertTrue(unknownTextTokens.allSatisfy { $0 == 0 })
    }

    func testBF16GGUFWeightsRemainBF16() throws {
        var payload = Data()
        for value in [Float(1), Float(-2.5), Float(0.125), Float(32)] {
            let bits = value.bitPattern
            let bfloatBits = UInt16(bits >> 16)
            payload.append(UInt8(truncatingIfNeeded: bfloatBits))
            payload.append(UInt8(truncatingIfNeeded: bfloatBits >> 8))
        }
        let fixture = try makeFixture(
            type: 30,
            payloadSize: payload.count,
            dimensions: [4],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
        XCTAssertEqual(inspection.tensors.first?.type, "BF16")
        XCTAssertTrue(inspection.tensors.first?.isMaterializable == true)
        XCTAssertEqual(inspection.tensors.first?.storageType, .bf16)

        let weights = try MLXGGUFLoader.loadWeights(from: fixture)
        let weight = try XCTUnwrap(weights["test.weight"])
        XCTAssertEqual(weight.dtype, .bfloat16)
        XCTAssertEqual(weight.asArray(Float.self), [1, -2.5, 0.125, 32])
    }

    func testQwen35BF16StateSpaceParameterReversesAEncoding() throws {
        var payload = Data()
        for value in [Float(-1), Float(-4), Float(-0.25), Float(-16)] {
            let bits = (-exp(value)).bitPattern
            let bfloatBits = UInt16(bits >> 16)
            payload.append(UInt8(truncatingIfNeeded: bfloatBits))
            payload.append(UInt8(truncatingIfNeeded: bfloatBits >> 8))
        }
        let fixture = try makeFixture(
            type: 30,
            payloadSize: payload.count,
            tensorName: "blk.0.ssm_a",
            dimensions: [4],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let weights = try MLXGGUFLoader.loadWeights(
            from: fixture,
            convertQwen35StateSpaceParameters: true
        )
        let value = try XCTUnwrap(weights["blk.0.ssm_a"])
        let restored = try XCTUnwrap(value.asArray(Float.self))
        XCTAssertEqual(restored[0], -1, accuracy: 0.01)
        XCTAssertEqual(restored[1], -4, accuracy: 0.01)
        XCTAssertEqual(restored[2], -0.25, accuracy: 0.01)
        XCTAssertEqual(restored[3], -16, accuracy: 0.01)
    }

    func testQwen35ConverterNormDetectionExcludesLinearAttentionNorm() {
        XCTAssertTrue(
            MLXGGUFModelLoader.isQwen35ConverterShiftedNorm("blk.0.attn_norm.weight")
        )
        XCTAssertTrue(
            MLXGGUFModelLoader.isQwen35ConverterShiftedNorm("blk.0.post_attention_norm.weight")
        )
        XCTAssertTrue(
            MLXGGUFModelLoader.isQwen35ConverterShiftedNorm("output_norm.weight")
        )
        XCTAssertFalse(
            MLXGGUFModelLoader.isQwen35ConverterShiftedNorm("blk.0.ssm_norm.weight")
        )
        XCTAssertFalse(
            MLXGGUFModelLoader.isQwen35ConverterShiftedNorm(
                "model.layers.0.linear_attn.norm.weight"
            )
        )
    }

    func testKQuantRequantizationNumericalError() throws {
        let fixtures: [(UInt32, String, Int, Data, [Float], Float, Float)] = [
            (
                10,
                "Q2_K",
                84,
                makeQ2KPayload().payload,
                makeQ2KPayload().values,
                0.5,
                0.01
            ),
            (
                11,
                "Q3_K",
                110,
                makeQ3KPayload().payload,
                makeQ3KPayload().values,
                0.5,
                0.01
            ),
            (
                12,
                "Q4_K",
                144,
                makeQ4KPayload().payload,
                makeQ4KPayload().values,
                0.01,
                0
            ),
            (
                13,
                "Q5_K",
                176,
                makeQ5KPayload().payload,
                makeQ5KPayload().values,
                0.01,
                0
            ),
            (
                14,
                "Q6_K",
                210,
                makeQ6KPayload().payload,
                makeQ6KPayload().values,
                0.5,
                0.01
            )
        ]

        for (type, typeName, payloadSize, payload, expected, maximumError, minimumError) in fixtures {
            let fixture = try makeFixture(
                type: type,
                payloadSize: payloadSize,
                dimensions: [256, 1],
                payload: payload
            )
            defer { try? FileManager.default.removeItem(at: fixture) }

            let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
            let tensor = try XCTUnwrap(inspection.tensors.first)
            XCTAssertEqual(tensor.type, typeName)

            let weights = try MLXGGUFLoader.loadWeights(from: fixture)
            let targetBits = GGUFStoragePolicy.storageType(for: typeName) == .int4 ? 4 : 8
            let actual = try reconstructedValues(from: weights, bits: targetBits)
            let errors = errorMetrics(actual: actual, expected: expected)
            XCTAssertLessThanOrEqual(
                errors.maximumAbsolute,
                maximumError,
                typeName + " max abs error"
            )
            XCTAssertLessThanOrEqual(
                errors.relative,
                maximumError / max(expected.map { abs($0) }.max() ?? 1, 1),
                typeName + " relative error"
            )
            if minimumError > 0 {
                XCTAssertGreaterThan(
                    errors.maximumAbsolute,
                    minimumError,
                    typeName + " should expose group-32 cross-scale error"
                )
                XCTAssertGreaterThan(
                    errors.relative,
                    minimumError / max(expected.map { abs($0) }.max() ?? 1, 1),
                    typeName + " relative group-32 error"
                )
            }
        }
    }

    func testLowerBitTypesAreRequantizedToMLXInt4() throws {
        let fixtures: [(UInt32, String, Int, [UInt64])] = [
            (41, "Q1_0", 18 * 32, [128, 32]),
            (42, "Q2_0", 18 * 32, [64, 32]),
            (10, "Q2_K", 84 * 16, [256, 16]),
            (11, "Q3_K", 110 * 16, [256, 16])
        ]

        for (type, typeName, payloadSize, dimensions) in fixtures {
            let fixture = try makeFixture(
                type: type,
                payloadSize: payloadSize,
                dimensions: dimensions
            )
            defer { try? FileManager.default.removeItem(at: fixture) }

            let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
            let tensor = try XCTUnwrap(inspection.tensors.first)

            XCTAssertEqual(tensor.type, typeName)
            XCTAssertTrue(tensor.isMaterializable)
            XCTAssertEqual(tensor.storageType, .int4)
            XCTAssertTrue(tensor.requiresConversion)
            let weights = try MLXGGUFLoader.loadWeights(from: fixture)
            XCTAssertEqual(weights["test.weight"]?.dtype, .uint32)
            XCTAssertEqual(weights["test.scales"]?.dtype, .bfloat16)
            XCTAssertNotNil(weights["test.biases"])
        }
    }

    func testPreservedQuantizedTypesUseMetalPacking() throws {
        var q4Payload = Data([0x00, 0x3c])
        q4Payload.append(contentsOf: [0x01, 0x10])
        q4Payload.append(contentsOf: [UInt8](repeating: 0, count: 14))
        let q4Fixture = try makeFixture(
            type: 2,
            payloadSize: 18,
            dimensions: [32],
            payload: q4Payload
        )
        defer { try? FileManager.default.removeItem(at: q4Fixture) }

        let q4Weights = try MLXGGUFLoader.loadWeights(from: q4Fixture)
        let q4Packed = try XCTUnwrap(q4Weights["test.weight"])
        XCTAssertEqual(q4Packed.asArray(UInt32.self)[0], 0x00000001)
        XCTAssertEqual(q4Packed.asArray(UInt32.self)[2], 0x00000010)
        XCTAssertEqual(
            try XCTUnwrap(q4Weights["test.scales"]).item(Float.self),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(q4Weights["test.biases"]).item(Float.self),
            -8,
            accuracy: 0.001
        )

        var q41Payload = Data([0x00, 0x3c, 0x00, 0x40])
        q41Payload.append(contentsOf: [UInt8](repeating: 0, count: 16))
        let q41Fixture = try makeFixture(
            type: 3,
            payloadSize: 20,
            dimensions: [32],
            payload: q41Payload
        )
        defer { try? FileManager.default.removeItem(at: q41Fixture) }

        let q41Weights = try MLXGGUFLoader.loadWeights(from: q41Fixture)
        XCTAssertEqual(
            try XCTUnwrap(q41Weights["test.biases"]).item(Float.self),
            2,
            accuracy: 0.001
        )

        var q8Payload = Data([0x00, 0x3c])
        q8Payload.append(contentsOf: [UInt8](repeating: 0, count: 32))
        let q8Fixture = try makeFixture(
            type: 8,
            payloadSize: 34,
            dimensions: [32],
            payload: q8Payload
        )
        defer { try? FileManager.default.removeItem(at: q8Fixture) }

        let q8Weights = try MLXGGUFLoader.loadWeights(from: q8Fixture)
        let q8Packed = try XCTUnwrap(q8Weights["test.weight"])
        XCTAssertEqual(q8Packed.asArray(UInt32.self)[0], 0x80808080)
        XCTAssertEqual(
            try XCTUnwrap(q8Weights["test.biases"]).item(Float.self),
            -128,
            accuracy: 0.001
        )
    }

    func testGroup64IsProducedDirectlyFromGGUFRawBlocks() throws {
        var payload = Data([0x00, 0x3c])
        payload.append(contentsOf: [UInt8](repeating: 0x88, count: 16))
        payload.append(contentsOf: [0x00, 0x40])
        payload.append(contentsOf: [UInt8](repeating: 0x99, count: 16))
        let fixture = try makeFixture(
            type: 2,
            payloadSize: 36,
            dimensions: [64, 1],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let weights = try MLXGGUFLoader.loadWeights(
            from: fixture,
            targetGroupSize: 64
        )
        let weight = try XCTUnwrap(weights["test.weight"])
        let scales = try XCTUnwrap(weights["test.scales"])
        let biases = try XCTUnwrap(weights["test.biases"])
        XCTAssertEqual(weight.shape, [1, 8])
        XCTAssertEqual(scales.shape, [1, 1])
        XCTAssertEqual(biases.shape, [1, 1])

        let reconstructed = MLX.dequantized(
            weight,
            scales: scales,
            biases: biases,
            groupSize: 64,
            bits: 4,
            dtype: .float32
        )
        let values = try XCTUnwrap(reconstructed.asArray(Float.self))
        XCTAssertEqual(values[0], 0, accuracy: 0.01)
        XCTAssertEqual(values[31], 0, accuracy: 0.01)
        XCTAssertEqual(values[32], 2, accuracy: 0.01)
        XCTAssertEqual(values[63], 2, accuracy: 0.01)
    }

    func testQ2KPreservesAllQuantizedSlicesBeforeRequantization() throws {
        var payload = Data(repeating: 0, count: 84)
        payload[0] = 0x00
        payload[1] = 0x3c
        payload.replaceSubrange(4..<20, with: Data(repeating: 1, count: 16))
        payload.replaceSubrange(20..<36, with: Data(repeating: 0x01, count: 16))
        payload.replaceSubrange(36..<52, with: Data(repeating: 0x02, count: 16))
        payload.replaceSubrange(52..<68, with: Data(repeating: 0x03, count: 16))
        let fixture = try makeFixture(
            type: 10,
            payloadSize: 84,
            dimensions: [256, 1],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let weights = try MLXGGUFLoader.loadWeights(from: fixture)
        let reconstructed = try reconstructedValues(from: weights, bits: 4)
        XCTAssertEqual(reconstructed[0], 1, accuracy: 0.01)
        XCTAssertEqual(reconstructed[16], 2, accuracy: 0.01)
        XCTAssertEqual(reconstructed[32], 0, accuracy: 0.01)
        XCTAssertEqual(reconstructed[128], 3, accuracy: 0.01)
        XCTAssertEqual(reconstructed[144], 0, accuracy: 0.01)
    }

    func testQ4KIsInspectableAndMaterializable() throws {
        var payload = Data([0x00, 0x3c, 0x00, 0x00])
        payload.append(contentsOf: [1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1])
        payload.append(contentsOf: [UInt8](repeating: 0x10, count: 128))
        let fixture = try makeFixture(
            type: 12,
            payloadSize: 144,
            dimensions: [256, 1],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
        let tensor = try XCTUnwrap(inspection.tensors.first)

        XCTAssertEqual(tensor.type, "Q4_K")
        XCTAssertEqual(tensor.byteSize, 144)
        XCTAssertTrue(tensor.isMaterializable)
        XCTAssertEqual(tensor.storageType, .int4)
        XCTAssertFalse(tensor.preservesSourceQuantization)
        XCTAssertTrue(tensor.requiresConversion)
        XCTAssertTrue(inspection.unsupportedTypes.isEmpty)

        let weights = try MLXGGUFLoader.loadWeights(from: fixture)
        XCTAssertEqual(weights["test.weight"]?.shape, [1, 32])
        XCTAssertEqual(weights["test.weight"]?.dtype, .uint32)
        let weight = try XCTUnwrap(weights["test.weight"])
        let scales = try XCTUnwrap(weights["test.scales"])
        let biases = try XCTUnwrap(weights["test.biases"])
        let reconstructed = MLX.dequantized(
            weight,
            scales: scales,
            biases: biases,
            groupSize: 32,
            bits: 4,
            dtype: .float32
        )
        let values: [Float] = try XCTUnwrap(reconstructed.asArray(Float.self))
        XCTAssertEqual(values[0], 0, accuracy: 0.001)
        XCTAssertEqual(values[31], 0, accuracy: 0.001)
        XCTAssertEqual(values[32], 1, accuracy: 0.001)
        XCTAssertEqual(values[63], 1, accuracy: 0.001)
        XCTAssertEqual(values[192], 0, accuracy: 0.001)
        XCTAssertEqual(values[223], 0, accuracy: 0.001)
        XCTAssertEqual(values[224], 1, accuracy: 0.001)
        XCTAssertEqual(values[255], 1, accuracy: 0.001)
    }

    func testMXFP4IsRepackedForMLXWithoutChangingValues() throws {
        var payload = Data([127])
        for index in 0..<16 {
            payload.append(UInt8(index) | (UInt8(15 - index) << 4))
        }
        let fixture = try makeFixture(
            type: 39,
            payloadSize: 17,
            dimensions: [32, 1],
            payload: payload
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
        let tensor = try XCTUnwrap(inspection.tensors.first)
        XCTAssertEqual(tensor.type, "MXFP4")
        XCTAssertEqual(tensor.byteSize, 17)
        XCTAssertTrue(tensor.isMaterializable)
        XCTAssertEqual(tensor.storageType, .int4)
        XCTAssertTrue(tensor.preservesSourceQuantization)
        XCTAssertTrue(tensor.requiresConversion)
        XCTAssertTrue(inspection.unsupportedTypes.isEmpty)

        let weights = try MLXGGUFLoader.loadWeights(from: fixture)
        let weight = try XCTUnwrap(weights["test.weight"])
        let scales = try XCTUnwrap(weights["test.scales"])
        XCTAssertEqual(weight.dtype, .uint32)
        XCTAssertEqual(weight.shape, [1, 4])
        XCTAssertEqual(scales.dtype, .uint8)
        XCTAssertEqual(scales.shape, [1, 1])
        XCTAssertNil(weights["test.biases"])

        let reconstructed = MLX.dequantized(
            weight,
            scales: scales,
            biases: nil,
            groupSize: 32,
            bits: 4,
            mode: .mxfp4,
            dtype: .float32
        )
        let values = try XCTUnwrap(reconstructed.asArray(Float.self))
        let expected: [Float] = [
            0, 0.5, 1, 1.5, 2, 3, 4, 6,
            -0, -0.5, -1, -1.5, -2, -3, -4, -6,
            -6, -4, -3, -2, -1.5, -1, -0.5, -0,
            6, 4, 3, 2, 1.5, 1, 0.5, 0
        ]
        XCTAssertEqual(values.count, expected.count)
        for (actual, expected) in zip(values, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    func testQ5KAndQ6KInspectionMatchesLoaderSupport() throws {
        for (type, typeName, payloadSize) in [(UInt32(13), "Q5_K", 176), (14, "Q6_K", 210)] {
            let fixture = try makeFixture(
                type: type,
                payloadSize: payloadSize,
                dimensions: [256, 1]
            )
            defer { try? FileManager.default.removeItem(at: fixture) }

            let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
            let tensor = try XCTUnwrap(inspection.tensors.first)

            XCTAssertEqual(tensor.type, typeName)
            XCTAssertTrue(tensor.isMaterializable)
            XCTAssertEqual(tensor.storageType, .int8)
            XCTAssertTrue(tensor.requiresConversion)
            XCTAssertTrue(inspection.unsupportedTypes.isEmpty)
            let weights = try MLXGGUFLoader.loadWeights(from: fixture)
            XCTAssertEqual(weights["test.weight"]?.dtype, .uint32)
            XCTAssertEqual(weights["test.scales"]?.dtype, .bfloat16)

            let speedWeights = try MLXGGUFLoader.loadWeights(
                from: fixture,
                quantizationProfile: .speed
            )
            XCTAssertEqual(speedWeights["test.weight"]?.dtype, .uint32)
            XCTAssertEqual(speedWeights["test.scales"]?.dtype, .bfloat16)
        }
    }

    func testUnsupportedTypesAreNotAssignedAStoragePlan() throws {
        let fixture = try makeFixture(type: 15, payloadSize: 256)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let inspection = try MLXNativeGGUFBackend().inspect(fileURL: fixture)
        let tensor = try XCTUnwrap(inspection.tensors.first)

        XCTAssertEqual(tensor.type, "Q8_K")
        XCTAssertFalse(tensor.isMaterializable)
        XCTAssertNil(tensor.storageType)
        XCTAssertFalse(tensor.preservesSourceQuantization)
        XCTAssertFalse(tensor.requiresConversion)
        XCTAssertEqual(inspection.unsupportedTypes, ["Q8_K"])
    }

    func testExplicitUnsupportedGGUFIsRejectedBeforeRuntimeLoading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-GGUF-Source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let weightURL = directory.appendingPathComponent("model-Q8_K.gguf")
        try GGUFFixture.write(type: 15, payloadSize: 256, to: weightURL)
        let manifest = ModelManifest(
            id: "unsupported-gguf",
            displayName: "Unsupported GGUF",
            capability: .textToText,
            backend: .mlxSwift,
            weightsFile: weightURL.lastPathComponent,
            weightsFormat: .gguf
        )

        XCTAssertThrowsError(
            try MLXGGUFModelSource.weightURL(in: directory, manifest: manifest)
        ) { error in
            guard case let GGUFBackendError.unsupportedMaterialization(types) = error else {
                return XCTFail("非預期錯誤：\(error)")
            }
            XCTAssertEqual(types, ["Q8_K"])
        }
    }

    private func makeFixture(
        type: UInt32,
        payloadSize: Int,
        tensorName: String = "test.weight",
        dimensions: [UInt64] = [256],
        payload: Data? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaKitchen-GGUF-\(UUID().uuidString).gguf")
        try GGUFFixture.write(
            type: type,
            payloadSize: payloadSize,
            to: url,
            tensorName: tensorName,
            dimensions: dimensions,
            payload: payload
        )
        return url
    }

    private func reconstructedValues(
        from weights: [String: MLXArray],
        bits: Int
    ) throws -> [Float] {
        let weight = try XCTUnwrap(weights["test.weight"])
        let scales = try XCTUnwrap(weights["test.scales"])
        let biases = try XCTUnwrap(weights["test.biases"])
        let reconstructed = MLX.dequantized(
            weight,
            scales: scales,
            biases: biases,
            groupSize: 32,
            bits: bits,
            dtype: .float32
        )
        return try XCTUnwrap(reconstructed.asArray(Float.self))
    }

    private func errorMetrics(
        actual: [Float],
        expected: [Float]
    ) -> (maximumAbsolute: Float, relative: Float) {
        precondition(actual.count == expected.count)
        let maximumAbsolute = zip(actual, expected)
            .map { abs($0 - $1) }
            .max() ?? 0
        let maximumExpected = expected.map { abs($0) }.max() ?? 1
        return (maximumAbsolute, maximumAbsolute / max(maximumExpected, 1))
    }

    private func makeQ2KPayload() -> (payload: Data, values: [Float]) {
        var payload = Data(repeating: 0, count: 84)
        payload[1] = 0x3c
        for index in 0..<8 {
            payload[4 + index * 2] = 1
            payload[5 + index * 2] = 2
        }
        for half in 0..<2 {
            for index in 0..<32 {
                payload[20 + half * 32 + index] = kQuantizedByte(index)
            }
        }

        var values = [Float]()
        for _ in 0..<2 {
            for chunk in 0..<4 {
                for index in 0..<16 {
                    let quantized = Float(
                        (kQuantizedByte(index) >> (chunk * 2)) & 3
                    )
                    values.append(quantized)
                }
                for index in 0..<16 {
                    let quantized = Float(
                        (kQuantizedByte(index + 16) >> (chunk * 2)) & 3
                    )
                    values.append(quantized * 2)
                }
            }
        }
        return (payload, values)
    }

    private func makeQ3KPayload() -> (payload: Data, values: [Float]) {
        var payload = Data(repeating: 0, count: 110)
        payload[109] = 0x3c
        payload.replaceSubrange(0..<32, with: Data(repeating: 0xff, count: 32))
        for half in 0..<2 {
            for index in 0..<32 {
                payload[32 + half * 32 + index] = kQuantizedByte(index)
            }
        }
        for index in 0..<16 {
            setQ3KScale(index.isMultiple(of: 2) ? 33 : 34, index: index, in: &payload)
        }

        var values = [Float]()
        for _ in 0..<2 {
            for chunk in 0..<4 {
                for index in 0..<16 {
                    let quantized = Float(
                        (kQuantizedByte(index) >> (chunk * 2)) & 3
                    )
                    values.append(quantized)
                }
                for index in 0..<16 {
                    let quantized = Float(
                        (kQuantizedByte(index + 16) >> (chunk * 2)) & 3
                    )
                    values.append(quantized * 2)
                }
            }
        }
        return (payload, values)
    }

    private func makeQ4KPayload() -> (payload: Data, values: [Float]) {
        var payload = Data(repeating: 0, count: 144)
        payload[1] = 0x3c
        payload.replaceSubrange(4..<8, with: Data(repeating: 1, count: 4))
        payload.replaceSubrange(12..<16, with: Data(repeating: 1, count: 4))

        var values = [Float]()
        for segment in 0..<4 {
            for index in 0..<32 {
                let low = UInt8(index % 16)
                let high = UInt8((index + 1) % 16)
                payload[16 + segment * 32 + index] = low | (high << 4)
                values.append(Float(low))
            }
            for index in 0..<32 {
                values.append(Float((index + 1) % 16))
            }
        }
        return (payload, values)
    }

    private func makeQ5KPayload() -> (payload: Data, values: [Float]) {
        var payload = Data(repeating: 0, count: 176)
        payload[1] = 0x3c
        payload.replaceSubrange(4..<8, with: Data(repeating: 1, count: 4))
        payload.replaceSubrange(12..<16, with: Data(repeating: 1, count: 4))

        var values = [Float]()
        for segment in 0..<4 {
            for index in 0..<32 {
                let low = UInt8(index % 16)
                let high = UInt8((index + 1) % 16)
                payload[48 + segment * 32 + index] = low | (high << 4)
                values.append(Float(low))
            }
            for index in 0..<32 {
                values.append(Float((index + 1) % 16))
            }
        }
        return (payload, values)
    }

    private func makeQ6KPayload() -> (payload: Data, values: [Float]) {
        var payload = Data(repeating: 0, count: 210)
        payload[209] = 0x3c
        for half in 0..<2 {
            for plane in 0..<4 {
                payload[192 + half * 8 + plane * 2] = 1
                payload[193 + half * 8 + plane * 2] = 2
            }
            for index in 0..<32 {
                let quantized = UInt8(index % 16)
                payload[half * 64 + index] = quantized | (quantized << 4)
                payload[half * 64 + 32 + index] = quantized | (quantized << 4)
            }
        }

        var values = [Float]()
        for _ in 0..<2 {
            for _ in 0..<4 {
                for index in 0..<32 {
                    let quantized = Float(index % 16) - 32
                    values.append(quantized * (index < 16 ? 1 : 2))
                }
            }
        }
        return (payload, values)
    }

    private func setQ3KScale(_ value: UInt8, index: Int, in payload: inout Data) {
        let group = index / 4
        let position = index % 4
        let low = value & 0x0f
        let high = (value >> 4) & 0x03
        switch group {
        case 0:
            payload[96 + position] = (payload[96 + position] & 0xf0) | low
            payload[104 + position] |= high << 0
        case 1:
            payload[100 + position] = (payload[100 + position] & 0xf0) | low
            payload[104 + position] |= high << 2
        case 2:
            payload[96 + position] = (payload[96 + position] & 0x0f) | (low << 4)
            payload[104 + position] |= high << 4
        default:
            payload[100 + position] = (payload[100 + position] & 0x0f) | (low << 4)
            payload[104 + position] |= high << 6
        }
    }

    private func kQuantizedByte(_ index: Int) -> UInt8 {
        let first = UInt8(index % 4)
        let second = UInt8((index / 2) % 4)
        let third = UInt8((index / 3) % 4)
        let fourth = UInt8((index / 4) % 4)
        return first | (second << 2) | (third << 4) | (fourth << 6)
    }
}
