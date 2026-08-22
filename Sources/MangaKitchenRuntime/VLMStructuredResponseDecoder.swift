import Foundation

enum VLMStructuredResponseDecoder {
    static let maximumAttempts = 3

    static func decodeArrays<Element: Decodable>(
        _: Element.Type,
        from response: String
    ) -> [[Element]] {
        let response = stripReasoning(from: response)
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

    /// Qwen 的 chat template 可能把 `<think>` 起始標記放在 prompt，所以
    /// generate 結果只會包含 reasoning、`</think>` 與最終 JSON。結構化流程
    /// 必須以最後一個結束標記為準，不能假設回覆內一定有成對的起始標記。
    private static func stripReasoning(from response: String) -> String {
        if let end = response.range(of: "</think>", options: .backwards) {
            let finalAnswer = String(response[end.upperBound...])
            // 最後一個 </think> 後又出現未關閉的 thinking，代表模型尚未
            // 產生完整 final answer；不可從 reasoning 內誤撿 JSON 片段。
            guard !finalAnswer.contains("<think>") else { return "" }
            return finalAnswer
        }
        // 只有起始標記表示 token 預算在 thinking 期間用完，此時沒有
        // 可信的最終結果。
        guard !response.contains("<think>") else { return "" }
        return response
    }

    static let finalJSONInstruction = """
    The final answer must contain only the requested JSON. If the runtime enables a <think>
    phase, use only a brief lightweight analysis (at most about 256 tokens), finish it, and
    output the JSON immediately after </think>. Do not explore multiple alternatives.
    Never put the final JSON inside the thinking phase. After the thinking boundary, do not
    use Markdown fences, analysis, reasoning, commentary, or any text around the final JSON.
    """

    /// 用於 UI 即時顯示的 thinking 內容。Qwen chat template 可能已把
    /// `<think>` 放在 prompt，因此串流本身常常只有內容與 `</think>`。
    /// 最終 JSON 一定排除，避免將機器資料誤當推理文字。
    static func streamedReasoningText(from response: String) -> String {
        var value = response
        if let end = value.range(of: "</think>") {
            value = String(value[..<end.lowerBound])
        }
        if let start = value.range(of: "<think>") {
            value = String(value[start.upperBound...])
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !response.contains("<think>"),
           !response.contains("</think>"),
           (trimmed.hasPrefix("[")
               || trimmed.hasPrefix("{")
               || trimmed.lowercased().hasPrefix("```json")) {
            return ""
        }
        return trimmed
    }

    /// 判斷 thinking 之後是否已有完整 JSON，不只檢查 `[` 或 `{`，
    /// 避免 token 額度在陣列中途用完時將截斷內容當成成功。
    static func hasCompleteStructuredFinalAnswer(_ response: String) -> Bool {
        let finalAnswer = stripReasoning(from: response)
        let candidates = JSONCandidates.arrays(in: finalAnswer)
            + JSONCandidates.objects(in: finalAnswer)
        return candidates.contains { candidate in
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else {
                return false
            }
            return value is [Any] || value is [String: Any]
        }
    }

    /// Thinking 額度用完後的強制收尾 prompt。保留簡短思考當作語境，
    /// 但第二段由 runtime 關閉 thinking，只允許產生最終 JSON。
    static func nonThinkingFinalizationPrompt(
        originalPrompt: String,
        reasoningResponse: String
    ) -> String {
        let reasoning = String(
            streamedReasoningText(from: reasoningResponse).prefix(4_000)
        )
        return """
        \(originalPrompt)

        FINALIZATION: A brief reasoning pass has already been completed. Do not reason again.
        Use the notes below only as private context, then output the requested complete JSON now.
        Do not output <think>, Markdown, analysis, commentary, or any text around the JSON.

        Brief reasoning notes:
        \(reasoning.isEmpty ? "No usable notes were produced." : reasoning)
        """
    }

    static func retryInstruction(attempt: Int) -> String {
        guard attempt > 0 else { return "" }
        return """

        IMPORTANT RETRY: The previous answer was invalid or incomplete. Finish any enabled thinking
        phase first, then return only the requested JSON array after </think>. Do not put the final
        JSON inside reasoning. Do not use Markdown fences, analysis, commentary, or omit any
        requested item.
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
