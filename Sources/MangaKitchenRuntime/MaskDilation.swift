import Foundation

/// 二值遮罩的方形膨脹。取樣時要避開遮罩附近的抗鋸齒殘留，CPU 與 GPU 兩個
/// 合成後端都需要同一份「排除範圍」，因此獨立成共用實作。
enum MaskDilation {
    /// 以 Chebyshev 距離膨脹 `radius` 像素。分成水平、垂直兩趟，複雜度與半徑無關。
    static func dilated(
        _ mask: [Bool],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Bool] {
        guard radius > 0, width > 0, height > 0 else { return mask }
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            let row = y * width
            var remaining = 0
            // 由左往右：遇到前景就讓後續 radius 個像素也算前景。
            for x in 0..<width {
                if mask[row + x] { remaining = radius + 1 }
                if remaining > 0 { horizontal[row + x] = true; remaining -= 1 }
            }
            remaining = 0
            for x in stride(from: width - 1, through: 0, by: -1) {
                if mask[row + x] { remaining = radius + 1 }
                if remaining > 0 { horizontal[row + x] = true; remaining -= 1 }
            }
        }

        var result = [Bool](repeating: false, count: mask.count)
        for x in 0..<width {
            var remaining = 0
            for y in 0..<height {
                if horizontal[y * width + x] { remaining = radius + 1 }
                if remaining > 0 { result[y * width + x] = true; remaining -= 1 }
            }
            remaining = 0
            for y in stride(from: height - 1, through: 0, by: -1) {
                if horizontal[y * width + x] { remaining = radius + 1 }
                if remaining > 0 { result[y * width + x] = true; remaining -= 1 }
            }
        }
        return result
    }
}
