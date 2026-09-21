import Foundation
import MangaKitchenCore

/// 將 WebKit 傳入的弱型別參數轉為應用程式使用的領域型別。
///
/// 此型別不保存狀態，也不執行任何業務操作；所有 bridge 指令共用相同的
/// 數值容錯、有限值檢查與座標正規化規則。
enum WebBridgeParameterDecoder {
    static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    static func double(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let string = value as? String { result = Double(string) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            // 先保留完整的 Int 精度，再處理 42.0 等浮點表示；不截斷或溢位。
            return Int(number.stringValue) ?? Int(exactly: number.doubleValue)
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func normalizedRect(_ value: Any?) -> NormalizedRect? {
        guard let raw = value as? [String: Any],
              let x = double(raw["x"]),
              let y = double(raw["y"]),
              let width = double(raw["width"]),
              let height = double(raw["height"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    static func normalizedPoint(_ value: Any?) -> NormalizedPoint? {
        guard let raw = value as? [String: Any],
              let x = double(raw["x"]),
              let y = double(raw["y"]),
              x.isFinite, y.isFinite else { return nil }
        return NormalizedPoint(x: x, y: y).clamped()
    }

    static func normalizedPolygons(_ value: Any?) -> [[NormalizedPoint]]? {
        guard let rawPolygons = value as? [Any] else { return nil }
        var result: [[NormalizedPoint]] = []
        for rawPolygon in rawPolygons {
            guard let rawPoints = rawPolygon as? [Any], rawPoints.count >= 3 else { return nil }
            var points: [NormalizedPoint] = []
            for rawPoint in rawPoints {
                guard let object = rawPoint as? [String: Any],
                      let x = double(object["x"]),
                      let y = double(object["y"]),
                      x.isFinite, y.isFinite else { return nil }
                points.append(NormalizedPoint(x: x, y: y).clamped())
            }
            result.append(points)
        }
        return result
    }
}
