import CoreML
import XCTest
@testable import MangaKitchenRuntime

final class SegmentationTensorReaderTests: XCTestCase {
    func testStridedFloatingStorageMatchesCoreMLCoordinates() throws {
        for dataType in [MLMultiArrayDataType.float16, .float32, .double] {
            let byteCount = 64 * MemoryLayout<Double>.stride
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            let array = try MLMultiArray(
                dataPointer: pointer, shape: [1, 3, 4], dataType: dataType,
                strides: [64, 12, 2], deallocator: { $0.deallocate() })
            for feature in 0..<3 {
                for candidate in 0..<4 {
                    array[[0, NSNumber(value: feature), NSNumber(value: candidate)]] =
                        NSNumber(value: Double(feature * 8 - candidate) * 0.125)
                }
            }
            let reader = SegmentationTensorReader(array)
            for feature in 0..<3 {
                for candidate in 0..<4 {
                    let expected = array[[0, NSNumber(value: feature), NSNumber(value: candidate)]].floatValue
                    XCTAssertEqual(reader.value(batch: 0, feature: feature, candidate: candidate), expected)
                    XCTAssertEqual(reader.value(at: feature * 12 + candidate * 2), expected)
                }
            }
        }
    }

    func testReaderRetainsStorageAndPreservesIntegerPredictionFallback() throws {
        func reader() throws -> SegmentationTensorReader {
            let array = try MLMultiArray(shape: [1, 2, 3], dataType: .int32)
            array[[0, 1, 2]] = -37
            return SegmentationTensorReader(array)
        }
        let retained = try reader()
        XCTAssertEqual(retained.value(batch: 0, feature: 1, candidate: 2), -37)
        XCTAssertEqual(retained.value(at: 5), 0, "Unsupported prototypes must keep their previous zero behavior.")
    }
}
