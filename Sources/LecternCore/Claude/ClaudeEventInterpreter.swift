import Foundation

/// What a stdout line of `claude -p --output-format stream-json` means for the current turn.
public enum ClaudeStreamOutput: Sendable {
    /// Non-terminal event for the listener: .sessionReady, .thinking, .textDelta, .quota, .warning.
    case event(BackendEvent)
    /// The turn is over. The event is terminal: .completed, .interrupted or .failed.
    case turnEnded(BackendEvent)
    /// `--resume` named a session Claude Code doesn't have. It arrives as an error `result` (the same
    /// subtype as an interrupt) before any turn starts, so it is not a real turn end.
    case resumeFailed(String)
}

/// Pure translation of Claude Code's stream-json stdout into BackendEvents for one turn.
/// Create a fresh value per turn; feed it every line in order.
public struct ClaudeEventInterpreter: Sendable {
    public static let authExpiredMessage = "Your Claude login expired or was revoked. Log in again to continue."
    public static let apiKeyWarning = "Claude is billing an API key, not your subscription"

    /// Set when the user pressed Stop, so the error `result` that follows reads as `.interrupted`.
    public var interruptRequested = false
    /// Resolved model from `system/init`, e.g. "claude-haiku-4-5-20251001".
    public private(set) var model: String?
    public private(set) var sessionId: String?
    /// True once `system/init` arrived: the process accepted its flags and picked up our message.
    public private(set) var sawInit = false
    public private(set) var streamedText = ""
    /// The CLI's own wording when the turn failed for lack of a valid login (the user sees `authExpiredMessage`).
    public private(set) var authFailureDetail: String?

    private var announcedThinking = false
    private var separateNextText = false
    /// Model calls in this turn (`message_start`): more than one means tool use (a skill turn).
    private var modelCalls = 0
    /// A `system/api_retry` hit a 401. The CLI recovers from some (token refresh), so it only counts
    /// when the final result names no other status.
    private var retryAuthSignal = false
    /// The turn's own assistant message reported `authentication_failed`.
    private var assistantAuthFailure = false
    private var syntheticText: String?
    private var assistantTexts: [String] = []

    public init() {}

    public mutating func consume(line: String) -> [ClaudeStreamOutput] {
        guard let obj = JSONLine.parse(line) else { return [] }
        return consume(obj)
    }

    public mutating func consume(_ ev: JSONObject) -> [ClaudeStreamOutput] {
        switch ev.str("type") {
        case "system": return system(ev)
        case "stream_event": return streamEvent(ev.obj("event") ?? [:])
        case "assistant": assistant(ev); return []
        case "rate_limit_event":
            guard let info = ev.obj("rate_limit_info"), let q = Self.quota(from: info) else { return [] }
            return [.event(.quota(q))]
        case "result": return [result(ev)]
        default: return []   // user echoes, control_response, status, hooks…
        }
    }

    // MARK: - Line kinds

    private mutating func system(_ ev: JSONObject) -> [ClaudeStreamOutput] {
        switch ev.str("subtype") {
        case "init":
            sawInit = true
            sessionId = ev.str("session_id") ?? sessionId
            var out: [ClaudeStreamOutput] = []
            if let m = ev.str("model"), !m.isEmpty {
                model = m
                out.append(.event(.sessionReady(model: m)))
            }
            if let source = ev.str("apiKeySource"), source != "none" {
                out.append(.event(.warning(Self.apiKeyWarning)))
            }
            return out
        case "api_retry":
            if ev.int("error_status") == 401 || ev.str("error") == "authentication_failed" { retryAuthSignal = true }
            return []
        default:
            return []
        }
    }

    private mutating func streamEvent(_ e: JSONObject) -> [ClaudeStreamOutput] {
        switch e.str("type") {
        case "message_start":
            // A skill turn makes several model calls (tool use); keep their texts apart while streaming.
            modelCalls += 1
            if !streamedText.isEmpty { separateNextText = true }
            return []
        case "content_block_delta":
            let delta = e.obj("delta") ?? [:]
            switch delta.str("type") {
            case "text_delta":
                guard var t = delta.str("text"), !t.isEmpty else { return [] }
                if separateNextText {
                    separateNextText = false
                    t = "\n\n" + t
                }
                streamedText += t
                return [.event(.textDelta(t))]
            case "thinking_delta":
                return announceThinking()
            default:
                return []
            }
        case "content_block_start":
            let kind = e.obj("content_block")?.str("type")
            return kind == "thinking" || kind == "redacted_thinking" ? announceThinking() : []
        default:
            return []
        }
    }

    private mutating func announceThinking() -> [ClaudeStreamOutput] {
        // Thinking only matters before visible text starts.
        guard !announcedThinking, streamedText.isEmpty else { return [] }
        announcedThinking = true
        return [.event(.thinking)]
    }

    private mutating func assistant(_ ev: JSONObject) {
        let message = ev.obj("message") ?? [:]
        let text = message.objs("content").filter { $0.str("type") == "text" }
            .compactMap { $0.str("text") }.joined()
        if ev.str("error") == "authentication_failed" { assistantAuthFailure = true }
        if message.str("model") == "<synthetic>" {
            if !text.isEmpty { syntheticText = text }
        } else if !text.isEmpty {
            assistantTexts.append(text)
        }
    }

    private mutating func result(_ ev: JSONObject) -> ClaudeStreamOutput {
        let subtype = ev.str("subtype") ?? ""
        // `subtype` can be "success" while `is_error` is true (401), so is_error decides.
        let isError = ev.bool("is_error") ?? (subtype != "success")
        let text = ev.str("result") ?? ""
        let errors = (ev.arr("errors") ?? []).compactMap { $0 as? String }
        sessionId = ev.str("session_id") ?? sessionId

        if isError, let missing = errors.first(where: { $0.contains("No conversation found") }) {
            return .resumeFailed(missing)
        }
        guard isError else {
            // `result` is only the last model call's text; a turn with tool use keeps every call's text, as
            // streamed (an earlier one may say, for example, that the document tried to give instructions).
            var final = modelCalls > 1 && !assistantTexts.isEmpty ? assistantTexts.joined(separator: "\n\n") : text
            if final.isEmpty { final = assistantTexts.joined(separator: "\n\n") }
            if final.isEmpty { final = streamedText }
            return .turnEnded(.completed(text: final, usage: Self.usage(from: ev)))
        }

        let detail = [text, syntheticText ?? "", errors.joined(separator: "\n")].first { !$0.isEmpty } ?? ""
        let status = ev.int("api_error_status")
        if status == 401 || assistantAuthFailure {
            authFailureDetail = detail
            return .turnEnded(.failed(.authRequired(Self.authExpiredMessage)))
        }
        if interruptRequested { return .turnEnded(.interrupted) }
        // An earlier 401 retry only decides when the result reports no other HTTP status (429/500/529…).
        if retryAuthSignal, status == nil {
            authFailureDetail = detail
            return .turnEnded(.failed(.authRequired(Self.authExpiredMessage)))
        }
        if status == 429 || ClaudeProtocol.looksLikeUsageLimit(detail) {
            return .turnEnded(.failed(.usageLimit(detail.isEmpty ? "Claude usage limit reached." : detail)))
        }
        if ClaudeProtocol.looksLikeAuthFailure(detail) {
            authFailureDetail = detail
            return .turnEnded(.failed(.authRequired(Self.authExpiredMessage)))
        }
        let message = detail.isEmpty ? "Claude Code reported an error (\(subtype.isEmpty ? "unknown" : subtype))." : detail
        return .turnEnded(.failed(.api(message)))
    }

    // MARK: - Payload parsers

    /// `result.usage`. Input counts include cache reads/writes; cached = cache reads.
    static func usage(from result: JSONObject) -> TurnUsage? {
        guard let u = result.obj("usage") else {
            return result.int("duration_ms").map { TurnUsage(durationMs: $0) }
        }
        let fresh = u.int("input_tokens") ?? 0
        let written = u.int("cache_creation_input_tokens") ?? 0
        let read = u.int("cache_read_input_tokens") ?? 0
        return TurnUsage(inputTokens: fresh + written + read, cachedInputTokens: read,
                         outputTokens: u.int("output_tokens"), durationMs: result.int("duration_ms"))
    }

    /// `rate_limit_info`: `unifiedWindows.{five_hour,seven_day}.{utilization 0–1, resetsAt unix s}`, `status`.
    public static func quota(from info: JSONObject) -> QuotaSnapshot? {
        let unified = info.obj("unifiedWindows") ?? [:]
        let preferred = ["five_hour", "seven_day"]
        let keys = preferred.filter { unified[$0] != nil } + unified.keys.filter { !preferred.contains($0) }.sorted()
        var windows: [QuotaWindow] = []
        for key in keys {
            guard let w = unified.obj(key), let utilization = w.double("utilization") else { continue }
            windows.append(QuotaWindow(label: windowLabel(key),
                                       usedPercent: max(0, (utilization * 1000).rounded() / 10),
                                       resetsAt: w.double("resetsAt").map { Date(timeIntervalSince1970: $0) }))
        }
        let status = info.str("status") ?? "allowed"
        let usingOverage = info.bool("isUsingOverage") ?? false
        let exhausted = status == "rejected" || usingOverage || windows.contains { $0.usedPercent >= 100 }
        guard !windows.isEmpty || exhausted else { return nil }
        var note: String?
        if usingOverage { note = "Using extra usage beyond your plan" }
        else if status == "allowed_warning" { note = "Approaching your plan's usage limit" }
        return QuotaSnapshot(provider: .claude, windows: windows, includedUsageExhausted: exhausted, note: note)
    }

    static func windowLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case "seven_day_opus": return "Weekly (Opus)"
        case "seven_day_sonnet": return "Weekly (Sonnet)"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
