import Combine
import Foundation
import MangaKitchenCore

struct ApplicationLogEntry: Encodable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: RuntimeLogLevel
    var category: String
    var message: String
}

/// 只存在記憶體中的環形 LOG；不編碼進偏好設定或專案快照。
@MainActor
final class ApplicationLogStore: ObservableObject {
    @Published private(set) var entries: [ApplicationLogEntry] = []

    private let maximumEntryCount = 500
    private let maximumMessageLength = 8_000

    func append(
        _ level: RuntimeLogLevel,
        category: String,
        message: String
    ) {
        let normalizedCategory = String(
            category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        )
        let normalizedMessage = String(
            message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumMessageLength)
        )
        guard !normalizedMessage.isEmpty else { return }
        entries.append(ApplicationLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: normalizedCategory.isEmpty ? "App" : normalizedCategory,
            message: normalizedMessage
        ))
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func runtimeHandler() -> RuntimeLogHandler {
        { [weak self] level, category, message in
            Task { @MainActor [weak self] in
                self?.append(level, category: category, message: message)
            }
        }
    }
}
