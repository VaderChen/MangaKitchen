import CoreGraphics
import Foundation
import MangaKitchenCore

/// 從字形團塊的排列量出直排或橫排。
///
/// 既有規則只看文字區域的長寬比：`height > width * 0.8` 就當直排。但長寬比描述的是
/// 框的形狀，不是字的排列 —— 圓形對話框裡兩行橫排台詞的長寬比本來就接近 1，於是整批
/// 被判成直排。真正能分辨方向的是字與字的相鄰方向：直排的下一個字在正下方，橫排在
/// 正右方，這與框的形狀無關，單行與多行都成立。
public enum MangaTextDirectionDetector {
    /// 判定所需的最低優勢比例。低於此值代表排列本身就模稜兩可（例如只有一兩個字，
    /// 或斜排的擬聲字），交回 `automatic` 讓既有規則決定，不要硬猜一個方向。
    private static let minimumMargin = 0.2
    /// 視為同一個字的合併距離，相對於字形大小。濁點、偏旁與「い」這類分離筆畫
    /// 會被拆成多個元件，不先併回去就會產生大量方向隨機的短距離鄰居。
    private static let mergeRatio = 0.15
    /// 合併後仍可視為單一個字的大小上限，相對於字形大小。
    ///
    /// 只看距離無法分辨「同一個字的偏旁」與「相鄰的兩個字」—— 日文排版的字距本來
    /// 就近乎貼合，兩者的間隙一樣小。真正的差別在合併後的尺寸：偏旁併起來還是一個字，
    /// 相鄰兩個字併起來會有一邊變成兩倍。
    private static let maximumGlyphGrowth = 1.25

    public static func direction(forGlyphBoxes boxes: [CGRect]) -> WritingDirection {
        let glyphs = mergedGlyphs(from: boxes)
        guard glyphs.count >= 2 else { return .automatic }

        var verticalVotes = 0
        var horizontalVotes = 0
        for index in glyphs.indices {
            guard let neighbour = nearestNeighbour(of: index, in: glyphs) else { continue }
            let horizontalOffset = abs(neighbour.midX - glyphs[index].midX)
            let verticalOffset = abs(neighbour.midY - glyphs[index].midY)
            // 兩軸相等時不投票，避免對角排列灌票給任何一邊。
            if verticalOffset > horizontalOffset {
                verticalVotes += 1
            } else if horizontalOffset > verticalOffset {
                horizontalVotes += 1
            }
        }

        let total = verticalVotes + horizontalVotes
        guard total > 0 else { return .automatic }
        let margin = Double(abs(verticalVotes - horizontalVotes)) / Double(total)
        guard margin >= minimumMargin else { return .automatic }
        return verticalVotes > horizontalVotes ? .vertical : .horizontal
    }

    /// 把同一個字被拆開的筆畫併回單一團塊。
    private static func mergedGlyphs(from boxes: [CGRect]) -> [CGRect] {
        let valid = boxes.filter { $0.width > 0 && $0.height > 0 }
        guard valid.count > 1 else { return valid }

        // 字形大小取中位數：偏旁與濁點是少數，中位數不會被它們拉走。
        let sizes = valid.map { max($0.width, $0.height) }.sorted()
        let glyphSize = sizes[sizes.count / 2]
        let tolerance = glyphSize * mergeRatio

        let sizeLimit = glyphSize * maximumGlyphGrowth
        var blobs = valid
        var didMerge = true
        while didMerge {
            didMerge = false
            search: for left in blobs.indices {
                for right in blobs.indices where right > left {
                    guard blobs[left].insetBy(dx: -tolerance, dy: -tolerance)
                        .intersects(blobs[right]) else { continue }
                    let union = blobs[left].union(blobs[right])
                    guard max(union.width, union.height) <= sizeLimit else { continue }
                    blobs[left] = union
                    blobs.remove(at: right)
                    didMerge = true
                    break search
                }
            }
        }
        return blobs
    }

    private static func nearestNeighbour(of index: Int, in glyphs: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestDistance = Double.greatestFiniteMagnitude
        for other in glyphs.indices where other != index {
            let horizontalOffset = glyphs[other].midX - glyphs[index].midX
            let verticalOffset = glyphs[other].midY - glyphs[index].midY
            let distance = horizontalOffset * horizontalOffset + verticalOffset * verticalOffset
            if distance < bestDistance {
                bestDistance = distance
                best = glyphs[other]
            }
        }
        return best
    }
}
