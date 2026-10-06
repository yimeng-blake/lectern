import Foundation

// MARK: - Paths

/// App-owned directories under ~/Library/Application Support/Lectern. Created on first access.
public enum AppPaths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Lectern", isDirectory: true))
    }

    /// Fixed, empty, non-git working directory for `claude -p` (sessions resume per-cwd).
    public static var claudeCwd: URL { ensure(appSupport.appendingPathComponent("claude-cwd", isDirectory: true)) }
    /// Fixed working directory for Codex threads.
    public static var codexCwd: URL { ensure(appSupport.appendingPathComponent("codex-cwd", isDirectory: true)) }
    /// Isolated CODEX_HOME: our own config.toml (no plugins, no notify hook, standard tier) and its own login.
    public static var codexHome: URL { ensure(appSupport.appendingPathComponent("codex-home", isDirectory: true)) }
    /// Rendered page images and other disposable files.
    public static var cache: URL { ensure(appSupport.appendingPathComponent("cache", isDirectory: true)) }
    /// Per-document conversation state (session ids, transcripts).
    public static var sessions: URL { ensure(appSupport.appendingPathComponent("sessions", isDirectory: true)) }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Environment

/// Children never inherit the app's environment. An inherited ANTHROPIC_API_KEY would silently bill
/// the API instead of the subscription, and when developing inside Claude Desktop the parent carries
/// CLAUDECODE / CLAUDE_CODE_* / ANTHROPIC_BASE_URL variables that must not reach the child.
public enum CleanEnvironment {
    public static func make(extra: [String: String] = [:]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": parent["USER"] ?? NSUserName(),
            "LOGNAME": parent["LOGNAME"] ?? NSUserName(),
            "SHELL": parent["SHELL"] ?? "/bin/zsh",
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": parent["TMPDIR"] ?? NSTemporaryDirectory(),
            // What a Finder-launched app gets; enough for `open`, `security`, etc.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }
}

// MARK: - Binary discovery

public enum BinaryLocator {
    /// Claude Code native binary. `override` comes from Settings.
    public static func claude(override: String?) -> (url: URL?, issue: String?) {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { candidates.append(expand(o)) }
        candidates += [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        // Older npm installs of Claude Code are a Node script, which can't run under a GUI app's PATH.
        // Remembered so the message says why the `claude` the user has (maybe their override) was skipped.
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
            return (nil, "The Claude Code CLI at \(shown) is a Node.js script (an older npm install), which Lectern can't run. In Terminal, run `claude install` to switch to the native build, then reopen Lectern.")
        }
        return (nil, "Claude Code CLI not found. Install it (\(claudeInstallGuide)) or set its path in Settings > Advanced.")
    }

    /// Where the "not found" message sends people; README.md links the same page.
    public static let claudeInstallGuide = "https://code.claude.com/docs/en/setup"

    /// Codex native binary. Prefers the copy bundled in ChatGPT.app: it is auto-updated, and the
    /// Codex server rejects current models from stale clients. npm's `codex` is a Node script that
    /// fails under a GUI app's PATH, so only the native binary inside the npm package is accepted.
    public static func codex(override: String?) -> (url: URL?, issue: String?) {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { candidates.append(expand(o)) }
        candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        candidates.append("\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        candidates += npmNativeCodexPaths()
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if requiresNode(path) { continue }
            return (URL(fileURLWithPath: path), nil)
        }
        return (nil, "Codex not found. Install the ChatGPT desktop app, or `npm i -g @openai/codex` and set the native binary path in Settings > Advanced.")
    }

    /// Native binaries shipped inside global npm installs of @openai/codex (nvm or Homebrew node).
    static func npmNativeCodexPaths() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var roots: [String] = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"]
        if let versions = try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            roots += versions.sorted(by: >).map { "\(home)/.nvm/versions/node/\($0)/lib/node_modules" }
        }
        var out: [String] = []
        for root in roots {
            let pkgDir = "\(root)/@openai/codex/node_modules/@openai"
            guard let platforms = try? fm.contentsOfDirectory(atPath: pkgDir) else { continue }
            for p in platforms where p.hasPrefix("codex-darwin") {
                let vendor = "\(pkgDir)/\(p)/vendor"
                guard let triples = try? fm.contentsOfDirectory(atPath: vendor) else { continue }
                for t in triples {
                    out.append("\(vendor)/\(t)/codex/codex")
                    out.append("\(vendor)/\(t)/bin/codex")
                }
            }
        }
        return out
    }

    /// True for `#!/usr/bin/env node` style launchers.
    static func requiresNode(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 128)) ?? Data()
        guard head.starts(with: [0x23, 0x21]) else { return false } // "#!"
        let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first ?? ""
        return line.contains("node")
    }

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
}

// MARK: - Long-lived child process with line-based stdout

/// Wraps Foundation.Process for JSONL protocols. Output callbacks are delivered on the main actor,
/// one complete line at a time, in order.
public final class ManagedProcess: @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]

    /// Called for every complete stdout line (without the trailing newline).
    public var onStdoutLine: (@MainActor (String) -> Void)?
    /// Called once when the process exits: (exit status, last ~4 KB of stderr).
    public var onExit: (@MainActor (Int32, String) -> Void)?

    private let process = Process()
    private let stdinPipe: Pipe?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    /// Separate from `lock` so a write blocked on a full pipe never stalls stdout/stderr handling.
    private let writeLock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdinClosed = false

    /// - Parameter keepStdinOpen: true for stream protocols (we write JSON lines); false wires stdin
    ///   to /dev/null, which one-shot `claude -p` / `codex exec` need (an open, idle pipe makes
    ///   `claude -p` wait 3 s and `codex exec` block forever).
    public init(executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL, keepStdinOpen: Bool) {
        self.executable = executable
        self.arguments = arguments
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        if keepStdinOpen {
            let p = Pipe()
            // A write racing the child's exit must fail with EPIPE, not kill the app with SIGPIPE.
            _ = fcntl(p.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            stdinPipe = p
            process.standardInput = p
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public var isRunning: Bool { process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    public var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    public func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if chunk.isEmpty {
                h.readabilityHandler = nil
                self.markFinished(stdoutEOF: true)
                return
            }
            self.consumeStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > 4096 { self.stderrBuffer = self.stderrBuffer.suffix(4096) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.markFinished(stdoutEOF: false)
            // Grandchildren can keep stdout open after the main process exits; don't wait forever for EOF.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.markFinished(stdoutEOF: true)
            }
        }
        try process.run()
    }

    private var sawEOF = false
    private var sawExit = false
    private var exitReported = false

    /// onExit fires once, after both process exit and stdout EOF, so every stdout line is delivered first.
    private func markFinished(stdoutEOF: Bool) {
        lock.lock()
        if stdoutEOF { sawEOF = true } else { sawExit = true }
        guard sawEOF, sawExit, !exitReported else { lock.unlock(); return }
        exitReported = true
        let tailLine = stdoutBuffer
        stdoutBuffer = Data()
        let stderr = String(decoding: stderrBuffer, as: UTF8.self)
        lock.unlock()
        let status = process.terminationStatus
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !tailLine.isEmpty { self.onStdoutLine?(String(decoding: tailLine, as: UTF8.self)) }
                self.onExit?(status, stderr)
            }
        }
    }

    private func consumeStdout(_ chunk: Data) {
        var lines: [String] = []
        lock.lock()
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
        }
        lock.unlock()
        guard !lines.isEmpty else { return }
        let complete = lines
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for l in complete { self.onStdoutLine?(l) }
            }
        }
    }

    /// Write one line (a newline is appended). Safe to call from any thread; may block until the
    /// child reads, so call it off the main thread.
    public func write(line: String) {
        guard let p = stdinPipe else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        guard !stdinClosed, process.isRunning else { return }
        var data = Data(line.utf8)
        data.append(0x0A)
        do { try p.fileHandleForWriting.write(contentsOf: data) } catch { /* process gone; onExit will report */ }
    }

    public func closeStdin() {
        guard let p = stdinPipe else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? p.fileHandleForWriting.close()
    }

    /// SIGTERM, then SIGKILL after `grace` seconds if still running. Signals go out before stdin is
    /// closed: a write stuck on a hung child then fails as the child dies instead of blocking the caller.
    public func terminate(grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
        closeStdin()
    }
}

// MARK: - One-shot commands

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum ProcessRunner {
    /// Run a short command with stdin at /dev/null and a clean environment.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.environment = environment ?? CleanEnvironment.make()
            if let currentDirectory { p.currentDirectoryURL = currentDirectory }
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let outBox = DataBox(), errBox = DataBox()
            let timedOut = FlagBox()
            let group = DispatchGroup()
            group.enter(); group.enter(); group.enter()
            p.terminationHandler = { _ in group.leave() }
            do {
                try p.run()
            } catch {
                cont.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                return
            }
            DispatchQueue.global().async { outBox.append(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            DispatchQueue.global().async { errBox.append(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { _ = timedOut.setOnce(); p.terminate() }
            }
            group.notify(queue: .global()) {
                cont.resume(returning: CommandResult(status: p.terminationStatus, stdout: outBox.string,
                                                     stderr: errBox.string, timedOut: timedOut.value))
            }
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    /// Returns true the first time only.
    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if flag { return false }; flag = true; return true }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

// MARK: - JSON helpers

public typealias JSONObject = [String: Any]

public enum JSONLine {
    public static func parse(_ line: String) -> JSONObject? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { return nil }
        return obj
    }

    /// Single-line JSON (no pretty printing, no escaped slashes).
    public static func encode(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { (self[k] as? NSNumber)?.boolValue }
    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func objs(_ k: String) -> [JSONObject] { (self[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
}
