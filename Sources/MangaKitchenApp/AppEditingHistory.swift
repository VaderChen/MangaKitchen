import Foundation
import MangaKitchenCore

/// 集中管理頁面編輯的暫存歷程，不負責修改頁面內容或觸發持久化。
@MainActor
final class AppEditingHistory {
    private var maskRedoStrokes: [UUID: [UUID: [MaskStroke]]] = [:]
    private var colorizationRedoStrokes: [UUID: [MaskStroke]] = [:]
    private var maskRevisions: [UUID: UInt64] = [:]
    private var regionUndoHistory: [UUID: [[DialogueRegion]]] = [:]
    private var regionRedoHistory: [UUID: [[DialogueRegion]]] = [:]

    func clear(pageID: UUID) {
        maskRedoStrokes[pageID] = nil
        colorizationRedoStrokes[pageID] = nil
        maskRevisions[pageID] = nil
        regionUndoHistory[pageID] = nil
        regionRedoHistory[pageID] = nil
    }

    func clearAll() {
        maskRedoStrokes.removeAll()
        colorizationRedoStrokes.removeAll()
        maskRevisions.removeAll()
        regionUndoHistory.removeAll()
        regionRedoHistory.removeAll()
    }

    func pushMaskRedoStroke(_ stroke: MaskStroke, pageID: UUID, regionID: UUID) {
        maskRedoStrokes[pageID, default: [:]][regionID, default: []].append(stroke)
    }

    func popMaskRedoStroke(pageID: UUID, regionID: UUID) -> MaskStroke? {
        guard var pageHistory = maskRedoStrokes[pageID],
              var regionHistory = pageHistory[regionID],
              let stroke = regionHistory.popLast() else { return nil }
        pageHistory[regionID] = regionHistory.isEmpty ? nil : regionHistory
        maskRedoStrokes[pageID] = pageHistory.isEmpty ? nil : pageHistory
        return stroke
    }

    func clearMaskRedo(pageID: UUID, regionID: UUID? = nil) {
        guard let regionID else {
            maskRedoStrokes[pageID] = nil
            return
        }
        guard var pageHistory = maskRedoStrokes[pageID] else { return }
        pageHistory[regionID] = nil
        maskRedoStrokes[pageID] = pageHistory.isEmpty ? nil : pageHistory
    }

    func maskRedoRegionIDs(pageID: UUID) -> [UUID] {
        maskRedoStrokes[pageID]?.compactMap { regionID, strokes in
            strokes.isEmpty ? nil : regionID
        } ?? []
    }

    func clearColorizationRedo(pageID: UUID) {
        colorizationRedoStrokes[pageID] = nil
    }

    func pushColorizationRedoStroke(_ stroke: MaskStroke, pageID: UUID) {
        colorizationRedoStrokes[pageID, default: []].append(stroke)
    }

    func popColorizationRedoStroke(pageID: UUID) -> MaskStroke? {
        guard var history = colorizationRedoStrokes[pageID],
              let stroke = history.popLast() else { return nil }
        colorizationRedoStrokes[pageID] = history.isEmpty ? nil : history
        return stroke
    }

    func hasColorizationRedo(pageID: UUID) -> Bool {
        !(colorizationRedoStrokes[pageID]?.isEmpty ?? true)
    }

    func maskRevision(pageID: UUID) -> UInt64 {
        maskRevisions[pageID] ?? 0
    }

    func advanceMaskRevision(pageID: UUID) {
        maskRevisions[pageID, default: 0] &+= 1
    }

    func recordRegions(pageID: UUID, regions: [DialogueRegion]) {
        var history = regionUndoHistory[pageID] ?? []
        if history.last != regions { history.append(regions) }
        if history.count > 50 { history.removeFirst(history.count - 50) }
        regionUndoHistory[pageID] = history
        regionRedoHistory[pageID] = nil
    }

    func undoRegions(pageID: UUID, current: [DialogueRegion]) -> [DialogueRegion]? {
        guard var history = regionUndoHistory[pageID],
              let previous = history.popLast() else { return nil }
        regionUndoHistory[pageID] = history.isEmpty ? nil : history
        regionRedoHistory[pageID, default: []].append(current)
        return previous
    }

    func redoRegions(pageID: UUID, current: [DialogueRegion]) -> [DialogueRegion]? {
        guard var history = regionRedoHistory[pageID],
              let next = history.popLast() else { return nil }
        regionRedoHistory[pageID] = history.isEmpty ? nil : history
        regionUndoHistory[pageID, default: []].append(current)
        return next
    }
}
