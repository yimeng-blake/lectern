import Foundation
import Observation

/// App-wide Grok integration through xAI's official Grok CLI: binary discovery and one-click install,
/// sign-in state (`grok models`), in-app sign-in (`grok login`), model catalog, sessions.
@MainActor @Observable
public final class GrokService: ProviderService {
    public let provider: Provider = .grok
    public private(set) var installIssue: String?
    public private(set) var authState: AuthState = .unknown
    public private(set) var models: [ModelOption] = GrokProtocol.catalog(listed: [], defaultModel: nil)
    /// The CLI reports no plan usage windows; a usage-limit error arrives as `.usageLimit` on the turn.
    public private(set) var quota: QuotaSnapshot?
    /// Detected/used path, for Settings.
    public private(set) var binaryPath: String?
    public private(set) var setupState: SetupState = .idle
    /// As `grok models` names the login, e.g. an email; nil when signed out.
    public private(set) var accountLabel: String?
    /// Method of the sign-in in progress; nil when none is running.
    public private(set) var loginMethod: LoginMethod?
    /// Added to every grok process's environment before Lectern's lock-down. lectern-probe points GROK_HOME at a
    /// scratch install; the app leaves it empty.
    @ObservationIgnored public var extraEnvironment: [String: String] = [:]

    @ObservationIgnored var loginTimeout: TimeInterval = 600
    @ObservationIgnored private let pathOverride: @MainActor () -> String?
    @ObservationIgnored private var observers: [@MainActor (AuthState) -> Void] = []
    /// A turn was refused for auth. `grok models` only says credentials exist, so it can't clear this;
    /// a completed sign-in or a successful turn can.
    @ObservationIgnored private var authExpired = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var statusCheck = 0
    @ObservationIgnored private var login: LoginAttempt?
    @ObservationIgnored private var loginCounter = 0
    @ObservationIgnored private var stateBeforeLogin: AuthState = .unknown

    public init(pathOverride: @escaping @MainActor () -> String?) {
        self.pathOverride = pathOverride
        locate()
        refreshAuth()
    }

    // MARK: - Binary and install

    /// Re-run discovery (after the path override changed or an install).
    public func relocateBinary() {
        locate()
        refreshAuth()
    }

    private func locate() {
        let found = BinaryLocator.grok(override: pathOverride())
        binaryPath = found.url?.path
        installIssue = found.issue
    }

    func currentBinary() -> URL? {
        if let p = binaryPath, FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        locate()
        return binaryPath.map { URL(fileURLWithPath: $0) }
    }

    /// xAI's official installer (`curl -fsSL https://x.ai/cli/install.sh | bash`), only from an explicit click.
    public func install() async {
        if case .running = setupState { return }
        setupState = .running("Installing Grok…")
        let result = await OfficialInstaller.run(OfficialInstaller.grokCommand, environment: [:])
        relocateBinary()
        switch result {
        case .success:
            setupState = installIssue.map { .failed("Grok was installed, but Lectern can't find it. \($0)") } ?? .done
        case .failure(let error):
            setupState = .failed(error.message)
        }
    }

    var environment: [String: String] { GrokProtocol.environment(extra: extraEnvironment) }

    // MARK: - ProviderService

    public func refreshAuth() {
        guard login == nil else { return }
        scheduleStatusCheck()
    }

    public func reloadModels() {
        scheduleStatusCheck()
    }

    public func markAuthExpired(_ reason: String) {
        // "Not signed in" is what `grok models` reports too; only a refused login must outlive its next check.
        if reason != GrokProtocol.signInPrompt { authExpired = true }
        guard login == nil else { return }
        setAuth(.signedOut(reason: reason))
    }

    public func addAuthObserver(_ handler: @escaping @MainActor (AuthState) -> Void) {
        observers.append(handler)
    }

    public func makeSession(conversationId: String?) -> ChatSession {
        GrokSession(service: self, conversationId: conversationId)
    }

    /// A turn completed, so the login works whatever an earlier failure said.
    func turnSucceeded() {
        guard authExpired else { return }
        authExpired = false
        if login == nil { scheduleStatusCheck() }
    }

    // MARK: - Status (`grok models`: sign-in state and this account's models, no model call)

    private func scheduleStatusCheck() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            await self?.checkStatus()
            self?.statusTask = nil
        }
    }

    @discardableResult
    func checkStatus() async -> GrokStatus? {
        guard let bin = currentBinary() else {
            accountLabel = nil
            setAuth(.failed(installIssue ?? GrokProtocol.notFoundMessage))
            return nil
        }
        statusCheck += 1
        let check = statusCheck
        switch authState {
        case .unknown, .failed: setAuth(.checking)
        default: break
        }
        let r = await ProcessRunner.run(bin, GrokProtocol.statusArguments, environment: environment,
                                        currentDirectory: GrokProtocol.workingDirectory, timeout: 30)
        let status = GrokStatus(output: r.stdout + "\n" + r.stderr)
        guard check == statusCheck else { return status }
        if let status { models = GrokProtocol.catalog(listed: status.models, defaultModel: status.defaultModel) }
        guard login == nil else { return status }
        guard let status, let signedIn = status.signedIn else {
            let detail = r.timedOut ? "`grok models` timed out"
                : GrokLoginOutput.lastLine(in: r.stderr) ?? "unexpected output (exit \(r.status))"
            setAuth(.failed("Couldn't check the Grok sign-in: \(detail)"))
            return nil
        }
        accountLabel = signedIn ? status.account : nil
        if !signedIn {
            setAuth(.signedOut(reason: GrokProtocol.signInPrompt))
        } else if authExpired {
            setAuth(.signedOut(reason: GrokProtocol.authExpiredMessage))
        } else {
            setAuth(.signedIn(account: status.account ?? "Grok"))
        }
        return status
    }

    private func setAuth(_ state: AuthState) {
        guard state != authState else { return }
        authState = state
        for observer in observers { observer(state) }
    }

    // MARK: - Sign-in (only ever from an explicit user click)

    private final class LoginAttempt {
        let id: Int
        let deviceCode: Bool
        var process: ManagedProcess?
        var tasks: [Task<Void, Never>] = []
        var progress: LoginProgress?

        init(id: Int, deviceCode: Bool) {
            self.id = id
            self.deviceCode = deviceCode
        }

        @MainActor func stop() {
            tasks.forEach { $0.cancel() }
            tasks = []
            if let p = process { GrokProcess.retire(p) }
            process = nil
        }
    }

    /// `.browser` (and `.terminal`): `grok login --oauth`, which opens the browser at auth.x.ai (X, Google, Apple
    /// or email). `.deviceCode`: `grok login --device-auth`, a code to confirm on accounts.x.ai. The CLI stores the
    /// login itself; Lectern only relays the link and code it prints.
    public func startLogin(_ method: LoginMethod) {
        if let current = login {
            current.stop()
            login = nil
        } else {
            stateBeforeLogin = authState
        }
        guard let bin = currentBinary() else {
            loginMethod = nil
            setAuth(.failed(installIssue ?? GrokProtocol.notFoundMessage))
            return
        }
        loginCounter += 1
        let deviceCode = method == .deviceCode
        let attempt = LoginAttempt(id: loginCounter, deviceCode: deviceCode)
        login = attempt
        loginMethod = deviceCode ? .deviceCode : .browser
        setAuth(.loggingIn(LoginProgress(message: deviceCode ? "Getting a sign-in code from xAI…"
                                                              : "Opening your browser to sign in to Grok…")))
        let id = attempt.id
        let p = ManagedProcess(executable: bin, arguments: GrokProtocol.loginArguments(deviceCode: deviceCode),
                               environment: environment, currentDirectory: GrokProtocol.workingDirectory,
                               keepStdinOpen: false)
        p.onStdoutLine = { [weak self] _ in self?.loginOutputChanged(attempt: id) }
        p.onExit = { [weak self] status, stderr in self?.loginExited(status: status, stderr: stderr, attempt: id) }
        do {
            try p.start()
        } catch {
            finishLogin(loginFailed("Couldn't start the Grok sign-in: \(error.localizedDescription)"))
            return
        }
        attempt.process = p
        // The CLI prints the link and code on stderr; ManagedProcess keeps its tail.
        attempt.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.login?.id == id else { return }
                self.loginOutputChanged(attempt: id)
            }
        })
        let timeout = loginTimeout
        attempt.tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.login?.id == id else { return }
            self.finishLogin(self.loginFailed("The Grok sign-in timed out. Try again."))
        })
    }

    public func cancelLogin() {
        guard login != nil else { return }
        finishLogin(stateBeforeLogin)
        refreshAuth()
    }

    private func loginOutputChanged(attempt id: Int) {
        guard let attempt = login, attempt.id == id, let text = attempt.process?.stderrTail else { return }
        let url = GrokLoginOutput.url(in: text)
        let progress: LoginProgress?
        if attempt.deviceCode {
            guard let code = GrokLoginOutput.userCode(in: text) else { return }
            progress = LoginProgress(message: "Enter the code \(code) on the xAI page to finish signing in to Grok.",
                                     url: url, userCode: code)
        } else {
            progress = url.map { LoginProgress(message: "Finish signing in to Grok in your browser — with X, Google, Apple or email. If no browser window opened, use the link.", url: $0) }
        }
        guard let progress, progress != attempt.progress else { return }
        attempt.progress = progress
        setAuth(.loggingIn(progress))
    }

    private func loginExited(status: Int32, stderr: String, attempt id: Int) {
        guard let attempt = login, attempt.id == id else { return }
        attempt.process = nil
        guard status == 0 else {
            let detail = GrokLoginOutput.lastLine(in: stderr) ?? ""
            finishLogin(loginFailed(detail.isEmpty ? "The Grok sign-in didn't complete." : "The Grok sign-in didn't complete: \(detail)"))
            return
        }
        attempt.stop()
        login = nil
        loginMethod = nil
        authExpired = false
        Task {
            if await checkStatus()?.signedIn != true, login == nil {
                // The CLI said the sign-in worked; trust it over a status check that couldn't tell.
                setAuth(.signedIn(account: accountLabel ?? "Grok"))
            }
        }
    }

    private func finishLogin(_ state: AuthState) {
        login?.stop()
        login = nil
        loginMethod = nil
        setAuth(state)
    }

    /// A sign-in that didn't complete leaves the stored login as it was.
    private func loginFailed(_ message: String) -> AuthState {
        if case .signedOut = stateBeforeLogin { return .signedOut(reason: message) }
        return .failed(message)
    }
}

enum GrokProcess {
    /// Stop listening and terminate, keeping the object alive until the child exits (SIGKILL escalation).
    @MainActor static func retire(_ p: ManagedProcess, after delay: TimeInterval = 0) {
        p.onStdoutLine = nil
        guard p.isRunning else { p.onExit = nil; return }
        p.onExit = { _, _ in p.onExit = nil }
        if delay <= 0 { p.terminate(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if p.isRunning { p.terminate() } }
    }
}
