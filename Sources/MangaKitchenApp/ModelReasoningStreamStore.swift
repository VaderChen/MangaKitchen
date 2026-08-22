import Combine
import Foundation
import MangaKitchenCore

struct ModelReasoningStreamSnapshot: Encodable, Sendable {
    var id: UUID?
    var text: String
    var isActive: Bool
}

/// 只保留當前一次模型 thinking 的記憶體狀態。這不是 LOG，不會被持久化。
@MainActor
final class ModelReasoningStreamStore: ObservableObject {
    @Published private(set) var snapshot = ModelReasoningStreamSnapshot(
        id: nil,
        text: "",
        isActive: false
    )

    /// 限制 WebState 大小，避免異常模型長時重複 thinking 撐大 UI 同步資料。
    private let maximumCharacterCount = 32_000

    func handle(_ event: RuntimeReasoningStreamEvent) {
        switch event {
        case let .started(id):
            snapshot = ModelReasoningStreamSnapshot(id: id, text: "", isActive: true)
        case let .updated(id, text):
            guard snapshot.id == id else { return }
            snapshot.text = String(text.prefix(maximumCharacterCount))
        case let .finished(id):
            guard snapshot.id == id else { return }
            snapshot.isActive = false
        }
    }

    func runtimeHandler() -> RuntimeReasoningStreamHandler {
        { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }
}
