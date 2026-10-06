import Foundation

// Shared vocabulary between the backends (Claude Code CLI, Codex app-server) and the app UI.
// Backend implementations live in LecternCore/Claude and LecternCore/Codex; the app layer
// (Sources/Lectern) only talks to them through ProviderService and ChatSession.

public enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    /// User-facing name. The Codex harness is what the ChatGPT subscription runs through.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }
}

/// One entry in a model picker.
public struct ModelOption: Identifiable, Hashable, Sendable {
    /// Value passed to the backend (`--model` for Claude, `model` for Codex). "" = backend default.
    public let id: String
    public let displayName: String
    public let detail: String?
    /// Supported reasoning efforts in UI order (e.g. ["low", "medium", "high"]).
    public let efforts: [String]
    /// Effort the backend uses when none is given; nil if unknown.
    public let defaultEffort: String?
    /// Codex service tier id for the faster, more expensive tier (e.g. "priority"); nil if none.
    public let fastTierId: String?
    public let isDefault: Bool

    public init(id: String, displayName: String, detail: String? = nil, efforts: [String],
                defaultEffort: String? = nil, fastTierId: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.fastTierId = fastTierId
        self.isDefault = isDefault
    }
}

/// Per-turn knobs chosen in the UI. Backends must apply these explicitly on every turn so the
/// user's global CLI config (e.g. Codex `service_tier = "priority"`, effort "ultra") never leaks in.
public struct TurnSettings: Equatable, Codable, Sendable {
    /// "" = backend default.
    public var model: String
    /// "" = model default.
    public var effort: String
    /// Codex only: use the fast/priority tier (costs ~2.5x included usage). Ignored by Claude.
    public var fastTier: Bool

    public init(model: String = "", effort: String = "", fastTier: Bool = false) {
        self.model = model
        self.effort = effort
        self.fastTier = fastTier
    }
}

/// A fully built prompt for one turn.
public struct TurnRequest: Sendable {
    /// Full user message text, including the <reading_context>/<pages> envelope.
    public var text: String
    /// Rendered page images (PNG files on disk) to attach.
    public var imagePNGs: [URL]
    /// Set only for a skill-mode turn (see SkillTurn); nil keeps the turn tool-free.
    public var skill: SkillTurn?

    public init(text: String, imagePNGs: [URL] = [], skill: SkillTurn? = nil) {
        self.text = text
        self.imagePNGs = imagePNGs
        self.skill = skill
    }
}

public struct TurnUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var durationMs: Int?

    public init(inputTokens: Int? = nil, cachedInputTokens: Int? = nil, outputTokens: Int? = nil, durationMs: Int? = nil) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
    }
}

public struct QuotaWindow: Equatable, Sendable {
    /// e.g. "5-hour", "Weekly".
    public var label: String
    /// 0...100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public var provider: Provider
    public var windows: [QuotaWindow]
    /// True when included plan usage is used up: further turns would be refused or would spend
    /// purchased credits. The app blocks sending (unless the user overrides) when this is true.
    public var includedUsageExhausted: Bool
    /// Extra info for the UI, e.g. "1,000 purchased credits available".
    public var note: String?

    public init(provider: Provider, windows: [QuotaWindow], includedUsageExhausted: Bool, note: String? = nil) {
        self.provider = provider
        self.windows = windows
        self.includedUsageExhausted = includedUsageExhausted
        self.note = note
    }
}

public enum BackendError: Error, Equatable, Sendable {
    /// Not signed in, or the stored login was revoked/expired (Claude 401, Codex "unauthorized").
    case authRequired(String)
    /// CLI binary missing or unusable.
    case notInstalled(String)
    /// Plan usage limit hit.
    case usageLimit(String)
    /// Backend process died unexpectedly.
    case processExited(String)
    /// Malformed or unexpected protocol traffic.
    case protocolError(String)
    /// Any other API/model error, with the backend's message.
    case api(String)

    public var message: String {
        switch self {
        case .authRequired(let m), .notInstalled(let m), .usageLimit(let m),
             .processExited(let m), .protocolError(let m), .api(let m):
            return m
        }
    }

    public var isAuth: Bool {
        if case .authRequired = self { return true }
        return false
    }
}

public enum BackendEvent: Sendable {
    /// Backend reported the resolved model for this turn (e.g. "claude-opus-5-5", "gpt-6.1-sol").
    case sessionReady(model: String)
    /// Model is reasoning; no visible text yet.
    case thinking
    /// Streamed answer text to append.
    case textDelta(String)
    /// Terminal: turn finished. `text` is the authoritative full answer text.
    case completed(text: String, usage: TurnUsage?)
    /// Terminal: user pressed Stop.
    case interrupted
    /// Terminal: turn failed.
    case failed(BackendError)
    /// Fresh usage-limit info (may arrive at any time).
    case quota(QuotaSnapshot)
    /// Non-fatal notice, e.g. "Claude is billing an API key, not your subscription".
    case warning(String)
    /// The backend could not resume the previous conversation; the next send starts a new one. Context
    /// that was sent earlier is gone, so the app must reset its ContextBuilder for this provider. It ends
    /// the current turn unsent (the prompt was built for the old conversation): the app rebuilds the
    /// prompt and sends it again.
    case conversationReset
}

/// One conversation with one backend about one document.
@MainActor
public protocol ChatSession: AnyObject {
    var provider: Provider { get }
    var isBusy: Bool { get }
    /// Persistable conversation id: Claude session UUID or Codex thread id. nil until one exists.
    var conversationId: String? { get }
    /// Events for the current turn, delivered on the main actor.
    var onEvent: ((BackendEvent) -> Void)? { get set }

    /// Start a turn. Must deliver exactly one terminal event (.completed / .interrupted / .failed, or
    /// .conversationReset when the turn ended unsent), including when the process cannot be started.
    /// Never called while `isBusy`.
    func send(_ request: TurnRequest, settings: TurnSettings)
    /// Stop the current turn (no-op if idle). The conversation stays usable.
    func interrupt()
    /// Forget conversation memory; the next send starts a fresh backend conversation.
    func resetConversation()
    /// Release processes/resources. A new session can later resume via `conversationId`.
    func shutdown()
}

public enum LoginMethod: Sendable {
    /// Official browser sign-in, driven from inside the app. The UI offers it for ChatGPT only.
    case browser
    /// Codex only: device-code sign-in (shows a code to enter on a web page).
    case deviceCode
    /// Claude only: open Terminal running the official `claude auth login`.
    case terminal
}

public struct LoginProgress: Equatable, Sendable {
    public var message: String
    /// Sign-in page to open manually if the browser didn't open.
    public var url: URL?
    /// Device-code flow: the code the user types on the verification page.
    public var userCode: String?

    public init(message: String, url: URL? = nil, userCode: String? = nil) {
        self.message = message
        self.url = url
        self.userCode = userCode
    }
}

public enum AuthState: Equatable, Sendable {
    case unknown
    case checking
    /// e.g. "you@example.com · Max".
    case signedIn(account: String)
    /// Reason shown to the user, e.g. "Your Claude login expired. Log in again to continue."
    case signedOut(reason: String)
    case loggingIn(LoginProgress)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// App-wide service for one provider: binary discovery, auth, model catalog, quota, sessions.
/// Implementations are `@Observable` so SwiftUI can read `authState`, `models`, `quota` directly.
@MainActor
public protocol ProviderService: AnyObject {
    var provider: Provider { get }
    /// Non-nil when the CLI can't be found/used; shown instead of the chat input.
    var installIssue: String? { get }
    var authState: AuthState { get }
    var models: [ModelOption] { get }
    var quota: QuotaSnapshot? { get }

    /// Cheap status re-check (no model call).
    func refreshAuth()
    /// As-requested login. Only ever called from an explicit user click.
    func startLogin(_ method: LoginMethod)
    func cancelLogin()
    /// Called by sessions when a turn fails with an auth error.
    func markAuthExpired(_ reason: String)
    func reloadModels()
    /// Register for auth state changes (e.g. to auto-retry a question after login succeeds).
    func addAuthObserver(_ handler: @escaping @MainActor (AuthState) -> Void)
    /// New session for a document. `conversationId` resumes a previous conversation when possible.
    func makeSession(conversationId: String?) -> ChatSession
    /// Skills this provider's harness can run on this Mac (empty if none or unsupported).
    func listSkills() async -> [SkillInfo]
}

public extension ProviderService {
    func listSkills() async -> [SkillInfo] { [] }
}
