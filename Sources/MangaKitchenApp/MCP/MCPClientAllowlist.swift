import Darwin
import Foundation

struct MCPClientAllowlist: Sendable {
    enum ValidationError: LocalizedError {
        case invalidEntry(String)

        var errorDescription: String? {
            switch self {
            case let .invalidEntry(value):
                "無效的 MCP 用戶端位址或 CIDR：\(value)"
            }
        }
    }

    private struct Network: Sendable {
        var address: [UInt8]
        var prefixLength: Int

        func contains(_ candidate: [UInt8]) -> Bool {
            guard candidate.count == address.count else { return false }
            let wholeBytes = prefixLength / 8
            let remainingBits = prefixLength % 8
            guard candidate.prefix(wholeBytes) == address.prefix(wholeBytes) else { return false }
            guard remainingBits > 0 else { return true }
            let mask = UInt8(0xFF << (8 - remainingBits))
            return candidate[wholeBytes] & mask == address[wholeBytes] & mask
        }
    }

    let entries: [String]
    private let networks: [Network]

    init(entries: [String]) throws {
        let normalized = Self.normalizedEntries(entries)
        self.entries = normalized
        networks = try normalized.map(Self.parseNetwork)
    }

    func allows(_ address: String?) -> Bool {
        guard let address,
              let bytes = Self.addressBytes(address) else { return false }
        return networks.contains { $0.contains(bytes) }
    }

    static func validate(_ entries: [String]) throws {
        _ = try MCPClientAllowlist(entries: entries)
    }

    static func normalizedEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }.sorted()
    }

    private static func parseNetwork(_ value: String) throws -> Network {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let address = addressBytes(String(components[0])) else {
            throw ValidationError.invalidEntry(value)
        }
        let maximumPrefix = address.count * 8
        let prefixLength: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]), (0...maximumPrefix).contains(parsed) else {
                throw ValidationError.invalidEntry(value)
            }
            prefixLength = parsed
        } else {
            prefixLength = maximumPrefix
        }
        return Network(address: address, prefixLength: prefixLength)
    }

    private static func addressBytes(_ rawValue: String) -> [UInt8]? {
        let value = rawValue.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawValue
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }
}

/// 三態欄位更新：省略代表不變，明確 null 代表清除，帶值代表設定。
/// 用於 nil 本身就是有效狀態的欄位，例如 bubbleBounds。
enum MCPFieldUpdate<Value> {
    case unchanged
    case clear
    case set(Value)

    /// 套用到既有值上。
    func applied(to current: Value?) -> Value? {
        switch self {
        case .unchanged: current
        case .clear: nil
        case let .set(value): value
        }
    }

    var isChange: Bool {
        if case .unchanged = self { return false }
        return true
    }
}
