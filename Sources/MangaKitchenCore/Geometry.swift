import Foundation

/// 以左上角為原點的正規化座標點，所有數值皆介於 0...1。
public struct NormalizedPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func clamped() -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

/// 以左上角為原點的正規化矩形，所有數值皆介於 0...1。
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    public func clamped() -> NormalizedRect {
        let left = min(max(minX, 0), 1)
        let top = min(max(minY, 0), 1)
        let right = min(max(maxX, left), 1)
        let bottom = min(max(maxY, top), 1)
        return NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func expanded(by fraction: Double) -> NormalizedRect {
        let horizontal = width * max(0, fraction)
        let vertical = height * max(0, fraction)
        return NormalizedRect(
            x: x - horizontal,
            y: y - vertical,
            width: width + horizontal * 2,
            height: height + vertical * 2
        ).clamped()
    }

    public func union(with other: NormalizedRect) -> NormalizedRect {
        let left = min(minX, other.minX)
        let top = min(minY, other.minY)
        let right = max(maxX, other.maxX)
        let bottom = max(maxY, other.maxY)
        return NormalizedRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        ).clamped()
    }

    public func intersection(with other: NormalizedRect) -> NormalizedRect {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else {
            return NormalizedRect(x: left, y: top, width: 0, height: 0).clamped()
        }
        return NormalizedRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        ).clamped()
    }
}
