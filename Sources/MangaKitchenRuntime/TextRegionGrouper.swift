import Foundation
import MangaKitchenCore

/// 將 Vision 偏向逐行輸出的結果合併成可排版的對話區塊。
/// 採幾何連通元件而非語言特例，因此橫排與直排漫畫都能共用。
enum TextRegionGrouper {
    static func merge(_ input: [DialogueRegion]) -> [DialogueRegion] {
        guard input.count > 1 else { return input }
        var parent = Array(input.indices)

        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            return current
        }

        func shouldMerge(_ lhs: DialogueRegion, _ rhs: DialogueRegion) -> Bool {
            let a = lhs.bounds
            let b = rhs.bounds
            let bothVertical = a.height > a.width * 1.25 && b.height > b.width * 1.25

            let horizontalOverlap = overlap(a.minX, a.maxX, b.minX, b.maxX)
            let verticalOverlap = overlap(a.minY, a.maxY, b.minY, b.maxY)
            let horizontalGap = gap(a.minX, a.maxX, b.minX, b.maxX)
            let verticalGap = gap(a.minY, a.maxY, b.minY, b.maxY)

            if bothVertical {
                let alignment = verticalOverlap / max(0.0001, min(a.height, b.height))
                let closeColumns = horizontalGap <= max(0.012, max(a.width, b.width) * 1.25)
                let similarTop = abs(a.centerY - b.centerY) <= max(a.height, b.height) * 0.65
                return closeColumns && (alignment >= 0.22 || similarTop)
            }

            let alignment = horizontalOverlap / max(0.0001, min(a.width, b.width))
            let closeLines = verticalGap <= max(0.012, max(a.height, b.height) * 1.25)
            let similarCenter = abs(a.centerX - b.centerX) <= max(a.width, b.width) * 0.55
            return closeLines && (alignment >= 0.22 || similarCenter)
        }

        for left in input.indices {
            for right in input.indices where right > left && shouldMerge(input[left], input[right]) {
                let leftRoot = root(left)
                let rightRoot = root(right)
                if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
            }
        }

        var groups: [Int: [DialogueRegion]] = [:]
        for index in input.indices {
            groups[root(index), default: []].append(input[index])
        }
        return groups.values.map(mergeGroup)
    }

    private static func mergeGroup(_ group: [DialogueRegion]) -> DialogueRegion {
        guard group.count > 1 else { return group[0] }
        let isVertical = group.filter { $0.bounds.height > $0.bounds.width * 1.25 }.count * 2 >= group.count
        let ordered = group.sorted { lhs, rhs in
            if isVertical, abs(lhs.bounds.centerX - rhs.bounds.centerX) > 0.015 {
                return lhs.bounds.centerX > rhs.bounds.centerX
            }
            if abs(lhs.bounds.centerY - rhs.bounds.centerY) > 0.015 {
                return lhs.bounds.centerY < rhs.bounds.centerY
            }
            return lhs.bounds.centerX < rhs.bounds.centerX
        }

        let minX = group.map(\.bounds.minX).min() ?? 0
        let minY = group.map(\.bounds.minY).min() ?? 0
        let maxX = group.map(\.bounds.maxX).max() ?? 0
        let maxY = group.map(\.bounds.maxY).max() ?? 0
        let confidence = group.map(\.confidence).reduce(0, +) / Double(group.count)
        return DialogueRegion(
            bounds: NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            rawSourceText: ordered.map { $0.rawSourceText ?? $0.sourceText }.joined(separator: "\n"),
            sourceText: ordered.map(\.sourceText).joined(separator: "\n"),
            confidence: confidence,
            maskPolygons: group.flatMap(\.maskPolygons)
        )
    }

    private static func overlap(_ aMin: Double, _ aMax: Double, _ bMin: Double, _ bMax: Double) -> Double {
        max(0, min(aMax, bMax) - max(aMin, bMin))
    }

    private static func gap(_ aMin: Double, _ aMax: Double, _ bMin: Double, _ bMax: Double) -> Double {
        max(0, max(aMin, bMin) - min(aMax, bMax))
    }
}
