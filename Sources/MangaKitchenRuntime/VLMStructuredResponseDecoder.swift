import Foundation

enum VLMStructuredResponseDecoder {
    static let maximumAttempts = 3

    static func decodeArrays<Element: Decodable>(
        _: Element.Type,
        from response: String
    ) -> [[Element]] {
        let decoder = JSONDecoder()
        let arrays: [[Element]] = JSONCandidates.arrays(in: response).compactMap {
            candidate -> [Element]? in
            guard let data = candidate.data(using: .utf8) else { return nil }
            return try? decoder.decode([Element].self, from: data)
        }
        let singleObjects: [[Element]] = JSONCandidates.objects(in: response).compactMap {
            candidate -> [Element]? in
            guard let data = candidate.data(using: .utf8),
                  let value = try? decoder.decode(Element.self, from: data) else { return nil }
            return [value]
        }
        var decoded = arrays
        decoded.append(contentsOf: singleObjects)
        return decoded
    }

    static func retryInstruction(attempt: Int) -> String {
        guard attempt > 0 else { return "" }
        return """

        IMPORTANT RETRY: The previous answer was invalid or incomplete. Return only the requested
        JSON array. Do not use Markdown fences, analysis, commentary, or omit any requested item.
        """
    }

    static func mappedProgress(attempt: Int, value: Double) -> Double {
        let local = min(max(value, 0), 1)
        return (Double(attempt) + local) / Double(maximumAttempts)
    }

    private enum JSONCandidates {
        static func arrays(in response: String) -> [String] {
            balancedCandidates(in: response, opening: "[", closing: "]")
        }

        static func objects(in response: String) -> [String] {
            balancedCandidates(in: response, opening: "{", closing: "}")
        }

        private static func balancedCandidates(
            in response: String,
            opening: Character,
            closing: Character
        ) -> [String] {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            var candidates: [String] = [trimmed]
            var startIndex: String.Index?
            var depth = 0
            var isInsideString = false
            var isEscaping = false

            for index in trimmed.indices {
                let character = trimmed[index]
                if isInsideString {
                    if isEscaping {
                        isEscaping = false
                    } else if character == "\\" {
                        isEscaping = true
                    } else if character == "\"" {
                        isInsideString = false
                    }
                    continue
                }

                if character == "\"" {
                    isInsideString = true
                } else if character == opening {
                    if depth == 0 { startIndex = index }
                    depth += 1
                } else if character == closing, depth > 0 {
                    depth -= 1
                    if depth == 0, let arrayStart = startIndex {
                        candidates.append(String(trimmed[arrayStart...index]))
                        startIndex = nil
                    }
                }
            }

            var seen: Set<String> = []
            return candidates.filter { seen.insert($0).inserted }
        }
    }
}
