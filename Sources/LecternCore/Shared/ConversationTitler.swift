import Foundation

/// Short topic titles for conversations: a local fallback from the first question, and a 2–6 word
/// title written by the provider's lightest model once the first answer is in.
public enum ConversationTitler {
    /// Seconds a model title may take, end to end; after that the fallback stays.
    static let timeout: TimeInterval = 20
    static let claudeModel = "haiku"
    static let maxTitleLength = 48

    /// Local fallback: a short title from the first question (trimmed to ~5 words / 40 chars; strips "Explain:" style prefixes and quotes).
    public static func fallbackTitle(question: String) -> String {
        var text = collapse(question)
        // "Explain: “…”" (Ask Lectern): drop the action label when a quotation follows it.
        if let label = text.range(of: #"^\p{L}[\p{L} ]{0,30}[:：]\s*(?=["“‘'「『«])"#, options: .regularExpression) {
            text.removeSubrange(label)
        }
        text = trim(text.trimmingCharacters(in: quotes.union(.whitespaces).union(CharacterSet(charactersIn: "…"))))
        guard !text.isEmpty else { return "New conversation" }  // same as an untitled panel

        var short = text
        let words = text.split(separator: " ")
        if words.count > 5 { short = words.prefix(5).joined(separator: " ") }
        let cap = text.unicodeScalars.contains(where: isCJK) ? 18 : 40
        if short.count > cap {
            short = String(short.prefix(cap))
            // Back off to a word boundary when there is one.
            if let space = short.lastIndex(of: " "), short.distance(from: short.startIndex, to: space) >= cap / 2 {
                short = String(short[..<space])
            }
        }
        short = trim(short)
        // Only a closing "?" was cut: keep the whole question.
        if text.dropFirst(short.count).allSatisfy({ "?？ ".contains($0) }) { return text }
        return short + "…"
    }

    /// 2–6 word topic title in the question's language (Chinese question → Chinese title), no quotes or trailing period.
    /// Uses the cheapest suitable model of `provider` via a one-shot call; nil on any failure, timeout (~20 s), signed-out
    /// state, or (Codex) when the purchased-credits guard would block (quota unknown or included usage exhausted).
    @MainActor public static func title(question: String, answer: String, provider: Provider,
                                        claude: ClaudeService, codex: CodexService) async -> String? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prompt = prompt(question: question, answer: answer)
        let reply: String?
        switch provider {
        case .claude:
            guard claude.authState.isSignedIn else { return nil }
            reply = await withDeadline(timeout) { await claude.oneShot(prompt: prompt, model: claudeModel, timeout: timeout) }
        case .codex:
            // oneShot also applies the purchased-credits guard.
            guard codex.authState.isSignedIn else { return nil }
            reply = await withDeadline(timeout) { await codex.oneShot(prompt: prompt, timeout: timeout) }
        case .grok, .local:
            // Titles for these use the local fallback for now.
            reply = nil
        }
        return reply.flatMap(cleanTitle)
    }

    // MARK: - Helpers

    static func prompt(question: String, answer: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Write a 2–6 word title for a conversation about this. Use the language of the question. "
            + "Reply with the title only, no quotes or period.\nQuestion: \(q.prefix(600))\nAnswer: \(a.prefix(600))"
    }

    /// The model's reply as a title: first line, no markdown, label, quotes or trailing punctuation, ≤ 48 chars.
    static func cleanTitle(_ reply: String) -> String? {
        guard var line = reply.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("```") }) else { return nil }
        line = line.replacingOccurrences(of: #"\*+|`+|__"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for pattern in [#"^(#{1,6}\s*|[-+•>]\s+|\d+[.)]\s+)+"#, #"^(title|标题)\s*[:：]\s*"#] {
            line = line.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        var title = trim(collapse(line))
        if title.count > maxTitleLength {
            title = String(title.prefix(maxTitleLength))
            if let space = title.lastIndex(of: " "), title.distance(from: title.startIndex, to: space) >= maxTitleLength / 2 {
                title = String(title[..<space])
            }
            title = trim(title)
        }
        return title.isEmpty ? nil : title
    }

    private static let quotes = CharacterSet(charactersIn: "\"'“”‘’「」『』«»")
    /// Trailing punctuation a title doesn't end with ("?" stays).
    private static let trailing = CharacterSet(charactersIn: ".。!！:：;；,，、…")

    /// Strips quotes and whitespace at both ends and trailing punctuation, until nothing changes.
    private static func trim(_ s: String) -> String {
        var out = s
        while true {
            var next = out.trimmingCharacters(in: quotes.union(.whitespacesAndNewlines))
            while let last = next.unicodeScalars.last, trailing.contains(last) { next.unicodeScalars.removeLast() }
            if next == out { return out }
            out = next
        }
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// `work`'s result, or nil once `seconds` pass (the work is left to finish or time out on its own).
    @MainActor private static func withDeadline(_ seconds: TimeInterval,
                                                _ work: @escaping @MainActor () async -> String?) async -> String? {
        let gate = Gate()
        return await withCheckedContinuation { continuation in
            gate.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.open() { continuation.resume(returning: nil) }
            }
            Task { @MainActor in
                let value = await work()
                gate.timer?.cancel()
                if gate.open() { continuation.resume(returning: value) }
            }
        }
    }

    @MainActor private final class Gate {
        var timer: Task<Void, Never>?
        private var used = false
        /// True only for the first caller.
        func open() -> Bool {
            defer { used = true }
            return !used
        }
    }
}
