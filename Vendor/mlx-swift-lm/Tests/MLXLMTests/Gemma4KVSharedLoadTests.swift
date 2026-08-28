import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import MLXVLM

struct Gemma4KVSharedLoadTests {

    @Test("KV-shared layers own no local k_proj/v_proj/k_norm")
    func kvSharedLayersOwnNoLocalKVProjections() {
        let model = Gemma4TextLanguageModel(Self.textConfig(numKVSharedLayers: 2))
        let keys = Set(model.parameters().flattened().map(\.0))

        for owning in [0, 1] {
            #expect(keys.contains { $0.contains("layers.\(owning).self_attn.k_proj") })
            #expect(keys.contains { $0.contains("layers.\(owning).self_attn.v_proj") })
        }
        for shared in [2, 3] {
            #expect(!keys.contains { $0.contains("layers.\(shared).self_attn.k_proj") })
            #expect(!keys.contains { $0.contains("layers.\(shared).self_attn.v_proj") })
            #expect(!keys.contains { $0.contains("layers.\(shared).self_attn.k_norm") })
        }
    }

    @Test("Sanitized Gemma 4 checkpoint loads into a KV-sharing model")
    func sanitizedCheckpointLoadsWithoutKeyNotFound() throws {
        let dense = Gemma4TextLanguageModel(Self.textConfig(numKVSharedLayers: 0))
        eval(dense)

        let firstKVSharedLayer = 4 - 2
        var checkpoint = [String: MLXArray]()
        for (key, value) in dense.parameters().flattened() {
            if let layerIdx = Self.layerIndex(in: key), layerIdx >= firstKVSharedLayer,
                key.contains(".self_attn.k_proj")
                    || key.contains(".self_attn.v_proj")
                    || key.contains(".self_attn.k_norm")
            {
                continue
            }
            checkpoint[key] = value
        }

        let model = Gemma4TextLanguageModel(Self.textConfig(numKVSharedLayers: 2))
        try model.update(
            parameters: ModuleParameters.unflattened(checkpoint), verify: [.all])
        eval(model)
    }

    private static func layerIndex(in key: String) -> Int? {
        guard let range = key.range(of: "layers.") else { return nil }
        return Int(key[range.upperBound...].prefix { $0.isNumber })
    }

    private static func textConfig(numKVSharedLayers: Int) -> Gemma4TextConfiguration {
        let json = """
            {
              "model_type": "gemma4_text",
              "hidden_size": 8,
              "num_hidden_layers": 4,
              "intermediate_size": 16,
              "num_attention_heads": 2,
              "num_key_value_heads": 1,
              "head_dim": 4,
              "global_head_dim": 4,
              "vocab_size": 12,
              "vocab_size_per_layer_input": 12,
              "num_kv_shared_layers": \(numKVSharedLayers),
              "hidden_size_per_layer_input": 0,
              "sliding_window": 8,
              "sliding_window_pattern": 1,
              "max_position_embeddings": 32,
              "rms_norm_eps": 1e-6,
              "rope_traditional": false,
              "use_double_wide_mlp": false,
              "enable_moe_block": false,
              "attention_k_eq_v": false,
              "layer_types": [
                "full_attention", "full_attention", "full_attention", "full_attention"
              ],
              "rope_parameters": {},
              "tie_word_embeddings": true
            }
            """
        return try! JSONDecoder().decode(
            Gemma4TextConfiguration.self, from: Data(json.utf8))
    }
}
