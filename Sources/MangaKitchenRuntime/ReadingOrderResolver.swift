import Foundation
import MangaKitchenCore

enum ReadingOrderResolver {
    static func sorted(
        _ regions: [DialogueRegion],
        direction: ReadingDirection
    ) -> [DialogueRegion] {
        guard regions.count > 1 else { return regions }

        let verticalCount = regions.filter {
            $0.bounds.height > $0.bounds.width * 1.35
        }.count
        if verticalCount * 2 >= regions.count || direction == .topToBottom {
            return regions.sorted { lhs, rhs in
                if abs(lhs.bounds.centerX - rhs.bounds.centerX) > 0.08 {
                    switch direction {
                    case .leftToRight: lhs.bounds.centerX < rhs.bounds.centerX
                    case .rightToLeft, .topToBottom: lhs.bounds.centerX > rhs.bounds.centerX
                    }
                } else {
                    lhs.bounds.centerY < rhs.bounds.centerY
                }
            }
        }

        let averageHeight = regions.map(\.bounds.height).reduce(0, +) / Double(regions.count)
        let rowTolerance = max(0.025, averageHeight * 0.65)
        return regions.sorted { lhs, rhs in
            if abs(lhs.bounds.centerY - rhs.bounds.centerY) > rowTolerance {
                return lhs.bounds.centerY < rhs.bounds.centerY
            }
            switch direction {
            case .rightToLeft: return lhs.bounds.centerX > rhs.bounds.centerX
            case .leftToRight, .topToBottom: return lhs.bounds.centerX < rhs.bounds.centerX
            }
        }
    }
}
