import Foundation

/// Command lines and stdin messages for Claude Code (`claude -p` stream-json), plus parsers for its
/// one-shot outputs. Everything here is pure so it can be checked against recorded CLI traffic.
enum ClaudeProtocol {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Long-lived per-conversation process. Never `--bare`: it ignores the subscription login.
    /// `--safe-mode` keeps OAuth but skips the user's CLAUDE.md, plugins, hooks and MCP servers.
    static func sessionArguments(model: String, effort: String, sessionId: String, resume: Bool) -> [String] {
        var args = [
            "-p", "--verbose",
            "--input-format", "stream-json", "--output-format", "stream-json",
            "--include-partial-messages",
            "--safe-mode", "--tools", "", "--strict-mcp-config",
            "--permission-mode", "dontAsk",
            "--system-prompt", ReaderPrompt.system,
        ]
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        args += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        return args
    }

    static let statusArguments = ["auth", "status", "--json"]
    static let loginArguments = ["auth", "login", "--claudeai"]
    static let verifyArguments = ["-p", "Reply with OK", "--model", "haiku", "--tools", "", "--safe-mode",
                                  "--no-session-persistence", "--output-format", "json"]

    static func newSessionId() -> String { UUID().uuidString.lowercased() }

    static func isValidSessionId(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// One stdin user message: image blocks first, then the text. Unreadable images are skipped and counted.
    static func userMessageLine(text: String, imagePNGs: [URL]) -> (line: String, missingImages: Int) {
        var content: [JSONObject] = []
        var missing = 0
        for url in imagePNGs {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { missing += 1; continue }
            let ext = url.pathExtension.lowercased()
            let mediaType = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/png"
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        let message: JSONObject = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
            "session_id": "",
        ]
        return (JSONLine.encode(message), missing)
    }

    /// Stops the running turn; the process stays alive for the next one.
    static func interruptLine(requestId: String = UUID().uuidString.lowercased()) -> String {
        JSONLine.encode(["type": "control_request", "request_id": requestId, "request": ["subtype": "interrupt"]])
    }

    /// `claude -p … --output-format json` prints one result object (some versions print an array of events).
    static func oneShotResult(_ stdout: String) -> JSONObject? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return trimmed.split(separator: "\n").reversed().lazy
                .compactMap { JSONLine.parse(String($0)) }.first { $0.str("type") == "result" }
        }
        if let obj = parsed as? JSONObject { return obj }
        if let arr = parsed as? [Any] {
            return arr.compactMap { $0 as? JSONObject }.last { $0.str("type") == "result" }
        }
        return nil
    }

    /// Error text that means "not signed in / login revoked".
    static func looksLikeAuthFailure(_ text: String) -> Bool {
        text.range(of: #"authenticat|log ?in"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeUsageLimit(_ text: String) -> Bool {
        text.range(of: #"usage limit|hit your limit|limit reached|rate limit"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// `claude auth status --json`. It can report loggedIn while the token is revoked; a 401 during a turn wins.
struct ClaudeAuthStatus: Equatable, Sendable {
    var loggedIn: Bool
    var authMethod: String?
    var email: String?
    var orgName: String?
    var subscriptionType: String?

    init(loggedIn: Bool, authMethod: String? = nil, email: String? = nil, orgName: String? = nil,
         subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    init?(json stdout: String) {
        guard let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}"), start < end,
              let obj = JSONLine.parse(String(stdout[start...end])),
              let loggedIn = obj.bool("loggedIn") else { return nil }
        self.init(loggedIn: loggedIn, authMethod: obj.str("authMethod"), email: obj.str("email"),
                  orgName: obj.str("orgName"), subscriptionType: obj.str("subscriptionType"))
    }

    /// "Max", "Pro", …; "API" for non-subscription (Console) logins, which bill the API rather than a plan.
    var planName: String? {
        if let sub = subscriptionType, !sub.isEmpty { return sub.prefix(1).uppercased() + sub.dropFirst() }
        if let method = authMethod, method != "claude.ai", method != "none" { return "API" }
        return nil
    }

    var accountLabel: String {
        let who = email ?? orgName ?? "Claude Code"
        guard let plan = planName else { return who }
        return "\(who) · \(plan)"
    }
}

/// Output of `claude auth login --claudeai`: "If the browser didn't open, visit: <url>",
/// "Paste code here if prompted >", "Login successful.".
enum ClaudeLoginOutput {
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// The sign-in page from the "visit: <url>" line.
    static func url(in text: String) -> URL? {
        let text = clean(text)
        guard let visit = text.range(of: "visit:", options: .caseInsensitive) else { return nil }
        let rest = text[visit.upperBound...]
        guard let r = rest.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        var s = String(rest[r])
        while let last = s.last, ".,;)".contains(last) { s.removeLast() }
        return URL(string: s)
    }

    static func indicatesSuccess(_ text: String) -> Bool {
        clean(text).range(of: "Login successful", options: .caseInsensitive) != nil
    }
}
