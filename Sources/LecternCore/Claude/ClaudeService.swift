import AppKit
import Foundation
import Observation

/// App-wide Claude Code integration: binary discovery, login state, model catalog, quota, sessions.
@MainActor @Observable
public final class ClaudeService: ProviderService {
    public let provider: Provider = .claude
    public private(set) var installIssue: String?
    public private(set) var authState: AuthState = .unknown
    public private(set) var models: [ModelOption] = ClaudeService.catalog
    public private(set) var quota: QuotaSnapshot?
    /// Detected/used path, for Settings.
    public private(set) var binaryPath: String?
    public private(set) var accountEmail: String?
    /// e.g. "Max".
    public private(set) var planName: String?
    /// Method of the login in progress; nil when none is running.
    public private(set) var loginMethod: LoginMethod?

    /// Bumped after every successful login. Sessions respawn when it changes, so a process still
    /// holding the old (revoked) token never serves another turn.
    @ObservationIgnored private(set) var loginGeneration = 0
    @ObservationIgnored var loginTimeout: TimeInterval = 300
    @ObservationIgnored var terminalPollInterval: TimeInterval = 3
    /// Opens the Terminal login script. Replaceable so tests don't open Terminal windows.
    @ObservationIgnored var openCommandFile: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    @ObservationIgnored private let pathOverride: @MainActor () -> String?
    @ObservationIgnored private var observers: [@MainActor (AuthState) -> Void] = []
    /// A turn got a 401. `auth status` keeps saying loggedIn for a revoked token, so it can't clear
    /// this; only a completed login or a successful verifyConnection() can.
    @ObservationIgnored private var authExpired = false
    @ObservationIgnored private var authExpiredAt = Date.distantPast
    @ObservationIgnored private var lastStatus: ClaudeAuthStatus?
    @ObservationIgnored private var statusCheck = 0
    @ObservationIgnored private var login: LoginAttempt?
    @ObservationIgnored private var loginCounter = 0
    @ObservationIgnored private var stateBeforeLogin: AuthState = .unknown

    static let catalog: [ModelOption] = {
        let efforts = ClaudeProtocol.efforts
        return [
            ModelOption(id: "", displayName: "Default (your Claude Code setting)", efforts: efforts, isDefault: true),
            ModelOption(id: "opus", displayName: "Opus", detail: "Most capable", efforts: efforts),
            ModelOption(id: "sonnet", displayName: "Sonnet", detail: "Fast and capable", efforts: efforts),
            ModelOption(id: "haiku", displayName: "Haiku", detail: "Fastest, lightest on usage", efforts: efforts),
            ModelOption(id: "fable", displayName: "Fable", efforts: efforts),
        ]
    }()

    public init(pathOverride: @escaping @MainActor () -> String?) {
        self.pathOverride = pathOverride
        locate()
        refreshAuth()
    }

    // MARK: - Binary

    /// Re-run discovery after the override changes.
    public func relocateBinary() {
        locate()
        refreshAuth()
    }

    private func locate() {
        let found = BinaryLocator.claude(override: pathOverride())
        binaryPath = found.url?.path
        installIssue = found.issue
    }

    /// Binary for the next spawn; re-runs discovery if the previous one disappeared.
    func currentBinary() -> URL? {
        if let p = binaryPath, FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        locate()
        return binaryPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - ProviderService

    public func refreshAuth() {
        guard login == nil else { return }
        Task { await self.checkStatus() }
    }

    public func markAuthExpired(_ reason: String) {
        authExpired = true
        authExpiredAt = Date()
        guard login == nil else { return }
        setAuth(.signedOut(reason: reason))
    }

    public func reloadModels() {
        models = Self.catalog
    }

    public func addAuthObserver(_ handler: @escaping @MainActor (AuthState) -> Void) {
        observers.append(handler)
    }

    public func makeSession(conversationId: String?) -> ChatSession {
        ClaudeSession(service: self, conversationId: conversationId)
    }

    /// Personal ~/.claude/skills, enabled Claude Code plugins' skills and the Claude app's synced skills,
    /// deduplicated by name in that order.
    public func listSkills() async -> [SkillInfo] {
        await Task.detached(priority: .userInitiated) { ClaudeSkills.discover() }.value
    }

    /// Tiny real call (haiku). `auth status` can say loggedIn for a revoked token; this can't.
    public func verifyConnection() async -> Bool {
        guard let bin = currentBinary() else { return false }
        let r = await ProcessRunner.run(bin, ClaudeProtocol.verifyArguments, environment: CleanEnvironment.make(),
                                        currentDirectory: AppPaths.claudeCwd, timeout: 120)
        guard let result = ClaudeProtocol.oneShotResult(r.stdout) else { return false }
        if result.bool("is_error") == false {
            if authExpired {
                authExpired = false
                loginGeneration += 1
            }
            if login == nil, !authState.isSignedIn { await checkStatus() }
            return true
        }
        let detail = result.str("result") ?? ""
        if result.int("api_error_status") == 401 || ClaudeProtocol.looksLikeAuthFailure(detail) {
            markAuthExpired(ClaudeEventInterpreter.authExpiredMessage)
        }
        return false
    }

    /// One-shot question with no tools and no saved session (conversation titles): the result text,
    /// or nil on an error, a timeout or a failed login. It never marks the login expired; a real
    /// turn reports that.
    public func oneShot(prompt: String, model: String, timeout: TimeInterval = 20) async -> String? {
        guard let bin = currentBinary() else { return nil }
        let r = await ProcessRunner.run(bin, Self.oneShotArguments(prompt: prompt, model: model),
                                        environment: CleanEnvironment.make(), currentDirectory: AppPaths.claudeCwd,
                                        timeout: timeout)
        guard !r.timedOut, let result = ClaudeProtocol.oneShotResult(r.stdout), result.bool("is_error") == false,
              let text = result.str("result")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    static func oneShotArguments(prompt: String, model: String) -> [String] {
        var args = ["-p", prompt]
        if !model.isEmpty { args += ["--model", model] }
        return args + ["--tools", "", "--safe-mode", "--no-session-persistence", "--output-format", "json"]
    }

    func updateQuota(_ snapshot: QuotaSnapshot) {
        quota = snapshot
    }

    // MARK: - Status

    /// Runs `auth status --json` and applies it unless a login started or a newer check began meanwhile.
    @discardableResult
    func checkStatus() async -> ClaudeAuthStatus? {
        guard let bin = currentBinary() else {
            setAuth(.failed(installIssue ?? "Claude Code CLI not found."))
            return nil
        }
        statusCheck += 1
        let check = statusCheck
        switch authState {
        case .unknown, .failed: setAuth(.checking)
        default: break
        }
        let (status, failure) = await Self.readStatus(bin)
        guard check == statusCheck, login == nil else { return status }
        guard let status else {
            setAuth(.failed("Couldn't check the Claude login: \(failure)"))
            return nil
        }
        lastStatus = status
        accountEmail = status.email
        planName = status.planName
        if authExpired, status.loggedIn, Self.terminalLoginSucceeded(after: authExpiredAt) {
            // The Terminal login finished after the app stopped waiting (cancel/timeout).
            try? FileManager.default.removeItem(at: Self.terminalMarkerURL)
            authExpired = false
            loginGeneration += 1
        }
        if !status.loggedIn {
            setAuth(.signedOut(reason: "Log in to Claude to use it here."))
        } else if authExpired {
            setAuth(.signedOut(reason: ClaudeEventInterpreter.authExpiredMessage))
        } else {
            setAuth(.signedIn(account: status.accountLabel))
        }
        return status
    }

    private static func readStatus(_ bin: URL) async -> (ClaudeAuthStatus?, String) {
        let r = await ProcessRunner.run(bin, ClaudeProtocol.statusArguments, environment: CleanEnvironment.make(),
                                        currentDirectory: AppPaths.claudeCwd, timeout: 20)
        if let status = ClaudeAuthStatus(json: r.stdout) { return (status, "") }
        if r.timedOut { return (nil, "`claude auth status` timed out") }
        let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, detail.isEmpty ? "unexpected output (exit \(r.status))" : String(detail.suffix(300)))
    }

    private func setAuth(_ state: AuthState) {
        guard state != authState else { return }
        authState = state
        for observer in observers { observer(state) }
    }

    // MARK: - Login (only ever from an explicit user click)

    private final class LoginAttempt {
        let id: Int
        let method: LoginMethod
        var process: ManagedProcess?
        var tasks: [Task<Void, Never>] = []
        var url: URL?
        var sawSuccess = false
        var lastLine = ""

        init(id: Int, method: LoginMethod) {
            self.id = id
            self.method = method
        }

        @MainActor func stop() {
            tasks.forEach { $0.cancel() }
            tasks = []
            if let p = process { ClaudeProcess.retire(p) }
            process = nil
        }
    }

    public func startLogin(_ method: LoginMethod) {
        if let current = login {
            current.stop()
            login = nil
        } else {
            stateBeforeLogin = authState
        }
        guard let bin = currentBinary() else {
            loginMethod = nil
            setAuth(.failed(installIssue ?? "Claude Code CLI not found."))
            return
        }
        loginCounter += 1
        let attempt = LoginAttempt(id: loginCounter, method: method == .terminal ? .terminal : .browser)
        login = attempt
        loginMethod = attempt.method
        switch method {
        case .terminal:
            startTerminalLogin(attempt, binary: bin)
        case .browser, .deviceCode:
            // Not offered in the UI: Anthropic doesn't allow third-party apps to offer Claude.ai login.
            startBrowserLogin(attempt, binary: bin)
        }
    }

    public func cancelLogin() {
        guard login != nil else { return }
        finishLogin(stateBeforeLogin)
        refreshAuth()
    }

    /// `claude auth login --claudeai` with a stdin pipe that stays open and is never written: the CLI
    /// opens the browser itself and exits 0 once the browser flow completes. Codes/tokens are never relayed.
    private func startBrowserLogin(_ attempt: LoginAttempt, binary: URL) {
        setAuth(.loggingIn(LoginProgress(message: "Opening your browser to sign in to Claude…")))
        let id = attempt.id
        let p = ManagedProcess(executable: binary, arguments: ClaudeProtocol.loginArguments,
                               environment: CleanEnvironment.make(), currentDirectory: AppPaths.claudeCwd,
                               keepStdinOpen: true)
        p.onStdoutLine = { [weak self] line in self?.loginOutput(line, attempt: id) }
        p.onExit = { [weak self] status, stderr in self?.loginExited(status: status, stderr: stderr, attempt: id) }
        do {
            try p.start()
        } catch {
            finishLogin(loginFailed("Couldn't start the Claude login: \(error.localizedDescription)"))
            return
        }
        attempt.process = p
        // ManagedProcess streams stdout only; pick the link up from stderr too in case the CLI writes it there.
        attempt.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let current = self.login, current.id == id, current.url == nil else { return }
                if let url = ClaudeLoginOutput.url(in: p.stderrTail) { self.loginFoundURL(url, attempt: id) }
            }
        })
        scheduleLoginTimeout(attempt)
    }

    private func loginOutput(_ line: String, attempt id: Int) {
        guard let attempt = login, attempt.id == id else { return }
        let text = ClaudeLoginOutput.clean(line).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { attempt.lastLine = text }
        if let url = ClaudeLoginOutput.url(in: text) { loginFoundURL(url, attempt: id) }
        if ClaudeLoginOutput.indicatesSuccess(text) { attempt.sawSuccess = true }
    }

    /// The printed link is the CLI's manual-code URL (it ends on a page with a code to paste into the
    /// CLI, which Lectern never relays), so it is not offered: Terminal login is the fallback.
    private func loginFoundURL(_ url: URL, attempt id: Int) {
        guard let attempt = login, attempt.id == id, attempt.url == nil else { return }
        attempt.url = url
        setAuth(.loggingIn(LoginProgress(
            message: "Finish signing in to Claude in the browser window that opened. If none opened, use Terminal instead.")))
    }

    private func loginExited(status: Int32, stderr: String, attempt id: Int) {
        guard let attempt = login, attempt.id == id else { return }
        attempt.process = nil
        if status == 0 || attempt.sawSuccess {
            Task { await self.loginSucceeded(attempt: id) }
            return
        }
        let stderrLine = stderr.split(separator: "\n").map { ClaudeLoginOutput.clean(String($0)) }
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let detail = stderrLine.isEmpty ? attempt.lastLine : stderrLine
        finishLogin(loginFailed(detail.isEmpty ? "Claude login didn't complete." : "Claude login didn't complete: \(detail)"))
    }

    private func loginSucceeded(attempt id: Int) async {
        guard let attempt = login, attempt.id == id else { return }
        attempt.stop()
        login = nil
        loginMethod = nil
        authExpired = false
        loginGeneration += 1
        if await checkStatus() == nil, case .failed = authState {
            // The CLI said the login worked; trust it over a status check that couldn't run.
            setAuth(.signedIn(account: accountEmail ?? "Claude"))
        }
    }

    private func finishLogin(_ state: AuthState) {
        login?.stop()
        login = nil
        loginMethod = nil
        setAuth(state)
    }

    /// A login that didn't complete leaves the stored login as it was: still signed out when it was,
    /// otherwise unknown (`.failed`, whose banner offers a status re-check before another login).
    private func loginFailed(_ message: String) -> AuthState {
        if case .signedOut = stateBeforeLogin { return .signedOut(reason: message) }
        return .failed(message)
    }

    private func scheduleLoginTimeout(_ attempt: LoginAttempt) {
        let id = attempt.id
        let seconds = loginTimeout
        attempt.tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.login?.id == id else { return }
            self.finishLogin(self.loginFailed("The Claude login timed out. Try again."))
        })
    }

    /// Opens Terminal on a script running the official `claude auth login`, then polls. `auth status`
    /// already says loggedIn for a revoked token, so it only counts when it flips from logged out;
    /// otherwise the script's exit-status marker decides.
    private func startTerminalLogin(_ attempt: LoginAttempt, binary: URL) {
        let script = AppPaths.appSupport.appendingPathComponent("login-claude.command")
        let marker = Self.terminalMarkerURL
        try? FileManager.default.removeItem(at: marker)
        do {
            try Self.terminalScript(binary: binary, marker: marker).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            finishLogin(loginFailed("Couldn't prepare the Terminal login: \(error.localizedDescription)"))
            return
        }
        setAuth(.loggingIn(LoginProgress(message: "Finish signing in in the Terminal window, then come back here.")))
        guard openCommandFile(script) else {
            finishLogin(loginFailed("Couldn't open Terminal for the Claude login."))
            return
        }
        let id = attempt.id
        let interval = terminalPollInterval
        let statusCanConfirm = lastStatus?.loggedIn == false
        attempt.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.login?.id == id else { return }
                if let code = Self.readMarker(marker) {
                    if code == 0 {
                        await self.loginSucceeded(attempt: id)
                    } else {
                        self.finishLogin(self.loginFailed("The Claude login in Terminal didn't complete (exit \(code))."))
                    }
                    return
                }
                guard statusCanConfirm, let bin = self.currentBinary() else { continue }
                let (status, _) = await Self.readStatus(bin)
                if status?.loggedIn == true, self.login?.id == id {
                    await self.loginSucceeded(attempt: id)
                    return
                }
            }
        })
        scheduleLoginTimeout(attempt)
    }

    /// The CLI runs with the same clean environment as Lectern's own spawns (plus TERM for the prompt),
    /// so the login lands where Lectern's CLI reads it, not under a CLAUDE_CONFIG_DIR or provider
    /// exported by the user's shell. No `exec`: the marker line must still run.
    static func terminalScript(binary: URL, marker: URL) -> String {
        let env = CleanEnvironment.make().sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
        return """
        #!/bin/zsh
        # Written by Lectern: runs Claude Code's official sign-in. Safe to delete.
        env -i \(env) TERM="${TERM:-xterm-256color}" \(shellQuote(binary.path)) auth login --claudeai
        code=$?
        print -r -- $code > \(shellQuote(marker.path))
        if (( code == 0 )); then
          print "\\nSigned in. You can close this window and return to Lectern."
        else
          print "\\nThe sign-in did not finish (exit $code). You can close this window."
        fi

        """
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Exit status of the last Terminal login, written by the script.
    static var terminalMarkerURL: URL { AppPaths.appSupport.appendingPathComponent("login-claude.status") }

    private static func readMarker(_ url: URL) -> Int? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func terminalLoginSucceeded(after date: Date) -> Bool {
        let url = terminalMarkerURL
        guard readMarker(url) == 0,
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        return modified > date
    }
}

enum ClaudeProcess {
    /// Terminate without listening any further, but keep the object alive until the child has exited
    /// so ManagedProcess can still escalate to SIGKILL.
    @MainActor static func retire(_ p: ManagedProcess) {
        p.onStdoutLine = nil
        guard p.isRunning else { p.onExit = nil; return }
        p.onExit = { _, _ in p.onExit = nil }
        p.terminate()
    }
}
