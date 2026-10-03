import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM
import XCTest

final class LFMProcessorCompatibilityTests: XCTestCase {
    private struct ImageTokenizer: Tokenizer {
        var imageID: Int?
        var includePlaceholder = true
        var imageStartID: Int?
        var imageEndID: Int?
        var wrappedPlaceholder = false
        var extraPlaceholder = false
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? {
            switch token {
            case "<image>": imageID
            case "<|image_start|>": imageStartID
            case "<|image_end|>": imageEndID
            default: nil
            }
        }
        func convertIdToToken(_ id: Int) -> String? { id == imageID ? "<image>" : nil }
        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            if extraPlaceholder { return [1, imageID ?? 124907, 2, imageID ?? 124907, 3] }
            if wrappedPlaceholder, let imageStartID, let imageEndID {
                return [1, imageStartID, imageID ?? 124907, imageEndID, 2]
            }
            return includePlaceholder ? [1, imageID ?? 124907, 2] : [1, 2]
        }
    }

    private func configuration(_ json: String) throws -> LFM2VLProcessorConfiguration {
        try JSONDecoder().decode(LFM2VLProcessorConfiguration.self, from: Data(json.utf8))
    }

    private func input(width: Int, height: Int) -> UserInput {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return UserInput(chat: [.user("Read this image.", images: [.ciImage(image)])])
    }

    func testExpandedVocabularyUsesTokenizerImageIDAndBoundedAspectRatio() async throws {
        let config = try configuration("""
            {"image_processor":{"do_image_splitting":false,"min_image_tokens":64,
             "max_image_tokens":256,"max_num_patches":1024,"encoder_patch_size":16,
             "downsample_factor":2},"processor_class":"Lfm2VlProcessor"}
            """)
        let processor = LFM2VLProcessor(config, tokenizer: ImageTokenizer(
            imageID: 124907, imageStartID: 124905, imageEndID: 124906))
        let prepared = try await processor.prepare(input: input(width: 687, height: 1024))
        // Reference smart_resize: 687x1024 -> 416x608 -> 26x38 patches -> 13x19 tokens.
        XCTAssertEqual(prepared.image?.frames?.first?.w, 26)
        XCTAssertEqual(prepared.image?.frames?.first?.h, 38)
        XCTAssertEqual(prepared.image?.pixels.dim(1), 988)
        let tokens = prepared.text.tokens.asArray(Int.self)
        XCTAssertEqual(tokens.filter { $0 == 124907 }.count, 247)
        XCTAssertEqual(tokens.first, 1)
        XCTAssertEqual(tokens.last, 2)
        XCTAssertEqual(tokens[1], 124905)
        XCTAssertEqual(tokens[tokens.count - 2], 124906)
    }

    func testLegacyFlatConfigurationKeepsImageTokenAndDimensions() async throws {
        let config = try configuration("{}")
        let processor = LFM2VLProcessor(config, tokenizer: ImageTokenizer(imageID: 396))
        let prepared = try await processor.prepare(input: input(width: 100, height: 200))
        XCTAssertEqual(prepared.image?.frames?.first?.h, 32)
        XCTAssertEqual(prepared.image?.frames?.first?.w, 32)
        XCTAssertEqual(prepared.text.tokens.asArray(Int.self).filter { $0 == 396 }.count, 256)
    }

    func testExistingImageBoundariesAreNotDuplicated() async throws {
        let processor = LFM2VLProcessor(try configuration("{}"), tokenizer: ImageTokenizer(
            imageID: 124907, imageStartID: 124905, imageEndID: 124906, wrappedPlaceholder: true))
        let prepared = try await processor.prepare(input: input(width: 64, height: 64))
        let tokens = prepared.text.tokens.asArray(Int.self)
        XCTAssertEqual(tokens.filter { $0 == 124905 }.count, 1)
        XCTAssertEqual(tokens.filter { $0 == 124906 }.count, 1)
        XCTAssertEqual(tokens.filter { $0 == 124907 }.count, 256)
    }

    func testMissingImageTokenOrPlaceholderThrowsInsteadOfReachingModelTrap() async throws {
        let config = try configuration("{}")
        for tokenizer in [ImageTokenizer(imageID: nil),
                          ImageTokenizer(imageID: 124907, includePlaceholder: false),
                          ImageTokenizer(imageID: 124907, extraPlaceholder: true)] {
            do {
                _ = try await LFM2VLProcessor(config, tokenizer: tokenizer)
                    .prepare(input: input(width: 64, height: 64))
                XCTFail("Invalid image token configuration must fail during input preparation.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("LFM"))
            }
        }
    }

    func testNestedNormalizationAndLimitsSurviveEncoding() throws {
        let config = try configuration("""
            {"image_processor":{"image_mean":[0.1,0.2,0.3],"image_std":[1,2,3],
              "do_image_splitting":false,"max_image_tokens":128,"max_num_patches":512}}
            """)
        let roundTrip = try JSONDecoder().decode(
            LFM2VLProcessorConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip.imageMean, [0.1, 0.2, 0.3])
        XCTAssertEqual(roundTrip.imageStd, [1, 2, 3])
        XCTAssertEqual(roundTrip.maxImageTokens, 128)
        XCTAssertEqual(roundTrip.maxNumPatches, 512)
        XCTAssertEqual(roundTrip.doImageSplitting, false)
        for invalid in ["{\"downsample_factor\":0}", "{\"image_processor\":{\"image_mean\":[0.5]}}"] {
            XCTAssertThrowsError(try configuration(invalid))
        }
    }
}
