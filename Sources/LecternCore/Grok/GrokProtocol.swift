import Foundation

// Grok runs through xAI's official Grok Build CLI (`grok`), one headless process per turn:
// `grok --prompt-file turn.json --output-format streaming-json …`, with `-s <uuid>` for a new
// conversation and `-r <uuid>` afterwards. Everything here is pure so it can be checked offline
// (lectern-probe grok-selftest / grok-replay). Verified against grok 1.0.46.

public enum GrokProtocol {
    public static let efforts = ["low", "medium", "high"]
    /// Shown before `grok models` has listed this account's models.
    static let fallbackModels = ["grok-4.7"]

    public static let signInPrompt = "Sign in to Grok to use it here."
    public static let authExpiredMessage = "Your Grok sign-in expired or was signed out. Sign in again to continue."
    public static let notFoundMessage = "Grok isn't installed yet. Install it from Lectern (it runs xAI's official installer), or set its path in Settings > Advanced."

    /// Fixed, empty working directory: no AGENTS.md / CLAUDE.md / .grok config can be picked up from it.
    public static var workingDirectory: URL { AppPaths.ensure(AppPaths.appSupport.appendingPathComponent("grok-cwd", isDirectory: true)) }
    /// Per-turn prompt files (document text and page images); deleted when the turn ends.
    static var promptDirectory: URL { AppPaths.ensure(AppPaths.cache.appendingPathComponent("grok-turns", isDirectory: true)) }

    /// Built-in tools removed on top of the allowlist below (`--disallowed-tools` wins over `--tools`).
    static let removedTools = ["todo_write", "run_terminal_cmd", "read_file", "list_dir", "grep", "search_replace",
                               "write_file", "web_search", "web_fetch", "task", "Agent"]

    /// One headless turn. Grok auto-approves read_file/list_dir/grep/web_search in every permission mode, so
    /// tools are removed (allowlist of one tool that is also denylisted = none) and every call is denied
    /// (`--deny *`), web search and subagents are off, and the reader prompt replaces Grok's coding prompt.
    public static func turnArguments(promptFile: URL, model: String, effort: String, sessionId: String,
                                     resume: Bool, cwd: URL) -> [String] {
        var args = [
            "--prompt-file", promptFile.path, "--output-format", "streaming-json", "--verbatim",
            "--system-prompt-override", ReaderPrompt.system,
            "--tools", "todo_write", "--disallowed-tools", removedTools.joined(separator: ","),
            "--deny", "*", "--permission-mode", "dontAsk",
            "--disable-web-search", "--no-subagents", "--no-plan", "--max-turns", "3",
            "--no-auto-update", "--cwd", cwd.path,
        ]
        if !model.isEmpty { args += ["-m", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        return args + (resume ? ["-r", sessionId] : ["-s", sessionId])
    }

    static let statusArguments = ["models"]
    static func loginArguments(deviceCode: Bool) -> [String] { ["login", deviceCode ? "--device-auth" : "--oauth"] }

    /// Settings no command-line flag covers: Claude/Cursor compatibility (their CLAUDE.md, rules, skills, hooks
    /// and MCP servers), memory, subagents, server-side tools, auto-update and session-trace upload (traces
    /// would carry document text, and uploading them can hold the process ~150 s after the answer).
    static let lockdown: [String: String] = {
        var env = ["GROK_MEMORY": "0", "GROK_SUBAGENTS": "0", "GROK_DISABLE_AUTOUPDATER": "1",
                   "GROK_TELEMETRY_TRACE_UPLOAD": "0", "GROK_BACKEND_SEARCH": "0", "GROK_WEB_FETCH": "0",
                   "GROK_WRITE_FILE": "0", "GROK_ASK_USER_QUESTION": "0"]
        for vendor in ["CLAUDE", "CURSOR"] {
            for surface in ["AGENTS", "RULES", "SKILLS", "HOOKS", "MCPS"] { env["GROK_\(vendor)_\(surface)_ENABLED"] = "0" }
        }
        return env
    }()

    /// Clean environment (no XAI_API_KEY: turns use the signed-in account) plus `extra`, then the lock-down.
    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        CleanEnvironment.make(extra: extra).merging(lockdown) { _, locked in locked }
    }

    /// The turn's ACP content blocks (`--prompt-file` parses a `.json` file as blocks): page images, then the text.
    /// Owner-only permissions. Returns how many images couldn't be read.
    static func writePrompt(text: String, imagePNGs: [URL], to url: URL) throws -> Int {
        var blocks: [JSONObject] = []
        var missing = 0
        for image in imagePNGs {
            guard let data = try? Data(contentsOf: image), !data.isEmpty else { missing += 1; continue }
            let ext = image.pathExtension.lowercased()
            blocks.append(["type": "image", "mimeType": ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png",
                           "data": data.base64EncodedString()])
        }
        blocks.append(["type": "text", "text": text])
        let data = try JSONSerialization.data(withJSONObject: blocks, options: [.withoutEscapingSlashes])
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: url)
        return missing
    }

    // MARK: - Models

    static func catalog(listed: [String], defaultModel: String?) -> [ModelOption] {
        let ids = listed.isEmpty ? fallbackModels : listed
        let defaultName = defaultModel.map { "Default (\(displayName($0)))" } ?? "Default"
        return [ModelOption(id: "", displayName: defaultName, efforts: efforts, isDefault: true)]
            + ids.map { ModelOption(id: $0, displayName: displayName($0), efforts: efforts) }
    }

    /// "grok-4.6" → "Grok 4.6", "grok-4-fast" → "Grok 4 Fast".
    static func displayName(_ id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Errors

    public enum Failure: Equatable, Sendable {
        /// `-s <id>`: the session already exists (an earlier process created it).
        case sessionInUse
        /// `-r <id>`: no such session.
        case sessionMissing
        case error(BackendError)
    }

    /// Classifies a CLI error message ("Not signed in…", "You've hit the rate limit for your plan.", …).
    public static func classify(_ raw: String) -> Failure {
        let message = raw.replacingOccurrences(of: #"^(Error|error):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ pattern: String) -> Bool {
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if has(#"session id .* is already in use"#) { return .sessionInUse }
        if has(#"no session found with id|session not found"#) { return .sessionMissing }
        if has(#"not signed in|not authenticated"#) { return .error(.authRequired(signInPrompt)) }
        if has(#"authentication (required|failed)|unauthori[sz]ed|\b401\b|(token|credentials?) (expired|revoked|invalid)"#) {
            return .error(.authRequired(authExpiredMessage))
        }
        if has(#"rate limit|usage limit|out of credits|payment required|\b402\b|\b429\b|too many requests|subscription required"#) {
            return .error(.usageLimit(message))
        }
        if has(#"grok login|sign in again"#) { return .error(.authRequired(authExpiredMessage)) }
        if has(#"unexpected argument|unrecognized|invalid value .* for '--"#) {
            return .error(.notInstalled("This version of the Grok CLI doesn't work with Lectern (\(message.prefix(160))). Update Grok and try again."))
        }
        return .error(.api(message.isEmpty ? "Grok reported an error." : String(message.prefix(800))))
    }

    /// The CLI's own "Error: …" text at the end of stderr, if any (log lines are off in headless mode).
    static func stderrError(_ stderr: String) -> String? {
        let clean = GrokLoginOutput.clean(stderr)
        guard let r = clean.range(of: #"(?m)^(Error|error): "#, options: [.regularExpression, .backwards]) else { return nil }
        let text = clean[r.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(800))
    }
}

// MARK: - `grok models` (status without a model call)

/// `grok models`: "You are logged in with …" / "You are not authenticated.", "Default model: X", then
/// "Available models:" with "  * grok-4.6 (default)" / "  - grok-4.5" lines.
public struct GrokStatus: Equatable, Sendable {
    public var signedIn: Bool?
    public var account: String?
    public var defaultModel: String?
    public var models: [String]

    public init?(output: String) {
        var signedIn: Bool?, account: String?, defaultModel: String?, models: [String] = [], inList = false
        for raw in GrokLoginOutput.clean(output).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("You are not authenticated") {
                signedIn = false
            } else if line.hasPrefix("You are logged in with ") {
                signedIn = true
                let who = line.dropFirst("You are logged in with ".count).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                account = who.isEmpty ? nil : who
            } else if line.hasPrefix("You are using XAI_API_KEY") || line.hasPrefix("You are authenticated via") {
                signedIn = true
                account = account ?? "API key"
            } else if line.hasPrefix("Default model:") {
                defaultModel = line.dropFirst("Default model:".count).split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("Available models:") {
                inList = true
            } else if inList, let r = line.range(of: #"^[*-]\s+\S+"#, options: .regularExpression) {
                models.append(String(line[r].dropFirst().trimmingCharacters(in: .whitespaces)))
            }
        }
        guard signedIn != nil || !models.isEmpty else { return nil }
        self.signedIn = signedIn
        self.account = account
        self.defaultModel = defaultModel
        self.models = models
    }
}

// MARK: - `grok login` output (stderr)

/// OAuth: "Open this URL to sign in:\n  https://auth.x.ai/oauth2/authorize?…". Device code: "To sign in, open this
/// URL in your browser:\n  https://accounts.x.ai/oauth2/device…" … "Confirm this code in your browser:\n  ABCD-1234".
public enum GrokLoginOutput {
    public static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// First sign-in link on an xAI host (anything else is ignored, so the app never offers a foreign link).
    public static func url(in text: String) -> URL? {
        let clean = clean(text)
        var search = clean.startIndex..<clean.endIndex
        while let r = clean.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression, range: search) {
            search = r.upperBound..<clean.endIndex
            var s = String(clean[r])
            while let last = s.last, ".,;)".contains(last) { s.removeLast() }
            guard let url = URL(string: s), let host = url.host?.lowercased() else { continue }
            if ["x.ai", "grok.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return nil
    }

    /// The device code: the first line after "…this code…" shaped like "ABCD-1234".
    public static func userCode(in text: String) -> String? {
        var afterPrompt = false
        for raw in clean(text).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: "code", options: .caseInsensitive) != nil, line.hasSuffix(":") { afterPrompt = true; continue }
            if afterPrompt, line.range(of: #"^[A-Z0-9]{3,}(-[A-Z0-9]{3,})*$"#, options: .regularExpression) != nil { return line }
        }
        return nil
    }

    /// Last meaningful line (skips timestamped log lines), for a failed sign-in.
    static func lastLine(in text: String) -> String? {
        clean(text).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) == nil }
    }
}

// MARK: - Binary discovery

extension BinaryLocator {
    /// Grok CLI native binary: the official installer's ~/.grok/bin, common bin dirs, then npm's native copy.
    /// npm's `bin/grok` can be a Node launcher, which can't run under a GUI app's PATH.
    public static func grok(override: String?) -> (url: URL?, issue: String?) {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { candidates.append(expand(o)) }
        candidates += ["\(home)/.grok/bin/grok", "\(home)/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        var roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules", "\(home)/.npm-global/lib/node_modules"]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            roots += versions.sorted(by: >).map { "\(home)/.nvm/versions/node/\($0)/lib/node_modules" }
        }
        candidates += roots.map { "\($0)/@xai-official/grok/bin/grok-native" }
        var nodeLauncher: String?
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if requiresNode(path) {
                if nodeLauncher == nil { nodeLauncher = path }
                continue
            }
            return (URL(fileURLWithPath: path), nil)
        }
        if let nodeLauncher {
            let shown = (nodeLauncher as NSString).abbreviatingWithTildeInPath
            return (nil, "The Grok CLI at \(shown) is a Node.js launcher, which Lectern can't run. Install Grok from Lectern (xAI's official installer), or set the native binary's path in Settings > Advanced.")
        }
        return (nil, GrokProtocol.notFoundMessage)
    }
}

// MARK: - streaming-json → BackendEvents

/// What a stdout line of `grok … --output-format streaming-json` means for the current turn.
public enum GrokStreamOutput: Sendable {
    /// Non-terminal: .sessionReady, .thinking, .textDelta, .warning.
    case event(BackendEvent)
    /// Terminal: .completed, .interrupted or .failed.
    case turnEnded(BackendEvent)
    /// `-s <id>` named an existing session: rerun the turn with `-r`.
    case sessionInUse(String)
    /// `-r <id>` named a session Grok doesn't have: start a new conversation.
    case sessionMissing(String)
}

/// Pure translation of one turn's NDJSON (`text`, `thought`, `tool_call`, `usage`, `end`, `error`; `end` is
/// last) plus the process exit into events. One value per turn; at most one terminal output.
public struct GrokStreamInterpreter: Sendable {
    /// Set when the user pressed Stop (the process is terminated), so the exit reads as `.interrupted`.
    public var interruptRequested = false
    public private(set) var streamedText = ""
    /// From `end`.
    public private(set) var sessionId: String?
    public private(set) var model: String?
    /// The CLI started the turn (any line other than an error), so the session exists from now on.
    public private(set) var sawOutput = false
    public private(set) var ended = false
    private var announcedThinking = false

    public init() {}

    public mutating func consume(line: String) -> [GrokStreamOutput] {
        guard !ended, let obj = JSONLine.parse(line) else { return [] }
        let type = obj.str("type")
        if type != "error" { sawOutput = true }
        switch type {
        case "text":
            guard let t = obj.str("data"), !t.isEmpty else { return [] }
            streamedText += t
            return [.event(.textDelta(t))]
        case "thought":
            guard !announcedThinking, streamedText.isEmpty else { return [] }
            announcedThinking = true
            return [.event(.thinking)]
        case "end":
            return end(obj)
        case "error":
            return [fail(obj.str("message") ?? "")]
        default:
            return []   // tool_call (always denied), usage, plan, available_commands, auto_compact_*…
        }
    }

    /// The process exited. Terminal output unless the stream already ended the turn.
    public mutating func processExited(status: Int32, stderr: String) -> GrokStreamOutput? {
        guard !ended else { return nil }
        if interruptRequested { ended = true; return .turnEnded(.interrupted) }
        if let message = GrokProtocol.stderrError(stderr) { return fail(message) }
        ended = true
        if status == 0, !streamedText.isEmpty { return .turnEnded(.completed(text: streamedText, usage: nil)) }
        let tail = GrokLoginOutput.clean(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .turnEnded(.failed(.processExited(tail.isEmpty ? "Grok stopped unexpectedly (exit \(status))."
                                                             : String(tail.suffix(600)))))
    }

    private mutating func end(_ obj: JSONObject) -> [GrokStreamOutput] {
        ended = true
        sessionId = obj.str("sessionId") ?? sessionId
        var out: [GrokStreamOutput] = []
        // modelUsage is keyed by model id; the main model is the one that wrote the most.
        let usage = obj.obj("modelUsage") ?? [:]
        if let m = usage.keys.max(by: { (usage.obj($0)?.int("outputTokens") ?? 0) < (usage.obj($1)?.int("outputTokens") ?? 0) }) {
            model = m
            out.append(.event(.sessionReady(model: m)))
        }
        let stop = obj.str("stopReason") ?? "end_turn"
        if stop == "cancelled" || (interruptRequested && streamedText.isEmpty) { return out + [.turnEnded(.interrupted)] }
        if streamedText.isEmpty, stop == "refusal" { return out + [.turnEnded(.failed(.api("Grok declined to answer this.")))] }
        if streamedText.isEmpty { return out + [.turnEnded(.failed(.api("Grok stopped without answering (\(stop)). Try asking again.")))] }
        if stop == "max_tokens" { out.append(.event(.warning("Grok's answer reached its length limit and may be cut off."))) }
        return out + [.turnEnded(.completed(text: streamedText, usage: Self.usage(obj)))]
    }

    private mutating func fail(_ message: String) -> GrokStreamOutput {
        ended = true
        if interruptRequested { return .turnEnded(.interrupted) }
        switch GrokProtocol.classify(message) {
        case .sessionInUse: return .sessionInUse(message)
        case .sessionMissing: return .sessionMissing(message)
        case .error(let error): return .turnEnded(.failed(error))
        }
    }

    /// `end.usage`: `input_tokens` is uncached only; TurnUsage counts the full prompt.
    static func usage(_ end: JSONObject) -> TurnUsage? {
        guard let u = end.obj("usage") else { return nil }
        let read = u.int("cache_read_input_tokens") ?? 0
        let full = (u.int("input_tokens") ?? 0) + read + (u.int("cache_creation_input_tokens") ?? 0)
        return TurnUsage(inputTokens: full, cachedInputTokens: read, outputTokens: u.int("output_tokens"))
    }
}
