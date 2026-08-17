import CoreGraphics
import Foundation
import MangaKitchenCore

/// Qwen grounding 同時可能回傳純座標陣列，或官方 `bbox_2d` 物件格式。
struct VLMGroundingBox: Decodable, Equatable {
    var coordinates: [Double]

    private enum CodingKeys: String, CodingKey {
        case bbox2D = "bbox_2d"
        case bbox
        case box
        case textBox = "text_box"
    }

    init(from decoder: any Decoder) throws {
        if let values = try? decoder.singleValueContainer().decode([Double].self),
           values.count == 4 {
            coordinates = values
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.bbox2D, .bbox, .box, .textBox] {
            if let values = try container.decodeIfPresent([Double].self, forKey: key),
               values.count == 4 {
                coordinates = values
                return
            }
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Grounding box must contain four numeric coordinates."
        ))
    }
}

/// 將 Qwen3-VL 以 0...1000 回傳的裁切圖座標映射回整頁正規化座標。
enum VLMTextGrounding {
    static let coordinateMaximum = 1_000.0

    static func pageBounds(
        modelBoxes: [[Double]],
        cropRect: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        clippingBounds: NormalizedRect?,
        paddingFraction: Double = 0.08
    ) -> NormalizedRect? {
        guard imageWidth > 0, imageHeight > 0,
              cropRect.width > 0, cropRect.height > 0,
              !modelBoxes.isEmpty, modelBoxes.count <= 16 else { return nil }

        var rectangles: [NormalizedRect] = []
        for values in modelBoxes {
            guard values.count == 4,
                  values.allSatisfy(\.isFinite),
                  values.allSatisfy({ (0...coordinateMaximum).contains($0) }) else {
                return nil
            }
            let left = min(values[0], values[2]) / coordinateMaximum
            let top = min(values[1], values[3]) / coordinateMaximum
            let right = max(values[0], values[2]) / coordinateMaximum
            let bottom = max(values[1], values[3]) / coordinateMaximum
            guard right - left >= 0.002, bottom - top >= 0.002 else { return nil }

            let raw = NormalizedRect(
                x: (cropRect.minX + left * cropRect.width) / Double(imageWidth),
                y: (cropRect.minY + top * cropRect.height) / Double(imageHeight),
                width: (right - left) * cropRect.width / Double(imageWidth),
                height: (bottom - top) * cropRect.height / Double(imageHeight)
            ).clamped()
            let padded = raw.expanded(by: paddingFraction)
            if let clippingBounds {
                let rawClipped = raw.intersection(with: clippingBounds)
                let clipped = padded.intersection(with: clippingBounds)
                let rawArea = max(raw.width * raw.height, .leastNonzeroMagnitude)
                let overlapArea = rawClipped.width * rawClipped.height
                // 座標大半落在候選外時視為 grounding 漂移，不可拿來放大遮罩。
                guard overlapArea / rawArea >= 0.7,
                      clipped.width > 0, clipped.height > 0 else { return nil }
                rectangles.append(clipped)
            } else {
                rectangles.append(padded)
            }
        }
        guard let first = rectangles.first else { return nil }
        return rectangles.dropFirst().reduce(first) { $0.union(with: $1) }
    }
}
