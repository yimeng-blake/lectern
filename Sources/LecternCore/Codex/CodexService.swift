import AppKit
import Foundation
import Observation

/// Where the Codex app-server keeps its config, login and threads.
public enum CodexHomeMode: String, Codable, CaseIterable, Sendable {
    /// Lectern's own CODEX_HOME (no plugins, no notify hook, standard tier) with its own sign-in.
    case isolated
    /// The user's ~/.codex and its existing login.
    case shared
}

/// The ChatGPT provider: one Codex `app-server` for the whole app, shared by all sessions.
@MainActor @Observable
public final class CodexService: ProviderService {
    public let provider: Provider = .codex
    public private(set) var installIssue: String?
    public private(set) var authState: AuthState = .unknown
    public private(set) var models: [ModelOption] = []
    public private(set) var quota: QuotaSnapshot?

    public private(set) var binaryPath: String?
    public private(set) var binaryVersion: String?
    public private(set) var accountEmail: String?
    /// Raw plan type, e.g. "pro".
    public private(set) var planName: String?
    /// The sign-in started by `startLogin` that has not completed yet.
    public private(set) var activeLoginId: String?
    /// Opens sign-in pages. Defaults to the user's browser.
    @ObservationIgnored public var urlOpener: @MainActor (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }

    static let signInReason = "Sign in with ChatGPT to use it here"
    static let expiredMessage = "Your ChatGPT sign-in expired or was revoked. Sign in again to continue."
    static let managedMarker = "# Managed by Lectern"
    static let managedConfig = """
    # Managed by Lectern
    model = "gpt-6.1-sol"
    model_reasoning_effort = "low"
    service_tier = "default"
    notify = []
    [analytics]
    enabled = false

    """

    @ObservationIgnored let server = CodexAppServer()
    @ObservationIgnored let workingDirectory: @MainActor () -> URL
    @ObservationIgnored private let pathOverride: @MainActor () -> String?
    @ObservationIgnored private let homeMode: @MainActor () -> CodexHomeMode
    @ObservationIgnored private let isolatedHome: @MainActor () -> URL

    /// Account type from account/read: "chatgpt", "apiKey", "amazonBedrock", or nil.
    @ObservationIgnored private(set) var accountType: String?
    /// Set by markAuthExpired. A failed turn beats account/read, which only reports what is stored.
    @ObservationIgnored private var expiredReason: String?
    @ObservationIgnored private var launchedHomeMode: CodexHomeMode?
    @ObservationIgnored private var stateBeforeLogin: AuthState?
    /// Bumped by every startLogin/cancelLogin so a stale account/login/start reply is abandoned.
    @ObservationIgnored private var loginAttempt = 0
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?
    @ObservationIgnored private var rateLimits: JSONObject?
    @ObservationIgnored private var ordinaryUsageAllowed: Bool?
    /// When `quota` was last confirmed by the server (read or update notification); nil = unconfirmed.
    @ObservationIgnored private var quotaFetchedAt: Date?
    /// Bumped by restart/signOut so an account read that started before them is dropped.
    @ObservationIgnored private var accountEpoch = 0
    @ObservationIgnored private var authObservers: [@MainActor (AuthState) -> Void] = []
    @ObservationIgnored private var versionPath: String?

    public convenience init(pathOverride: @escaping @MainActor () -> String?,
                            homeMode: @escaping @MainActor () -> CodexHomeMode) {
        self.init(pathOverride: pathOverride, homeMode: homeMode,
                  isolatedHome: { AppPaths.codexHome }, workingDirectory: { AppPaths.codexCwd })
    }

    /// `isolatedHome` / `workingDirectory` are injectable so tests never touch the real app folders.
    init(pathOverride: @escaping @MainActor () -> String?,
         homeMode: @escaping @MainActor () -> CodexHomeMode,
         isolatedHome: @escaping @MainActor () -> URL,
         workingDirectory: @escaping @MainActor () -> URL) {
        self.pathOverride = pathOverride
        self.homeMode = homeMode
        self.isolatedHome = isolatedHome
        self.workingDirectory = workingDirectory
        server.makeLaunch = { [weak self] in
            guard let self else { throw CodexAppServer.Failure.notInstalled("Codex service is gone.") }
            return try self.makeLaunch()
        }
        server.addListener { [weak self] method, params in self?.handleNotification(method, params) }
        server.addExitListener { [weak self] message in self?.serverStopped(message) }
        locateBinary()
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: ProviderService

    /// Account plus quota: readAccount reads the rate limits before it publishes a sign-in.
    public func refreshAuth() {
        Task { await readAccount() }
    }

    public func reloadModels() {
        Task { await loadModels() }
    }

    /// Re-reads account, quota and the model catalog; returns when all three are done.
    public func refresh() async {
        await readAccount()
        await loadModels()
    }

    /// `.terminal` is Claude-only; it falls back to the browser flow here.
    public func startLogin(_ method: LoginMethod) {
        if let id = activeLoginId { abandonLogin(id) }
        if case .loggingIn = authState {} else { stateBeforeLogin = authState }
        loginAttempt += 1
        let attempt = loginAttempt
        setAuth(.loggingIn(LoginProgress(message: "Starting ChatGPT sign-in…")))
        Task { await beginLogin(deviceCode: method == .deviceCode, attempt: attempt) }
    }

    public func cancelLogin() {
        guard case .loggingIn = authState else { return }
        loginAttempt += 1
        if let id = activeLoginId { abandonLogin(id) }
        restoreAfterLogin(nil)
    }

    public func markAuthExpired(_ reason: String) {
        expiredReason = reason
        // The next sign-in may be another account: its quota must be read again before a send.
        quotaFetchedAt = nil
        if !loginInProgress { setAuth(.signedOut(reason: reason)) }
    }

    public func addAuthObserver(_ handler: @escaping @MainActor (AuthState) -> Void) {
        authObservers.append(handler)
    }

    public func makeSession(conversationId: String?) -> ChatSession {
        CodexSession(service: self, conversationId: conversationId)
    }

    // MARK: Settings actions

    /// account/logout. Only in isolated mode: in shared mode it would sign the user's own Codex out.
    public func signOut() {
        guard homeMode() == .isolated else { return }
        if launchedHomeMode != nil, launchedHomeMode != .isolated { server.stop() }
        Task {
            _ = try? await server.request("account/logout", nil)
            accountEpoch += 1
            expiredReason = nil
            clearQuota()
            await readAccount()
        }
    }

    /// After path or home-mode changes: stop the app-server and forget the account; the server
    /// restarts on the next request (the caller follows with refreshAuth/reloadModels to show status).
    public func restart() {
        // The sign-in dies with the process; no account/login/cancel needed.
        loginAttempt += 1
        activeLoginId = nil
        loginTimeout?.cancel()
        stateBeforeLogin = nil
        server.stop()
        accountEpoch += 1
        expiredReason = nil
        accountType = nil
        accountEmail = nil
        planName = nil
        clearQuota()
        locateBinary()
        setAuth(.unknown)
    }

    /// Terminates the app-server (e.g. when the app quits). The next request starts it again.
    public func stop() {
        server.stop()
    }

    // MARK: Launch

    private func locateBinary() {
        let found = BinaryLocator.codex(override: pathOverride())
        installIssue = found.issue
        binaryPath = found.url?.path
        if let url = found.url, versionPath != url.path {
            versionPath = url.path
            Task { await loadVersion(url) }
        }
        if let issue = found.issue { setAuth(.failed(issue)) }
    }

    private func loadVersion(_ url: URL) async {
        let result = await ProcessRunner.run(url, ["--version"], timeout: 10)
        guard versionPath == url.path else { return }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        binaryVersion = out.isEmpty ? nil : out.replacingOccurrences(of: "codex-cli ", with: "")
    }

    private func makeLaunch() throws -> CodexAppServer.Launch {
        locateBinary()
        guard let url = binaryPath.map({ URL(fileURLWithPath: $0) }) else {
            throw CodexAppServer.Failure.notInstalled(installIssue ?? "Codex not found.")
        }
        let mode = homeMode()
        launchedHomeMode = mode
        var arguments = ["app-server"]
        let environment: [String: String]
        switch mode {
        case .isolated:
            let home = isolatedHome()
            writeManagedConfig(in: home)
            environment = CleanEnvironment.make(extra: ["CODEX_HOME": home.path])
        case .shared:
            environment = CleanEnvironment.make()
            arguments += ["-c", "notify=[]", "-c", "service_tier=\"default\""]
        }
        return .init(executable: url, arguments: arguments, environment: environment,
                     currentDirectory: workingDirectory())
    }

    /// Writes config.toml when missing or still ours; a file the user replaced is left alone.
    private func writeManagedConfig(in home: URL) {
        AppPaths.ensure(home)
        let file = home.appendingPathComponent("config.toml")
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            guard existing.hasPrefix(Self.managedMarker), existing != Self.managedConfig else { return }
        }
        try? Self.managedConfig.write(to: file, atomically: true, encoding: .utf8)
    }

    private func serverStopped(_ message: String) {
        guard activeLoginId != nil else { return }
        activeLoginId = nil
        loginTimeout?.cancel()
        stateBeforeLogin = nil
        setAuth(.signedOut(reason: "Sign-in was interrupted because Codex stopped. Try again."))
    }

    // MARK: Account

    private func setAuth(_ state: AuthState) {
        guard state != authState else { return }
        authState = state
        for observer in authObservers { observer(state) }
    }

    /// A sign-in owns the state until account/login/completed, including while its
    /// account/login/start reply (which carries the loginId) is still pending.
    private var loginInProgress: Bool {
        if activeLoginId != nil { return true }
        if case .loggingIn = authState { return true }
        return false
    }

    private func readAccount() async {
        switch authState {
        case .unknown, .failed: setAuth(.checking)
        default: break
        }
        let epoch = accountEpoch
        do {
            let result = try await server.request("account/read", [:])
            guard epoch == accountEpoch else { return }
            // Auth observers send waiting questions as soon as this publishes .signedIn, and the
            // purchased-credits guard needs the quota by then.
            if result.obj("account") != nil { await readRateLimits() } else { clearQuota() }
            guard epoch == accountEpoch else { return }
            applyAccount(result)
        } catch {
            guard epoch == accountEpoch, !loginInProgress else { return }
            setAuth(.failed(Self.describe(error)))
        }
    }

    private func applyAccount(_ result: JSONObject) {
        let account = result.obj("account")
        accountType = account?.str("type")
        accountEmail = account?.str("email")
        planName = account?.str("planType")
        guard !loginInProgress else { return }
        guard let account else {
            expiredReason = nil
            if result.bool("requiresOpenaiAuth") == false {
                setAuth(.signedIn(account: "No sign-in required"))
            } else {
                setAuth(.signedOut(reason: Self.signInReason))
            }
            return
        }
        if let expiredReason {
            setAuth(.signedOut(reason: expiredReason))
        } else {
            setAuth(.signedIn(account: Self.describeAccount(account)))
        }
    }

    static func describeAccount(_ account: JSONObject) -> String {
        switch account.str("type") {
        case "apiKey": return "OpenAI API key"
        case "amazonBedrock": return "Amazon Bedrock"
        default:
            let parts = [account.str("email"), account.str("planType").map(planDisplayName)].compactMap { $0 }
            return parts.isEmpty ? "ChatGPT account" : parts.joined(separator: " · ")
        }
    }

    static func planDisplayName(_ raw: String) -> String {
        let known = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                     "promax": "Pro Max", "team": "Team", "business": "Business", "enterprise": "Enterprise",
                     "edu": "Edu", "unknown": "ChatGPT"]
        return known[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: Login

    private func beginLogin(deviceCode: Bool, attempt: Int) async {
        do {
            let result = try await server.request("account/login/start",
                                                  ["type": deviceCode ? "chatgptDeviceCode" : "chatgpt"])
            guard attempt == loginAttempt else {
                if let id = result.str("loginId") { abandonLogin(id) }
                return
            }
            guard let loginId = result.str("loginId") else {
                restoreAfterLogin("Codex did not start a sign-in.")
                return
            }
            activeLoginId = loginId
            let progress: LoginProgress
            if deviceCode {
                let code = result.str("userCode")
                progress = LoginProgress(message: "Enter the code \(code ?? "") on the OpenAI page to finish signing in.",
                                         url: result.str("verificationUrl").flatMap(URL.init(string:)), userCode: code)
            } else {
                progress = LoginProgress(message: "Finish signing in with ChatGPT in your browser.",
                                         url: result.str("authUrl").flatMap(URL.init(string:)))
            }
            setAuth(.loggingIn(progress))
            if let url = progress.url { urlOpener(url) }
            loginTimeout?.cancel()
            loginTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, self.activeLoginId == loginId else { return }
                self.loginAttempt += 1
                self.abandonLogin(loginId)
                self.restoreAfterLogin("Sign-in timed out. Try again.")
            }
        } catch {
            guard attempt == loginAttempt else { return }
            restoreAfterLogin("Couldn't start sign-in: \(Self.describe(error))")
        }
    }

    /// account/login/cancel for a sign-in we no longer track; its login/completed is ignored.
    private func abandonLogin(_ loginId: String) {
        if activeLoginId == loginId { activeLoginId = nil }
        loginTimeout?.cancel()
        server.post("account/login/cancel", ["loginId": loginId])
    }

    /// After a cancelled or failed sign-in. A failed re-login leaves the existing login in place.
    private func restoreAfterLogin(_ failure: String?) {
        let previous = stateBeforeLogin
        stateBeforeLogin = nil
        switch previous {
        case .signedIn?:
            setAuth(previous!)
        case .signedOut(let reason)?:
            setAuth(.signedOut(reason: failure ?? reason))
        default:
            // The state before the sign-in was never established (e.g. a failed status check), so
            // don't declare the account signed out.
            if let failure {
                setAuth(.failed(failure))
            } else {
                setAuth(.checking)
                Task { await readAccount() }
            }
        }
    }

    private func loginCompleted(_ params: JSONObject) {
        guard let active = activeLoginId else { return }
        if let id = params.str("loginId"), id != active { return }
        activeLoginId = nil
        loginTimeout?.cancel()
        if params.bool("success") == true {
            stateBeforeLogin = nil
            expiredReason = nil
            quotaFetchedAt = nil
            setAuth(.checking)
            Task { await refresh() }
        } else {
            restoreAfterLogin(params.str("error").map { "Sign-in didn't finish: \($0)" } ?? Self.signInReason)
        }
    }

    // MARK: Notifications

    private func handleNotification(_ method: String, _ params: JSONObject) {
        switch method {
        case "account/login/completed":
            loginCompleted(params)
        case "account/updated":
            Task { await readAccount() }
        case "account/rateLimits/updated":
            if let update = params.obj("rateLimits") { mergeRateLimits(update) }
        default:
            break
        }
    }

    // MARK: Quota

    /// How the purchased-credits guard should treat the next ChatGPT turn.
    public enum CreditsCheck: Equatable, Sendable {
        /// Not a ChatGPT account (API key, Bedrock, no sign-in required): no purchased credits.
        case notApplicable
        /// A recent read says included usage is available.
        case available
        /// A recent read says included usage is used up.
        case exhausted
        /// Never read, read failed, `ordinaryUsageAllowed` unavailable, or out of date: read it first.
        case needsRefresh
    }

    /// An unknown or old quota never counts as "fine". An exhausted snapshot is also stale once one of
    /// its windows has reset.
    public func creditsCheck(maxAge: TimeInterval = 300, now: Date = Date()) -> CreditsCheck {
        guard authState.isSignedIn, accountType == "chatgpt" else { return .notApplicable }
        guard let quota, let fetched = quotaFetchedAt, now.timeIntervalSince(fetched) <= maxAge else {
            return .needsRefresh
        }
        if quota.includedUsageExhausted {
            let reset = quota.windows.contains { ($0.resetsAt ?? .distantFuture) <= now }
            return reset ? .needsRefresh : .exhausted
        }
        // Null means unavailable; the protocol says not to infer recovery from percentages.
        return ordinaryUsageAllowed == nil ? .needsRefresh : .available
    }

    /// account/rateLimits/read now; returns when the reply (or failure) is in.
    public func refreshQuota() async {
        await readRateLimits()
    }

    private func clearQuota() {
        rateLimits = nil
        ordinaryUsageAllowed = nil
        quota = nil
        quotaFetchedAt = nil
    }

    private func readRateLimits() async {
        do {
            let result = try await server.request("account/rateLimits/read", [:])
            ordinaryUsageAllowed = result.bool("ordinaryUsageAllowed")
            rateLimits = result.obj("rateLimits")
            quota = rateLimits.map { Self.quotaSnapshot($0, ordinaryUsageAllowed: ordinaryUsageAllowed) }
            quotaFetchedAt = rateLimits == nil ? nil : Date()
        } catch CodexAppServer.Failure.rpc(let code, _) where code == -32600 {
            // Signed out, or not a ChatGPT account: no quota to show.
            clearQuota()
        } catch {
            // Server trouble: keep the last snapshot; creditsCheck lets it age out.
        }
    }

    /// account/rateLimits/updated is sparse: null fields keep the previous value.
    private func mergeRateLimits(_ update: JSONObject) {
        guard var current = rateLimits else {
            rateLimits = update
            quota = Self.quotaSnapshot(update, ordinaryUsageAllowed: ordinaryUsageAllowed)
            quotaFetchedAt = Date()
            Task { await readRateLimits() }
            return
        }
        if let a = update.str("limitId"), let b = current.str("limitId"), a != b { return }
        let wasExhausted = quota?.includedUsageExhausted == true
        for (key, value) in update where !(value is NSNull) { current[key] = value }
        rateLimits = current
        quota = Self.quotaSnapshot(current, ordinaryUsageAllowed: ordinaryUsageAllowed)
        quotaFetchedAt = Date()
        // A sparse update can't clear "limit reached"; re-read so a reset unblocks sending.
        if wasExhausted { Task { await readRateLimits() } }
    }

    static func quotaSnapshot(_ rl: JSONObject, ordinaryUsageAllowed: Bool?) -> QuotaSnapshot {
        let windows: [QuotaWindow] = ["primary", "secondary"].compactMap { key in
            guard let w = rl.obj(key) else { return nil }
            return QuotaWindow(label: windowLabel(w.int("windowDurationMins")),
                               usedPercent: w.double("usedPercent") ?? 0,
                               resetsAt: w.double("resetsAt").map { Date(timeIntervalSince1970: $0) })
        }
        let reached = rl.str("rateLimitReachedType") != nil
        let exhausted = ordinaryUsageAllowed == false || reached || windows.contains { $0.usedPercent >= 100 }
        return QuotaSnapshot(provider: .codex, windows: windows, includedUsageExhausted: exhausted,
                             note: creditsNote(rl.obj("credits")))
    }

    static func windowLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage" }
        switch minutes {
        case 10080: return "Weekly"
        case 300: return "5-hour"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }

    static func creditsNote(_ credits: JSONObject?) -> String? {
        guard let credits, credits.bool("hasCredits") == true else { return nil }
        if credits.bool("unlimited") == true { return "Unlimited credits" }
        guard let raw = credits.str("balance"), let value = Double(raw), value > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        let balance = formatter.string(from: NSNumber(value: value)) ?? raw
        return "\(balance) purchased credits — Lectern won't spend them unless you allow it"
    }

    // MARK: Models

    private func loadModels() async {
        var options: [ModelOption] = []
        var cursor: String?
        do {
            for _ in 0..<10 {
                var params: JSONObject = [:]
                if let cursor { params["cursor"] = cursor }
                let result = try await server.request("model/list", params)
                options += result.objs("data").compactMap(Self.modelOption)
                cursor = result.str("nextCursor")
                if cursor == nil { break }
            }
        } catch {
            return
        }
        if !options.isEmpty { models = options }
    }

    static func modelOption(_ m: JSONObject) -> ModelOption? {
        guard m.bool("hidden") != true, let id = m.str("id") ?? m.str("model") else { return nil }
        let efforts = m.objs("supportedReasoningEfforts").compactMap { $0.str("reasoningEffort") }
        let fastTier = m.objs("serviceTiers").compactMap { $0.str("id") }.first { $0 != "default" }
        return ModelOption(id: id, displayName: m.str("displayName") ?? id, detail: m.str("description"),
                           efforts: efforts, defaultEffort: m.str("defaultReasoningEffort"),
                           fastTierId: fastTier, isDefault: m.bool("isDefault") == true)
    }

    // MARK: One-shot

    /// A throwaway question on an ephemeral thread (conversation titles): the catalog's lightest
    /// model, effort low, standard tier, read-only, no approvals. nil when signed out, when the
    /// purchased-credits guard would hold a question (quota unknown or included usage used up), or
    /// on any failure or timeout. It never spends purchased credits and never marks the login expired.
    public func oneShot(prompt: String, timeout: TimeInterval = 20) async -> String? {
        guard installIssue == nil, await preflight() == nil else { return nil }
        if creditsCheck() == .needsRefresh { await refreshQuota() }
        switch creditsCheck() {
        case .available, .notApplicable: break
        case .exhausted, .needsRefresh: return nil
        }
        if models.isEmpty { await loadModels() }
        guard let option = Self.oneShotModel(in: models) else { return nil }
        let effort = option.efforts.isEmpty || option.efforts.contains("low") ? "low" : option.efforts[0]
        let threadId: String
        do {
            let result = try await server.request("thread/start", [
                "model": option.id, "serviceTier": "default", "cwd": workingDirectory().path,
                "sandbox": "read-only", "approvalPolicy": "never", "ephemeral": true,
            ], timeout: timeout)
            guard let id = result.obj("thread")?.str("id") else { return nil }
            threadId = id
        } catch {
            return nil
        }
        let generation = server.generation
        let turn = OneShotTurn()
        let text: String? = await withCheckedContinuation { continuation in
            turn.continuation = continuation
            turn.listener = server.addThreadListener(threadId) { [weak turn] method, params in turn?.handle(method, params) }
            turn.exitListener = server.addExitListener { [weak turn] _ in turn?.finish(nil) }
            turn.timer = Task { [weak self, weak turn] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let turn else { return }
                if let turnId = turn.turnId { self?.server.post("turn/interrupt", ["threadId": threadId, "turnId": turnId]) }
                turn.finish(nil)
            }
            Task {
                do {
                    let result = try await self.server.request("turn/start", [
                        "threadId": threadId, "input": [["type": "text", "text": prompt, "text_elements": [Any]()]],
                        "model": option.id, "effort": effort, "serviceTier": "default",
                    ], timeout: timeout)
                    if turn.turnId == nil { turn.turnId = result.obj("turn")?.str("id") }
                } catch {
                    turn.finish(nil)
                }
            }
        }
        turn.timer?.cancel()
        if let token = turn.listener { server.removeThreadListener(threadId, token) }
        if let token = turn.exitListener { server.removeListener(token) }
        if server.generation == generation { server.post("thread/unsubscribe", ["threadId": threadId]) }
        guard let clean = text.map({ ReaderPrompt.stripDirectives($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
              !clean.isEmpty else { return nil }
        return clean
    }

    /// The catalog's lightest model for one-shot chores: the first "luna" or "mini" model, else the default.
    public static func oneShotModel(in models: [ModelOption]) -> ModelOption? {
        models.first { m in
            let name = "\(m.id) \(m.displayName)".lowercased()
            return name.contains("luna") || name.contains("mini")
        } ?? models.first { $0.isDefault } ?? models.first
    }

    /// One `oneShot` turn; every callback runs on the main actor.
    @MainActor private final class OneShotTurn {
        var continuation: CheckedContinuation<String?, Never>?
        var listener: UUID?
        var exitListener: UUID?
        var timer: Task<Void, Never>?
        var turnId: String?
        private var messages: [String] = []

        func handle(_ method: String, _ params: JSONObject) {
            switch method {
            case "turn/started":
                if turnId == nil { turnId = params.obj("turn")?.str("id") }
            case "item/completed":
                if let item = params.obj("item"), item.str("type") == "agentMessage", let text = item.str("text") {
                    messages.append(text)
                }
            case "turn/completed":
                let info = params.obj("turn") ?? [:]
                guard info.str("status") == "completed" else { return finish(nil) }
                var text = messages.joined(separator: "\n\n")
                if text.isEmpty {
                    text = info.objs("items").filter { $0.str("type") == "agentMessage" }
                        .compactMap { $0.str("text") }.joined(separator: "\n\n")
                }
                finish(text)
            default:
                break
            }
        }

        func finish(_ text: String?) {
            continuation?.resume(returning: text)
            continuation = nil
        }
    }

    // MARK: Session support

    struct TurnConfig: Equatable {
        var model: String
        var effort: String
        var serviceTier: String
    }

    /// Explicit model, effort and tier for a turn, so the user's own Codex config never leaks in.
    /// nil when model and effort can't both be pinned (no catalog and no explicit choice): such a
    /// turn would run on the user's ~/.codex defaults, so it must not be sent.
    func turnConfig(for settings: TurnSettings) async -> TurnConfig? {
        if models.isEmpty { await loadModels() }
        let option = settings.model.isEmpty
            ? (models.first { $0.isDefault } ?? models.first)
            : models.first { $0.id == settings.model }
        let fallbackEffort = option.flatMap { $0.defaultEffort ?? $0.efforts.first }
        var effort = settings.effort.isEmpty ? fallbackEffort : settings.effort
        if let option, let chosen = effort, !option.efforts.isEmpty, !option.efforts.contains(chosen) {
            effort = fallbackEffort
        }
        guard let model = settings.model.isEmpty ? option?.id : settings.model, let effort else { return nil }
        let tier = settings.fastTier ? (option?.fastTierId ?? "default") : "default"
        return TurnConfig(model: model, effort: effort, serviceTier: tier)
    }

    static let noTurnConfigMessage = "Couldn't load the ChatGPT model list, so Lectern can't pin the model and effort for this question. Try again."

    /// Starts the app-server and returns an error that should fail the turn before it starts.
    /// A turn without a login is not refused by the server: it retries 401s for ~15 s first.
    func preflight() async -> BackendError? {
        do {
            try await server.ensureStarted()
        } catch {
            return Self.backendError(error)
        }
        switch authState {
        case .unknown, .checking, .failed: await readAccount()
        default: break
        }
        if loginInProgress { return .authRequired("Finish signing in to ChatGPT first.") }
        if case .signedOut(let reason) = authState { return .authRequired(reason) }
        return nil
    }

    /// Warning for logins that don't bill the ChatGPT subscription.
    var billingWarning: String? {
        switch accountType {
        case "apiKey": return "ChatGPT is using an OpenAI API key, not your ChatGPT subscription"
        case "amazonBedrock": return "ChatGPT is using Amazon Bedrock, not your ChatGPT subscription"
        default: return nil
        }
    }

    static func backendError(_ error: Error) -> BackendError {
        guard let failure = error as? CodexAppServer.Failure else { return .api(error.localizedDescription) }
        switch failure {
        case .notInstalled(let m), .launchFailed(let m): return .notInstalled(m)
        case .exited(let m): return .processExited(m)
        case .timedOut: return .protocolError(failure.message)
        case .rpc(_, let m):
            if m.range(of: #"authenticat|unauthori|log ?in|sign ?in"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .authRequired(expiredMessage)
            }
            return .api(m)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? CodexAppServer.Failure)?.message ?? error.localizedDescription
    }
}
