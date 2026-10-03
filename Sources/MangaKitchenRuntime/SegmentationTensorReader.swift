import CoreML
import Foundation

/// Cache Core ML's Objective-C metadata once per output, not once per coefficient.
/// Retaining the array keeps its strided storage alive for the reader's lifetime.
struct SegmentationTensorReader {
    private let array: MLMultiArray
    private let pointer: UnsafeMutableRawPointer
    private let dataType: MLMultiArrayDataType
    let strides: [Int]

    init(_ array: MLMultiArray) {
        self.array = array
        pointer = array.dataPointer
        dataType = array.dataType
        strides = array.strides.map(\.intValue)
    }

    @inline(__always)
    func value(at offset: Int) -> Float {
        switch dataType {
        case .float32: pointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: Float(pointer.assumingMemoryBound(to: Double.self)[offset])
        case .float16: Float(pointer.assumingMemoryBound(to: Float16.self)[offset])
        default: 0 // Preserve the prototype decoder's unsupported-type behavior.
        }
    }

    @inline(__always)
    func value(batch: Int, feature: Int, candidate: Int) -> Float {
        switch dataType {
        case .float32, .double, .float16:
            value(at: batch * strides[0] + feature * strides[1] + candidate * strides[2])
        default:
            // Prediction arrays had a general Core ML fallback; keep that behavior.
            array[[NSNumber(value: batch), NSNumber(value: feature), NSNumber(value: candidate)]].floatValue
        }
    }
}
