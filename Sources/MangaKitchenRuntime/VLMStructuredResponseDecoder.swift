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
        if let finalChannel = harmonyFinalChannel(from: response) {
            return finalChannel
        }
        if response.contains("<|channel|>analysis") || response.contains("<|start|>assistant") {
            // Harmony 回覆若尚未進入 final channel，所有內容都仍屬於
            // reasoning，不能從其中誤撿 JSON 片段。
            return ""
        }
        if let gemmaVisibleChannel = gemmaVisibleChannel(from: response) {
            return gemmaVisibleChannel
        }
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

    private static func harmonyFinalChannel(from response: String) -> String? {
        let marker: Range<String.Index>
        if let fullMarker = response.range(
            of: "<|channel|>final<|message|>",
            options: .backwards
        ) {
            marker = fullMarker
        } else if let shortMarker = response.range(of: "<|channel|>final", options: .backwards) {
            marker = shortMarker
        } else {
            return nil
        }

        var value = String(response[marker.upperBound...])
        for terminator in ["<|return|>", "<|end|>"] {
            if let range = value.range(of: terminator) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        return value
    }

    private static func gemmaVisibleChannel(from response: String) -> String? {
        let hasThoughtChannel = response.contains("<|channel>thought")
        let hasGemmaMarker = hasThoughtChannel
            || response.contains("<|channel>")
            || response.contains("<channel|>")
            || response.contains("<|turn>model")
            || response.contains("<turn|>")
        guard hasGemmaMarker else { return nil }

        var value = response
        if hasThoughtChannel {
            guard let close = value.range(of: "<channel|>", options: .backwards) else {
                return ""
            }
            value = String(value[close.upperBound...])
        } else if let close = value.range(of: "<channel|>", options: .backwards) {
            value = String(value[close.upperBound...])
        }
        if let modelTurn = value.range(of: "<|turn>model") {
            value = String(value[modelTurn.upperBound...])
        }
        for marker in ["<turn|>", "<|tool_response>", "<tool_response|>"] {
            if let end = value.range(of: marker) {
                value = String(value[..<end.lowerBound])
                break
            }
        }
        return value
    }

    static let finalJSONInstruction = """
    The final answer must contain only the requested JSON. If the runtime enables a <think>
    phase, use only a brief lightweight analysis (at most about 256 tokens), finish it, and
    output the JSON immediately after </think>. Do not explore multiple alternatives.
    Never put the final JSON inside the thinking phase. After the thinking boundary, do not
    use Markdown fences, analysis, reasoning, commentary, or any text around the final JSON.
    If your chat format uses Harmony channels, keep any analysis brief and put the complete JSON
    only in the final channel. Never put the JSON in the analysis or commentary channel.
    """

    /// 用於 UI 即時顯示的 thinking 內容。Qwen chat template 可能已把
    /// `<think>` 放在 prompt，因此串流本身常常只有內容與 `</think>`。
    /// 最終 JSON 一定排除，避免將機器資料誤當推理文字。
    static func streamedReasoningText(from response: String) -> String {
        if response.contains("<|channel|>analysis") || response.contains("<|channel|>final") {
            guard let analysis = response.range(
                of: "<|channel|>analysis<|message|>",
                options: .backwards
            ) else {
                return ""
            }
            var value = String(response[analysis.upperBound...])
            if let end = value.range(of: "<|end|>") {
                value = String(value[..<end.lowerBound])
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if response.contains("<|channel>") || response.contains("<channel|>") {
            guard let start = response.range(of: "<|channel>thought", options: .backwards) else {
                return ""
            }
            let end = response.range(of: "<channel|>", range: start.upperBound..<response.endIndex)
            let upperBound = end?.lowerBound ?? response.endIndex
            return String(response[start.upperBound..<upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        JSON inside reasoning. Do not use Markdown fences, analysis, commentary, placeholders such
        as "..." or "translated text", or omit any requested item. Every translation value must
        be actual text in the requested target language.
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
            var startIndices: [String.Index] = []
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
                    startIndices.append(index)
                    depth += 1
                } else if character == closing, depth > 0 {
                    depth -= 1
                    if let candidateStart = startIndices.popLast() {
                        candidates.append(String(trimmed[candidateStart...index]))
                    }
                }
            }

            var seen: Set<String> = []
            return candidates.filter { seen.insert($0).inserted }
        }
    }
}
