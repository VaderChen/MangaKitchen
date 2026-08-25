import MangaKitchenCore

/// 翻譯頁面各階段映射到整體進度的唯一規則。
public enum PageWorkflowProgress {
    public static func overall(stage: PageProcessingStage, fraction: Double) -> Double {
        let value = min(max(fraction, 0), 1)
        return switch stage {
        case .pending: 0
        case .scanned: 0.02
        case .detectingText: value * 0.25
        case .maskReady: 0.25
        case .translating: 0.25 + value * 0.4
        case .translationReady: 0.65
        case .superResolving: 0.65 + value * 0.35
        case .composing: 0.65 + value * 0.35
        case .recognizing: value * 0.15
        case .masking: 0.55 + value * 0.05
        case .restoringBackground: 0.6 + value * 0.25
        case .typesetting: 0.85 + value * 0.15
        case .completed: 1
        case .failed: 0
        }
    }
}
