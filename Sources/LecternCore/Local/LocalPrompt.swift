import Foundation

/// Shrinks a ContextBuilder prompt to a small model's window: a long outline is cut first, then pages
/// furthest from the current page are left out, then the current page is shortened. The rest of the
/// envelope and the question stay intact. Sizes are in model tokens (`LocalModelLimits.tokens`).
enum LocalPromptFitter {
    static func fit(_ input: String, maxTokens: Int) -> (text: String, trimmed: Bool) {
        let tokens = LocalModelLimits.tokens
        guard tokens(input) > maxTokens else { return (input, false) }
        var text = input
        var trimmed = false
        // Outline entries are short numbers and symbols, which cost the most tokens per character.
        if let line = text.range(of: #"(?m)^outline: .*$"#, options: .regularExpression), tokens(String(text[line])) > maxTokens / 8 {
            var kept = "outline:"
            for entry in text[line].dropFirst("outline: ".count).components(separatedBy: " · ") {
                guard tokens(kept + entry) < maxTokens / 8 else { kept += " · …"; break }
                kept += (kept == "outline:" ? " " : " · ") + entry
            }
            text.replaceSubrange(line, with: kept)
            trimmed = true
        }
        let total = tokens(text)
        guard total > maxTokens,
              let open = text.range(of: "<pages>\n"),
              let close = text.range(of: "\n</pages>", options: .backwards), open.upperBound <= close.lowerBound
        else { return (text, trimmed) }
        let body = String(text[open.upperBound..<close.lowerBound])
        var blocks = body.components(separatedBy: "\n=== Page").enumerated()
            .map { $0.offset == 0 ? $0.element : "=== Page" + $0.element }
        let pages = blocks.map { firstNumber(in: $0, after: #"^=== Pages? "#) ?? 0 }
        let current = firstNumber(in: text, after: "current page ") ?? pages.first ?? 0
        var remaining = maxTokens - (total - tokens(body)) - 24
        let order = blocks.indices.sorted { (abs(pages[$0] - current), pages[$0]) < (abs(pages[$1] - current), pages[$1]) }
        for i in order {
            let cost = tokens(blocks[i]) + 1
            if cost <= remaining {
                remaining -= cost
            } else if remaining > 150 {
                // Keep the start of this page, in proportion to what is left.
                let keep = Int(Double(blocks[i].count) * Double(remaining - 40) / Double(cost))
                blocks[i] = String(blocks[i].prefix(max(0, keep))) + "\n(… the rest of page \(pages[i]) was left out to fit this model)"
                remaining = 0
            } else {
                blocks[i] = "=== Page \(pages[i]) ===\n(left out to fit this model)"
            }
        }
        return (String(text[..<open.upperBound]) + blocks.joined(separator: "\n") + String(text[close.lowerBound...]), true)
    }

    private static func firstNumber(in s: String, after prefix: String) -> Int? {
        guard let r = s.range(of: prefix + #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r].drop { !$0.isNumber })
    }
}

/// Hides a leading `<think>…</think>` block that older reasoning models (e.g. deepseek-r1 without
/// Ollama's thinking support) write into the answer.
struct ThinkTagFilter {
    private enum State { case start, thinking, answer }
    private var state = State.start
    private var buffer = ""

    /// The visible part of a streamed chunk.
    mutating func consume(_ chunk: String) -> String {
        switch state {
        case .answer:
            return chunk
        case .start:
            buffer += chunk
            let head = buffer.drop { $0.isWhitespace }
            if head.hasPrefix("<think>") {
                state = .thinking
                buffer = String(head.dropFirst("<think>".count))
                return consume("")
            }
            if "<think>".hasPrefix(head) { return "" }   // could still become the tag
            state = .answer
            defer { buffer = "" }
            return buffer
        case .thinking:
            buffer += chunk
            guard let end = buffer.range(of: "</think>") else {
                buffer = String(buffer.suffix(8))
                return ""
            }
            state = .answer
            let rest = String(buffer[end.upperBound...].drop { $0.isWhitespace })
            buffer = ""
            return rest
        }
    }

    /// Text held back at the end of the stream (an answer shorter than the tag).
    mutating func flush() -> String {
        defer { buffer = "" }
        return state == .start ? buffer : ""
    }
}
