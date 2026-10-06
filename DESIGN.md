# Lectern design

Lectern is a personal macOS PDF reader with a side-by-side chat pane. It talks to Claude and ChatGPT
through the official first-party harnesses, using each user's own subscriptions:

- **Claude** — Claude Code CLI (`claude -p`, stream-json), logged in with the user's own Claude plan.
- **ChatGPT** — Codex `app-server` (JSON-RPC over stdio), logged in with ChatGPT. This is the same
  harness ChatGPT.app runs internally.

The app never touches stored credentials. Logins always complete through the vendors' own flows,
triggered only when the user asks: for Claude, the user runs the unmodified `claude auth login` in
Terminal (Lectern doesn't offer Claude.ai login inside the app, per Anthropic's policy for third-party
apps); for ChatGPT, Codex app-server's own `account/login/start`.

Build: SwiftPM, tools version 5.10 (only ever built with Swift 6.3 from the Command Line Tools and
the macOS 26 SDK; older toolchains and running on macOS 14/15 are untested), Swift 5 language mode,
macOS 14+ deployment target, Apple Silicon (arm64).
`swift build` (if `xcode-select` points at an older Xcode, prefix
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`; `scripts/build-app.sh` picks a toolchain with
Swift >= 5.10 by itself). Never `swift file.swift` (the JIT can't load PDFKit). No App Sandbox (the
app spawns external binaries).

## Targets and file ownership

```
Package.swift                                   (fixed)
Sources/LecternCore/Shared/ChatTypes.swift      (fixed) Provider, ModelOption, TurnSettings, TurnRequest,
                                                        BackendEvent, BackendError, AuthState, LoginMethod,
                                                        QuotaSnapshot, protocols ChatSession + ProviderService
Sources/LecternCore/Shared/ProcessSupport.swift (fixed) AppPaths, CleanEnvironment, BinaryLocator,
                                                        ManagedProcess, ProcessRunner, JSONLine, dict accessors
Sources/LecternCore/Shared/ReaderPrompt.swift   (fixed) system prompt, Codex directive stripping
Sources/LecternCore/Shared/ConversationTitler.swift (titler) fallback + model conversation titles
Sources/lectern-probe/Probe.swift               (fixed) dispatcher (`@main`; SwiftPM compiles a file named
                                                        main.swift as top-level code, so it can't hold `@main`);
                                                        calls claudeProbeCommands(), codexProbeCommands(),
                                                        contextProbeCommands(), e2eProbeCommands()
Sources/lectern-probe/ProbeE2E.swift            (integrator) `ask`: ReaderDocument → ContextBuilder → session,
                                                        with ChatModel's sign-in gate and credits guard;
                                                        `title`: ConversationTitler end to end (one model call)

Sources/LecternCore/Claude/*                    (Claude agent)  ClaudeService, ClaudeSession, parsing
Sources/lectern-probe/ProbeClaude.swift         (Claude agent)  func claudeProbeCommands() -> [ProbeCommand]
Sources/LecternCore/Codex/*                     (Codex agent)   CodexAppServer, CodexService, CodexSession
Sources/lectern-probe/ProbeCodex.swift          (Codex agent)   func codexProbeCommands() -> [ProbeCommand]
Sources/LecternCore/Document/*                  (Document agent) ReaderDocument, ContextBuilder, OCR, TableDetector,
                                                        CitationVerifier, PassageLocator
Sources/LecternCore/Document/CitationTypes.swift (fixed) CitationCheck
Sources/Lectern/App/ReadingFeatures.swift       (fixed) SelectionAction, ChatPreset, PassageRequest
Sources/Lectern/Views/PDFReaderView.swift       (Document agent)
Sources/lectern-probe/ProbeContext.swift        (Document agent) func contextProbeCommands() -> [ProbeCommand]
                                                        context-build, pdf-info, verify-citations, locate
Sources/Lectern/Views/ChatPaneView.swift        (Chat UI agent)
Sources/Lectern/Views/ChatHeaderView.swift      (Chat UI agent)
Sources/Lectern/Views/AuthBannerView.swift      (Chat UI agent)
Sources/Lectern/Views/TranscriptWebView.swift   (Chat UI agent)
Sources/Lectern/Resources/web/chat.{html,css,js}(Chat UI agent; vendor/ already holds marked + KaTeX)
Sources/Lectern/App/*                           (App agent) LecternApp (+ AppDelegate, ReaderCommands),
                                                            ReaderWindows (ReaderWindowManager), AppServices,
                                                            SettingsStore, SessionStore, ConversationStack,
                                                            ChatModel, ChatMessage, HighlightStore
Sources/Lectern/Views/DocumentWindow.swift      (App agent)
Sources/Lectern/Views/ConversationStackView.swift (App agent) ConversationColumnController, ConversationPanel,
                                                            title bar, New Conversation bar, ConversationActions
Sources/Lectern/Views/SettingsView.swift        (App agent)
scripts/build-app.sh, scripts/package-release.sh, VERSION, README.md   (App agent)
```

Agents only create/edit files they own. If a fixed file needs a change, report it instead.

## Shared contracts (app target)

These types are implemented by the App agent and consumed by the Chat UI agent. Names and
signatures are binding.

```swift
// Sources/Lectern/App/ChatMessage.swift
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, notice }
    enum Status: String, Codable { case streaming, thinking, done, interrupted, failed, waitingForLogin }
    let id: UUID
    var role: Role
    var provider: Provider
    var model: String?          // resolved model name for assistant messages
    var text: String            // markdown (assistant), plain (user/notice)
    var status: Status
    var errorText: String?      // set when status == .failed
    var pages: [Int]            // 1-based pages sent as context with this user message
    var createdAt: Date
    var citationChecks: [CitationCheck]?  // assistant answers; nil in older sessions and never written as null
}

// Sources/Lectern/App/ConversationStack.swift — one per document window (see "Conversations" below)
@MainActor @Observable final class ConversationStack {
    static let maxConversations = 4
    let document: ReaderDocument
    var readingState: ReadingState          // written by PDFReaderView; shared by every conversation
    var passageRequest: PassageRequest?     // PDFReaderView goes to the page (and the claim's passage), then sets nil
    private(set) var conversations: [ChatModel]   // top to bottom, never empty
    private(set) var focusedID: UUID?
    var focused: ChatModel? { get }         // focusedID's conversation, else the first
    var canAddConversation: Bool { get }    // < maxConversations
    var canCloseConversation: Bool { get }  // > 1
    let isSecondaryWindow: Bool
    init(document:services:settings:sessionStore:secondary:titler:onConversationCreated:)  // restores the saved ones
    convenience init(document: ReaderDocument, services: AppServices)   // wires ConversationTitler + register
    @discardableResult func addConversation() -> ChatModel?   // at the bottom, focused, input focus; nil at the limit
    func closeConversation(_ id: UUID)      // detach (stack = nil), shut down, refocus the next one, save; not the last
    func canMoveConversation(_ id: UUID, by offset: Int) -> Bool
    func moveConversation(_ id: UUID, by offset: Int)   // Move Up (-1) / Move Down (+1); saves
    func focus(_ id: UUID)                  // not saved by itself (the next change saves it)
    func ask(_ action: SelectionAction, selection: String, pages: [Int])  // Ask Lectern → focused (expanded first)
    func goTo(page: Int, claim: String? = nil)  // sets passageRequest
    func shutdown()                         // window closed: every conversation shuts down, one save at the end
    func persist()                          // all conversations, in order; never from a secondary window
}

// Sources/Lectern/App/ChatModel.swift — one per conversation (panel)
@MainActor @Observable final class ChatModel {
    typealias Titler = @MainActor (_ question: String, _ answer: String, _ provider: Provider) async -> String?
    init(stack: ConversationStack, stored: StoredConversation? = nil, services: [Provider: ProviderService],
         settings: SettingsStore, secondary: Bool = false, titler: Titler? = nil)
    let id: UUID
    let document: ReaderDocument
    weak var stack: ConversationStack?      // nil once closed (a late save or context build then does nothing)
    var readingState: ReadingState { get }  // the stack's
    private(set) var title: String          // automatic until renamed; StoredConversation.defaultTitle at first
    private(set) var titleIsCustom: Bool
    var isCollapsed: Bool                   // saved on change
    var isFocused: Bool { get }
    var isAnyBusy: Bool { get }             // a turn runs for either provider
    var hasUserMessages: Bool { get }
    var stored: StoredConversation { get }  // what the stack saves
    func rename(_ title: String)            // trimmed, one line, ≤ 80 chars; empty → back to the automatic title
    func clearConversation()                // panel menu "New Chat": both providers start over; a custom title stays
    func takeFocus()                        // stack.focus(id): input focus, a click in the panel, a preset
    func requestInputFocus()                // new conversation: its input takes the keyboard focus

    var provider: Provider                  // switching keeps both conversations
    var settings: TurnSettings              // for `provider`; setter persists as the new default
    var models: [ModelOption] { get }       // for `provider`
    var selectedModel: ModelOption? { get } // option matching settings.model (or the default)
    var effortChoices: [String] { get }     // efforts for selectedModel ("" = Default is added by the UI)
    var authState: AuthState { get }        // for `provider`
    var quota: QuotaSnapshot? { get }       // for `provider`
    var installIssue: String? { get }       // for `provider`
    var resolvedModel: String? { get }      // last model reported by the backend for `provider`

    var messages: [ChatMessage] { get }     // all providers, in order; each tagged with its provider
    var isBusy: Bool { get }                // a turn is running for `provider`
    var draft: String
    var attachPageImage: Bool
    var includeWholeDocument: Bool
    var creditsGuardActive: Bool { get }    // true while a send is blocked by the quota guard
    var creditsGuardReason: CreditsGuardReason? { get }  // .exhausted | .unknown (usage couldn't be read)
    var lastWarning: String? { get }

    func send()                             // sends `draft`
    func stop()
    func newChat()                          // resets the current provider's conversation
    func startLogin(_ method: LoginMethod)
    func cancelLogin()
    func recheckAuth()                      // re-reads the login status; never logs in
    func confirmSpendCredits()              // user override for the quota guard; sends the blocked message
    func cancelBlockedSend()                // question goes back into the input, ahead of any new text
    func goTo(page: Int, claim: String? = nil)  // 1-based, from [p. N] links → stack.goTo; past the end → lastWarning
    func ask(_ action: SelectionAction, selection: String, pages: [Int])  // "Ask Lectern"; pages 1-based;
                                            // the selection is captured for this question only
    func runPreset(_ preset: ChatPreset)    // ignored while busy or held by the credits guard
}
```

Views:

```swift
struct ChatPaneView: View { @Bindable var model: ChatModel }   // one conversation, under its title bar
final class ConversationColumnController: NSViewController     // the chat pane: the stack's panels
struct PDFReaderView: NSViewRepresentable {
    let document: ReaderDocument
    let controller: ReaderController
    @Binding var readingState: ReadingState         // bound to the ConversationStack
    @Binding var passageRequest: PassageRequest?
}
struct TranscriptWebView: NSViewRepresentable {
    let messages: [ChatMessage]
    let documentTitle: String               // default name for a saved table: "<title> - table.csv"
    let onGoTo: (Int, String?) -> Void      // 1-based page, claim (the sentence around the citation)
}
// chat.js → Swift messages: goto {page, claim} · copy · open · saveCSV {csv, name} · resync
```

Citation checks: when an answer completes, ChatModel runs `CitationVerifier.verify` off the main
thread and stores the result in `citationChecks` (only if the text didn't change meanwhile). chat.js
numbers each bracketed citation in order (`[p. 2, 4]` is one), skipping code and link text the same
way the verifier does, and puts ✓ (verified) or ⚠ (partial, notFound, pageMissing) after it. When the
count or the lowest page at any ordinal differs, that message shows no badges. Finished tables get
"Copy CSV" / "Save CSV…" (RFC 4180, UTF-8 with BOM, a leading `'` before formula-like cells).
Presets: a menu next to the image and whole-document toggles, grouped General / Finance
(`ChatPreset.all`), disabled while busy, while the credits guard holds a question, or when not signed in.

## Service constructors (LecternCore)

```swift
public enum CodexHomeMode: String, Codable, CaseIterable, Sendable { case isolated, shared }   // Codex/CodexService.swift

@MainActor @Observable public final class ClaudeService: ProviderService {
    public init(pathOverride: @escaping @MainActor () -> String?)
    public var binaryPath: String? { get }          // detected/used path, for Settings
    public var accountEmail: String? { get }
    public var planName: String? { get }            // e.g. "Max"
    public var loginMethod: LoginMethod? { get }    // .terminal while a login runs (.browser is unused)
    public func verifyConnection() async -> Bool    // tiny real call; `auth status` can lie
    public func relocateBinary()                    // re-run discovery after the override changes
    public func oneShot(prompt: String, model: String, timeout: TimeInterval = 20) async -> String?
                                                    // result text; nil on is_error, timeout or bad output;
                                                    // never markAuthExpired
}

@MainActor @Observable public final class CodexService: ProviderService {
    public init(pathOverride: @escaping @MainActor () -> String?,
                homeMode: @escaping @MainActor () -> CodexHomeMode)
    public var binaryPath: String? { get }
    public var binaryVersion: String? { get }       // from `codex --version`
    public var accountEmail: String? { get }
    public var planName: String? { get }            // e.g. "pro"
    public var activeLoginId: String? { get }       // sign-in started by startLogin, not yet completed
    public var urlOpener: @MainActor (URL) -> Void  // opens sign-in pages; default NSWorkspace (probes replace it)
    public func signOut()                           // account/logout; isolated mode only
    public func restart()                           // after path/home-mode changes: kill app-server, forget the
                                                    // account; re-init lazily (caller then calls refreshAuth/reloadModels)
    public func stop()                              // app quit: terminate the app-server
    public func refresh() async                     // account + quota + models; returns when done
    public func creditsCheck(maxAge: TimeInterval = 300) -> CreditsCheck  // .notApplicable | .available |
                                                    // .exhausted | .needsRefresh (unknown or older than maxAge)
    public func refreshQuota() async                // account/rateLimits/read
    public func oneShot(prompt: String, timeout: TimeInterval = 20) async -> String?  // see "Conversation titles"
    public static func oneShotModel(in models: [ModelOption]) -> ModelOption?
                                                    // first id/displayName containing "luna" or "mini", else default
}

public enum ConversationTitler {                    // Shared/ConversationTitler.swift
    /// ~5 words / 40 chars (18 for CJK) from the first question; drops an "Explain:"-style label before a
    /// quotation, quotes and trailing punctuation (a closing "?" stays); "New conversation" when empty.
    public static func fallbackTitle(question: String) -> String
    /// 2–6 word title in the question's language; nil when signed out, on any failure, after ~20 s, or
    /// (Codex) when the purchased-credits check doesn't return .available / .notApplicable.
    @MainActor public static func title(question: String, answer: String, provider: Provider,
                                        claude: ClaudeService, codex: CodexService) async -> String?
}
```

CodexService starts the app-server and refreshes account/quota/models from `init`. An account read
that finds an account reads the rate limits before it publishes `.signedIn`, so auth observers (which
send waiting questions) never see a sign-in with an unknown quota. A sign-in owns
`authState` from `startLogin` until `account/login/completed` (or cancel/timeout), including while the
`account/login/start` reply is pending; account reads in that window don't overwrite it.

`makeSession(conversationId:)`: a non-nil id means "this conversation completed at least one turn
before; resume it". The app persists ids only after a turn completes.

## Document layer (LecternCore/Document)

```swift
public final class ReaderDocument: @unchecked Sendable {
    public init?(data: Data, fileURL: URL?, title: String)
    public let pdf: PDFDocument             // for the UI (main thread only)
    public var isLocked: Bool               // encrypted and not unlocked yet (main thread)
    @MainActor public func unlock(password: String) async -> Bool  // both copies; drops caches
    public let title: String
    public let fileURL: URL?
    public let contentHash: String          // SHA-256 hex of the file bytes (CryptoKit)
    public var pageCount: Int
    public func pageText(_ index: Int) async -> String          // 0-based; cached; extracted on a private
                                                                 // serial queue from a SEPARATE PDFDocument
    public func outline() async -> [(title: String, page: Int)] // 0-based pages, capped ~200 entries
    public func renderPagePNG(_ index: Int, maxLongEdge: CGFloat = 1600) async -> URL?  // AppPaths.cache
    public func searchPages(_ query: String, topK: Int) async -> [Int]  // keyword scoring over page texts
    public func pageTextSource(_ index: Int) async -> TextSource  // .pdfText | .ocr | .none
    public func isTableHeavy(_ index: Int) async -> Bool         // TableDetector: mostly a table
}

public enum CitationVerifier {      // checks each [p. N] citation's numbers and "quoted phrases" on the cited pages
    public static func verify(answer: String, in document: ReaderDocument) async -> [CitationCheck]
}
public enum PassageLocator {        // 0-based page; a range in the raw PDFPage.string (the UI page's string,
                                    // for page.selection(for:)); nil when nothing fits or the page was OCR'd
    public static func locate(claim: String, page: Int, in document: ReaderDocument) async -> NSRange?
}

public struct ReadingState: Equatable, Sendable {
    public var currentPage: Int             // 0-based
    public var visiblePages: [Int]          // 0-based
    public var selectionText: String?
    public var selectionPages: [Int]        // 0-based
}

public struct ContextOptions: Sendable {
    public var neighborRadius: Int = 1
    public var attachPageImage: Bool = false
    public var wholeDocument: Bool = false
    public var tokenBudget: Int             // defaultTokenBudget(for:model:): Claude 300_000 (Haiku, a
                                            // 200K-context model, 140_000), Codex 150_000 (chars/4 estimate)
}

public struct BuiltPrompt: Sendable {
    public var request: TurnRequest
    public var pagesIncluded: [Int]         // 0-based
    public var estimatedTokens: Int
}

/// One per (document, provider conversation). Tracks which pages were already sent so each page's
/// text goes over the wire once per conversation.
public final class ContextBuilder {
    public init(document: ReaderDocument)
    public func reset()                     // new conversation: forget sentPages and outlineSent
    public func build(question: String, state: ReadingState, options: ContextOptions) async -> BuiltPrompt
}
```

Envelope (pages are 1-based in text):

```
<reading_context>
document: "<title>" · <N> pages · current page 12 · visible 12–13
selection (p. 12): "…"
outline: (first turn only) 1. Intro — p. 1 · 2. Results — p. 7 …
</reading_context>
<pages>
=== Page 11 ===
…
=== Page 12 ===
(page 12 was provided earlier)     ← for pages already sent in this conversation
</pages>
Question: …
```

- Always: title, page count, current page, visible pages, selection with pages, text of current page ±radius.
- Selection pages add their text, but a selection spanning more than 5 pages (Select All, a long drag)
  adds only its first and last pages, and selection pages furthest from the current page are dropped
  while the unsent text exceeds `tokenBudget`; the context line says so.
- A PDF that is still locked gets a note that no text or images are available; renders are never
  written while locked (the app asks for the password before showing the reader).
- Auto-attach the current page image (once per conversation) when its text is under ~400 chars
  (slides, charts), when it was OCR'd, or when it is mostly a table; the context line gives the reason.
- OCR (Vision, `.accurate`, automatic language detection): a page whose PDF text has under 25
  non-space characters and whose render (from the extraction copy, never the UI copy) has ink. The OCR
  text replaces the PDF text only when longer; its page block starts with "(text recognized by OCR)".
  Cached in memory and in `AppPaths.cache/<hash>/ocr/v1-page-N.txt`; `pageText`, `searchPages` and
  whole-document mode use it.
- `wholeDocument`: all pages if the estimate fits `tokenBudget`, else `searchPages(question, 12)` plus
  current ±radius; say in the envelope which mode was used.
- PDFKit flattens tables; the image toggle is the remedy.

## Claude backend (verified live, CLI 2.1.290)

Long-lived process per document conversation, spawned lazily on first send:

```
<claude> -p --verbose --input-format stream-json --output-format stream-json
  --include-partial-messages --safe-mode --tools "" --strict-mcp-config
  --permission-mode dontAsk --system-prompt <ReaderPrompt.system>
  [--model <m>] [--effort <low|medium|high|xhigh|max>]
  (--session-id <new uuid> | --resume <uuid>)
cwd = AppPaths.claudeCwd, env = CleanEnvironment.make()
```

- **Never `--bare`** (ignores the subscription login). `--safe-mode` keeps OAuth while skipping the
  user's CLAUDE.md, plugins, hooks and MCP. `--tools ""` → 0 tools (verified).
- `--verbose` is mandatory with stream-json output.
- Model aliases: `opus`, `sonnet`, `haiku`, `fable`, or full ids; "" = user's default (currently
  claude-opus-5-5). `haiku` resolved to claude-haiku-4-5-20251001. Efforts: low, medium, high, xhigh, max.
- Changing model/effort: terminate and respawn with `--resume <uuid>` + new flags on the next send
  (~0.5 s). Idle > 60 min: terminate; respawn with `--resume` on next send.
- `--resume` keeps the same session id. Use `--session-id <uuid>` the first time; once a turn completed
  under that id, later spawns use `--resume`. If `--resume` fails (session not found), start fresh with a
  new uuid and tell the ContextBuilder to reset.
- Stdin message (one JSON per line):
  `{"type":"user","message":{"role":"user","content":[ {image blocks…}, {"type":"text","text":"…"} ]},"parent_tool_use_id":null,"session_id":""}`
  Image block (verified): `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}`
- Stdout events:
  - `system/init` (re-emitted each turn): `model`, `apiKeySource`. If apiKeySource != "none", emit
    `.warning("Claude is billing an API key, not your subscription")`. Emit `.sessionReady(model:)`.
  - `stream_event` with `event.delta.type == "text_delta"` → `.textDelta(event.delta.text)`;
    `thinking_delta` → `.thinking` (once).
  - `system/api_retry` with `error_status == 401` → remember auth failure.
  - `assistant` with `message.model == "<synthetic>"` or `error == "authentication_failed"` → auth failure text.
  - `rate_limit_event`: `rate_limit_info.unifiedWindows.{five_hour,seven_day}.{utilization (0–1), resetsAt (unix s)}`,
    `rate_limit_info.status` ("allowed" = fine) → `.quota(...)` and store on the service.
  - `result` (end of turn): `is_error`, `subtype`, `result` (final text), `api_error_status`, `usage`,
    `duration_ms`, `session_id`. **`subtype` can be "success" even when `is_error` is true (401).**
    Auth failure when api_error_status == 401 or the assistant message had `error == "authentication_failed"`;
    then an interrupt → `.interrupted`; then an earlier 401 api_retry counts only when the result has no
    api_error_status (the CLI recovers from some 401s, so a later 429/500/529 wins); usage limit; finally
    result text matching /authenticat|log ?in/i. Auth → `.failed(.authRequired(...))` and
    `service.markAuthExpired(...)`.
    After an interrupt: `subtype == "error_during_execution"`, `is_error == true` → `.interrupted`.
- Interrupt (verified; process stays alive for the next turn):
  `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}` →
  `control_response` with `response.subtype == "success"`, then the turn's `result`.
- Process exit during a turn → `.failed(.processExited(stderr tail))`; next send respawns with `--resume`.
- Verified error shapes: `--resume <unknown>` → `result` with subtype `error_during_execution` (same as an
  interrupt) and `errors: ["No conversation found with session ID: …"]`, exit 1 → the session takes a new
  uuid and ends the turn with `.conversationReset` without resending (the prompt says pages were
  "provided earlier"); the app rebuilds the prompt and sends it as a new turn. `--session-id <existing>` →
  stderr `Error: Session ID … is already in use.`, exit 1, no stdout → retry once with `--resume`.
  The interrupt result carries `errors: ["[ede_diagnostic] …"]`; its control_response has `{still_queued: []}`.

Auth (ClaudeService):
- Status: `claude auth status --json` → `{loggedIn, authMethod, email, subscriptionType}`. **It can
  say loggedIn while the token is revoked**, so a 401 during a turn always wins (markAuthExpired).
- **The UI offers only `.terminal` for Claude.** Anthropic's policy says third-party developers must
  not offer Claude.ai login in their own apps; users may sign in to the unmodified Claude Code binary
  themselves. The `.browser` code path below is kept in ClaudeService but no view calls it.
- In-app login (`.browser`, unused): spawn `claude auth login --claudeai` (clean env, stdin pipe kept
  open and never written). It opens the browser itself and prints
  `If the browser didn't open, visit: <url>` and `Paste code here if prompted >`, then
  `Login successful.` and exits 0 when the browser flow completes. The printed url is the manual-code
  one (`redirect_uri` platform.claude.com/oauth/code/callback, ends on a code-paste page), so it is NOT
  shown (the UI used to offer "Use Terminal instead" here). 5-minute timeout; cancel = terminate. Never read or
  relay codes/tokens. A login that fails leaves `.signedOut(reason:)` when the state before it was
  signed out, else `.failed(message)` (state unknown; the banner offers "Check again" first).
- `.terminal` ("Log in in Terminal", the only Claude login the UI offers): write
  `AppPaths.appSupport/login-claude.command` (`#!/bin/zsh`, runs the absolute claude path with
  `auth login --claudeai` under `env -i` + the CleanEnvironment values + TERM, no `exec`), chmod 755,
  `NSWorkspace.shared.open` it (LecternCore may `import AppKit`), then poll `auth status` every 3 s
  for up to 5 min; also offer `verifyConnection()`.
  The script also writes its exit status to `AppPaths.appSupport/login-claude.status`: after a 401,
  `auth status` says loggedIn throughout, so only that marker can confirm a re-login.
- `verifyConnection() async -> Bool`: one-shot `claude -p "Reply with OK" --model haiku --tools ""
  --safe-mode --no-session-persistence --output-format json` (stdin /dev/null); success = `is_error == false`.
- `oneShot(prompt:model:timeout:)`: the same command shape (`claude -p <prompt> --model <m> --tools ""
  --safe-mode --no-session-persistence --output-format json`, clean env, stdin /dev/null, cwd
  `AppPaths.claudeCwd`) → `result` text, nil on `is_error`/timeout/unreadable output. It never calls
  `markAuthExpired` (titles are best-effort; a real turn's 401 still wins). The prompt goes after `-p`, so
  it must not start with "-" (the title prompt starts with "Write").
- After any successful login, existing ClaudeSessions must respawn their process before the next turn.
- Never call `claude auth logout` (it would log out the user's terminal Claude Code too).

## Codex backend (verified live, bundled codex-cli 0.159.2)

One `app-server` process for the whole app (owned by CodexService), one thread per document.
For exact message shapes, generate the protocol bindings from the codex binary you run (they are
not committed; `docs/codex-app-server-*-ts/` is git-ignored):

```sh
# the copy bundled in ChatGPT.app, or `codex` from `npm i -g @openai/codex`
/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex app-server generate-ts --out docs/codex-app-server-ts
```

Then read `ClientRequest.ts`, `ServerNotification.ts`, `ServerRequest.ts` and `v2/*`. The notes below
were verified against 0.159.2.

- Binary: `BinaryLocator.codex(override:)` (ChatGPT.app's bundled copy auto-updates; resolve the
  path on every spawn).
- Codex home mode (Settings, default **isolated**):
  - isolated: env `CODEX_HOME = AppPaths.codexHome`; the service writes `codex-home/config.toml` if
    missing (or if it starts with the `# Managed by Lectern` marker) with:
    ```
    # Managed by Lectern
    model = "gpt-6.1-sol"
    model_reasoning_effort = "low"
    service_tier = "default"
    notify = []
    [analytics]
    enabled = false
    ```
    Verified: no plugin MCP servers start, thread/start takes ~70 ms. Needs its own one-time sign-in.
  - shared: no CODEX_HOME (uses ~/.codex and its login); launch args add
    `-c notify=[] -c service_tier="default"`. The user's plugins/MCP servers still load
    (`disabledPluginIds` "does not yet filter plugin capabilities").
- Launch: `<codex> app-server` (+ shared-mode `-c` args), cwd = AppPaths.codexCwd, keepStdinOpen.
- Wire: JSONL; requests `{"id":N,"method":…,"params":…}` (no "jsonrpc" field needed); responses
  `{"id":N,"result":…}` / `{"id":N,"error":{code,message}}`; notifications `{"method":…,"params":…}`;
  server→client requests have both `id` and `method` and MUST be answered (echo the id exactly).
- Handshake: `initialize {clientInfo:{name:"lectern",title:"Lectern",version:"0.1"}, capabilities:null}`
  → then notification `initialized`.
- `account/read {}` → `{account: null | {type:"chatgpt", email, planType}, requiresOpenaiAuth}`.
  account null → signedOut("Sign in with ChatGPT to use it here").
- `model/list {}` → `data[]`: `id, displayName, description, isDefault, supportedReasoningEfforts[].reasoningEffort,
  defaultReasoningEffort, serviceTiers[].id` (currently ["priority"]). Works without auth.
  Live list: gpt-6.1-sol (default, efforts low…ultra, default low), gpt-6-astra, gpt-6-sol, gpt-6-luna,
  gpt-5.6-sol/terra/luna. Never hardcode; gpt-5.5 retires 2026-10-14.
- `account/rateLimits/read {}` → `{ordinaryUsageAllowed, rateLimits:{primary:{usedPercent,windowDurationMins,resetsAt},
  secondary, credits:{hasCredits,unlimited,balance}, rateLimitReachedType, spendControlReached}}`
  (error -32600 when signed out; only that error clears the snapshot, other errors keep it).
  Notification `account/rateLimits/updated {rateLimits}` is sparse: merge.
  `includedUsageExhausted = ordinaryUsageAllowed == false || rateLimitReachedType != nil ||
  any window usedPercent >= 100`. `ordinaryUsageAllowed == null` means unavailable ("must not infer
  recovery from percentages"): the credits guard treats it as unknown. Note text: "<balance> purchased credits — Lectern won't spend them
  unless you allow it". windowDurationMins 10080 → "Weekly", 300 → "5-hour".
- Login (as requested): `account/login/start {type:"chatgpt"}` → `{type:"chatgpt", loginId, authUrl}`
  (auth.openai.com, localhost:1455 callback handled by app-server). Open `authUrl` with NSWorkspace.
  Device code: `{type:"chatgptDeviceCode"}` → `{loginId, verificationUrl, userCode}`.
  Completion: notification `account/login/completed {loginId, success, error}`; then re-read account,
  rate limits, models. Cancel: `account/login/cancel {loginId}` (verified). Also handle
  `account/updated`. NEVER use `chatgptAuthTokens` or `apiKey` login types.
- Sign out (isolated mode only, Settings): `account/logout`.
- Thread: `thread/start {model, serviceTier:"default"|<fastTierId>, cwd: codexCwd, sandbox:"read-only",
  approvalPolicy:"never", ephemeral:false, developerInstructions: ReaderPrompt.system}` →
  `{thread:{id}, model, serviceTier, reasoningEffort}`. Reopen: `thread/resume {threadId, model,
  serviceTier, cwd, sandbox, approvalPolicy, developerInstructions}`; on error forget the thread and end
  the turn with `.conversationReset` (unsent); the app resets the ContextBuilder and resends a rebuilt
  prompt, which starts a new thread. A reply that arrives after the session was shut down or reset is
  not subscribed to: the session posts `thread/unsubscribe` instead.
- Turn: `turn/start {threadId, input:[{type:"text",text,text_elements:[]}, {type:"localImage",path,detail:"high"}…],
  model, effort, serviceTier}` where serviceTier = fastTier ? model.fastTierId : "default". Always send
  model + effort + serviceTier explicitly (a user's ~/.codex config may set another model, an "ultra"
  effort or the priority tier; verified that explicit "default" overrides). → `{turn:{id,status}}`. When model and effort
  can't both be resolved (model/list unavailable and no explicit choice) the turn fails before
  thread/start instead of going out without them.
- Streaming notifications (route by threadId): `item/agentMessage/delta {threadId,turnId,itemId,delta}`
  → `.textDelta`; `item/started` with item.type "reasoning" → `.thinking`; `item/completed` with
  item.type "agentMessage" → authoritative text (a turn may have several; join with blank lines);
  `turn/completed {threadId, turn:{id,status:"completed"|"interrupted"|"failed",error}}` → terminal event;
  `error {error:{message,codexErrorInfo},willRetry,threadId,turnId}` → keep for the terminal event when
  willRetry is false; `thread/tokenUsage/updated` → usage (`tokenUsage.last`).
  codexErrorInfo "unauthorized" → `.authRequired` (+ markAuthExpired); "usageLimitExceeded" → `.usageLimit`.
  Strip `ReaderPrompt.stripDirectives` from final text.
- Interrupt: `turn/interrupt {threadId, turnId}` → turn/completed with status "interrupted".
- Server requests: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
  `execCommandApproval`, `applyPatchApproval` → respond with the schema's decline value; everything
  else → error `{code:-32601,message:"Not supported by Lectern"}`.
- Process exit: fail in-flight turns with `.processExited`, restart lazily (backoff), threads resume.
- `oneShot(prompt:timeout:)` (titles): nil when Codex isn't installed or `preflight()` fails (signed out,
  sign-in running); `creditsCheck()` (re-reading the quota when `.needsRefresh`) must give `.available` or
  `.notApplicable` (never purchased credits, whatever protectCredits says). `thread/start {model:
  oneShotModel(in:), serviceTier:"default", cwd: codexCwd, sandbox:"read-only", approvalPolicy:"never",
  ephemeral:true}` → `turn/start {effort:"low" (else the model's first effort), serviceTier:"default"}` →
  agent messages joined at `turn/completed`. Timeout → `turn/interrupt`; always removes its listeners and
  posts `thread/unsubscribe`; never marks the login expired. Verified live: gpt-6-luna, ~2.4 s.
- Verified quirks: a turn sent while signed out is not refused; the server retries 401s for ~15 s and
  then fails with `codexErrorInfo {httpConnectionFailed:{httpStatusCode:401}}`, so Lectern checks sign-in
  before sending and treats any 401 as `.authRequired`. `thread/resume` of a thread that never completed
  a turn fails with -32600 "no rollout found". Right after `thread/resume` the server replays a
  `thread/tokenUsage/updated` carrying the previous turn's id: take the turn id only from `turn/started`
  or the `turn/start` reply. In shared mode the `thread/start` reply reports `reasoningEffort` from
  ~/.codex; ThreadStartParams has no effort field, so the per-turn effort is what applies. The app-server
  exits by itself (status 0) when its stdin closes.

## App layer

- **Lectern never writes to a PDF.** There is no NSDocument, FileDocument or DocumentGroup: an
  NSDocument counted chat typing as edits ("— Edited") and autosaved on close, rewriting the user's
  file. Nothing in the app opens a document path for writing.
- `@main LecternApp`: only `Settings { SettingsView() }` plus `.commands { ReaderCommands }`, and an
  `@NSApplicationDelegateAdaptor` AppDelegate.
- `ReaderWindowManager` (App/ReaderWindows.swift, @MainActor @Observable singleton) owns reader windows:
  - `open(_ urls: [URL])` / `open(_ url:)`. Identity = `standardizedFileURL.resolvingSymlinksInPath()`
    path (so `/tmp/x.pdf`, `/private/tmp/x.pdf` and symlinks match), falling back to the file's
    `fileResourceIdentifier` (hard links, letter case). An already-open file only comes to the front
    (deminiaturized, `makeKeyAndOrderFront`).
  - Bytes: `Data(contentsOf:options: .mappedIfSafe)` (read-only map); a read error → NSAlert, no window.
  - Window: AppKit `NSWindow` (titled/closable/miniaturizable/resizable), title = file name with
    extension, `representedURL` = file (proxy icon), content 1400×900 (clamped to the screen),
    centered first and then cascaded from the key reader window (or the previous one in the same batch),
    `isReleasedWhenClosed = false`, not restorable, `tabbingMode .automatic` (system tab preference).
    Content = `NSHostingController(rootView: DocumentWindow)` with `sizingOptions [.minSize]` and no
    scene bridging (the window owns its title).
  - `ReaderWindowController` (NSWindowDelegate, one per window) receives the ConversationStack from
    DocumentWindow (`onConversationsReady`) and, in `windowWillClose`, shuts it down exactly once, drops
    the window from the registry, clears the delegate and then (next main-actor turn) the content view
    controller, which frees the SwiftUI tree, the conversations and the mapped bytes. A stack created
    after its window closed (a late unlock) is shut down immediately. `ReaderWindowManager.activeConversations`
    is the key reader window's stack (File > New Conversation / Close Conversation).
  - Recent files: `recentFiles` = last 10 canonical paths in UserDefaults key `recentFiles`, most recent
    first, de-duplicated, missing files pruned (at launch, on each open, on app activation, on a failed
    open). Each open also calls `NSDocumentController.shared.noteNewRecentDocumentURL` (Dock menu);
    Clear Menu clears both.
  - Open panel: one NSOpenPanel at a time (`allowedContentTypes [.pdf]`, multiple selection), non-modal.
- AppDelegate: `application(_:open:)` → `open` (PDFs only); `applicationShouldOpenUntitledFile` → false;
  0.5 s after launch, with no reader window, Open panel or other window, the Open panel is shown (like
  Preview; the delay lets Finder's open events arrive first); `applicationShouldHandleReopen` → Open
  panel when there are no windows at all (minimized reader windows are left to AppKit, which restores
  one); `applicationShouldTerminateAfterLastWindowClosed` → false; `applicationWillTerminate` →
  `AppServices.shutdown()`.
- Menus (`ReaderCommands`): `.newItem` → "Open…" (⌘O) and "Open Recent" (recent files, a folder suffix
  when names clash, Clear Menu); `.saveItem` → only "Close" (⌘W, `keyWindow.performClose`), since
  replacing that group also removes the standard Close.
- DocumentWindow(data:fileURL:reader:onConversationsReady:) = the reader split (see Viewer) once the
  ReaderDocument loads; an unreadable PDF shows a ContentUnavailableView in the window. Every state
  (loading, password, can't-open, reader) has an unbounded max size (`maxWidth/maxHeight: .infinity`;
  password and can't-open also min 480×320): with a bounded max the hosting view shrinks the window to
  the view's ideal size, so a locked or unreadable PDF would open at 480×352 instead of 1400×900.
- Info.plist (scripts/build-app.sh) declares com.adobe.pdf as a Viewer document type, rank Alternate,
  with no NSDocumentClass. CFBundleShortVersionString and CFBundleVersion come from the `VERSION`
  file. If `Sources/Lectern/Resources/AppIcon.icns` exists it is copied into Contents/Resources and
  `CFBundleIconFile = AppIcon` is set. LICENSE and THIRD_PARTY_NOTICES.md are copied into
  Contents/Resources.
- Release: `scripts/package-release.sh` runs build-app.sh, checks the binary is arm64-only and the
  ad-hoc signature verifies, then `ditto -c -k --norsrc --noextattr --keepParent` (no `__MACOSX/`
  entries; the script fails if any appear) → `dist/Lectern-<version>-arm64.zip` plus a `.sha256`.
  Not notarized (no Developer ID). build-app.sh copies resources with `cp -X` and runs `xattr -cr` on
  the bundle before signing (no quarantine or provenance attributes in it). Before replacing a
  bundle it quits only the Lectern process running from that bundle (by pid, via
  `NSRunningApplication.terminate`).
- Web resources: `Sources/Lectern/Resources` is excluded from the SwiftPM target (no resource bundle,
  no `Bundle.module`): SwiftPM's generated accessor embeds the absolute build path (the builder's home
  folder) in the binary, and it doesn't search Contents/Resources of an assembled .app anyway.
  build-app.sh copies `web/` to Contents/Resources/web and the app loads
  `Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "web")`. Unbundled
  `swift run Lectern` falls back to the source tree, found by walking up from the executable.
- `AppServices` (@MainActor singleton): SettingsStore, ClaudeService, CodexService, SessionStore.
- SettingsStore (UserDefaults): per-provider default TurnSettings (Claude: model "", effort "";
  Codex: model = catalog default, effort = its default, fastTier false), protectCredits (true),
  codexHomeMode ("isolated"), claudePathOverride, codexPathOverride, neighborRadius (1), lastProvider,
  aiConversationTitles (true).
- SessionStore: `AppPaths.sessions/<contentHash>.json`, version 2 =
  `{version: 2, conversations: [StoredConversation], focusedID, viewer}` with StoredConversation =
  `{id, title, titleIsCustom, provider?, claudeSessionId?, codexThreadId?, messages, collapsed}`, top to
  bottom. Conversation ids saved only after a turn completes; saved after each turn and each stack change.
  A reopened document starts with fresh ContextBuilders (all context re-sent once). Decoding is lenient
  (unknown provider, missing fields). Version 1 files (`{claudeSessionId, codexThreadId, messages,
  viewer}`) load as one conversation titled `fallbackTitle(first question)` ("Conversation" without one);
  a v1 file with only viewer state loads with no conversations; the next write is version 2 (no v1 keys).
  Lectern 0.1.0 reads a v2 file as an empty chat, and its next save (even `saveViewer`) can drop the
  conversations: a downgrade loses them (GUIDE says so).
- `.conversationReset` from a session → reset that provider's ContextBuilder; if it ended a sent turn,
  drop the placeholder reply and re-queue the question first (its prompt is rebuilt with full context).
- `.interrupted` with no answer text → `ContextBuilder.discard` that prompt (it may never have been
  delivered). Stop timeout → the replacement session resumes `conversationIds[p]`, else reset the builder.
- Two windows on the same bytes (same contentHash; a copy at another path, since the same file only
  focuses its window): the second (`ConversationStack.isSecondaryWindow`) shows the saved conversations
  but starts new backend conversations and never saves (a notice in its focused conversation says so).
  `AppServices.isOpen(contentHash:)` ignores shut-down models, so once the first window closes, the next
  window on those bytes is the primary one again. `ChatModel.shutdown()` is idempotent (a later `send()`
  re-arms it).
- Encrypted PDFs: DocumentWindow asks for the password (SecureField) and calls `unlock(password:)`
  before creating the reader; PDFView's own prompt would unlock only the UI copy.
- Banner: `.signedOut` → Claude: "Log in in Terminal" + "Check again" (for a login done in the
  user's own terminal); ChatGPT: "Sign in with ChatGPT" + "Use a device code". `.failed` → "Check
  again" (recheckAuth) first, login buttons secondary. Codex: a cancelled sign-in whose previous state was not
  signedIn/signedOut re-reads the account instead of declaring signed out.
- ChatModel send flow:
  1. draft empty or busy → ignore. installIssue → notice.
  2. Auth not signedIn → append user message with status `.waitingForLogin`; the banner offers login;
     when the provider's auth observer reports `.signedIn`, send it automatically.
  3. Codex quota guard (protectCredits), fail-closed via `CodexService.creditsCheck()`: `.exhausted` →
     creditsGuardActive = true (reason .exhausted), message waits for confirmSpendCredits()/
     cancelBlockedSend(); `.needsRefresh` (no snapshot, read failed, ordinaryUsageAllowed null, older than
     5 min, or exhausted with a window whose resetsAt passed) → `refreshQuota()` first, then decide once
     more, and a quota still unknown blocks with reason .unknown. Never sends on a guess.
  4. ContextBuilder (per provider) builds the prompt; session.send(request, settings).
  5. Events update the assistant message; `.failed(.authRequired)` → message status
     `.waitingForLogin` (retry the same user message automatically after login).
- Settings window tabs: **Accounts** (per provider: status, account; Claude: Log in in Terminal /
  Verify connection; ChatGPT: Sign in with ChatGPT / device code / Sign out (isolated only); quota), **Models** (defaults,
  fast tier toggle with "uses ~2.5× your included usage", protect-credits toggle), **Advanced**
  (binary path overrides with detected path shown, Codex home mode, context radius, Conversations: "AI
  conversation titles").

## Conversations (stacked chat panels)

Each document window has a `ConversationStack` of 1–4 conversations (`ChatModel`s), shown top to bottom
in the chat pane. Each conversation has its own provider choice, Claude session, Codex thread, context
builders, messages, title and collapsed state; the stack owns the shared reading state, citation
jumps, the focus and the saved file.

- **Pane** (`ConversationColumnController`, Views/ConversationStackView.swift): an AppKit `NSSplitView`
  (`isVertical = false`, thin dividers) over a 30 pt "+ New Conversation" bar. Panels are
  `NSHostingView(ConversationPanel)` with no sizing or scene bridging; sync via
  `withObservationTracking` on `conversations` and each `isCollapsed`. Panels are reordered or hidden, not
  rebuilt, so a transcript's web view keeps its page. Expanded panels share the height in proportion to
  their last heights (divider drags and window resizes update the shares; reopening splits equally, as
  heights aren't saved). Collapsed = the 30 pt title bar only; a divider next to one doesn't move.
  Dividers stop at 200 pt per expanded panel (an equal share when the pane is shorter).
- **Focus**: a local left/right mouse-down monitor focuses the panel under the click; focusing the input
  or running a preset focuses its conversation. A new conversation takes focus and its input the
  keyboard focus. With more than one panel the focused title bar is tinted with the accent color.
  `focusedID` is saved with the next change. Ask Lectern (`ReaderController.onAsk` → `stack.ask`) goes to
  the focused conversation and expands it; ⌘. (Stop) is bound only in the focused panel.
- **Title bar**: chevron (collapse/expand), title (double-click → inline field: Return or clicking away
  commits, Esc cancels, empty → automatic title), a spinner while either provider answers, the provider
  name when collapsed, and a "⋯" menu: Rename…, New Chat (`clearConversation`, disabled while busy),
  Move Up, Move Down, Close Conversation. Close and New Chat ask first (NSAlert sheet) when the
  conversation has user messages; the last conversation can't be closed. The header's pencil "New chat"
  still resets only the selected provider's conversation.
- **Titles**: when the first answer of a conversation completes, the title becomes
  `ConversationTitler.fallbackTitle(question)` (the shown user message, e.g. "Explain: “…”") and is saved
  with the turn; then, if `aiConversationTitles` and not renamed, `ConversationTitler.title` runs off the
  critical path with the question and the answer's first 4000 characters (the titler caps both at 600)
  and replaces the title only if no rename or clear happened meanwhile (`titleGeneration`). Later answers
  never retitle. Claude uses `oneShot(model: "haiku")`; Codex `oneShot` (above). Prompt: "Write a 2–6
  word title for a conversation about this. Use the language of the question. Reply with the title only,
  no quotes or period." + question + answer. The reply is cleaned (first line, no markdown, "Title:"/"标题："
  labels, quotes or trailing punctuation, ≤ 48 chars). A nil title keeps the fallback (no retry).
  Clearing a custom name goes back to the last automatic title (or re-titles from the first exchange).
- **Menus**: File > New Conversation (⌥⌘N; shows the chat pane if hidden; disabled at 4) and File >
  Close Conversation (⌥⌘W; the focused conversation; disabled with one conversation or the chat
  hidden). Like the viewer menus they need a key reader window.
- **Probe**: `lectern-probe title --provider claude|codex [--home shared|isolated] --question Q --answer A`
  prints the fallback, auth, (Codex) credits check and model, then the title and its time (exit 0 title,
  1 nil, 2 usage). It also starts a Codex app-server for reads only.

## Rules

- Spawn only the unmodified CLIs; never read `~/.codex/auth.json` or the Keychain item
  `Claude Code-credentials`; never set CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY; never relay
  OAuth codes or tokens; logins only on explicit user action. Claude login is offered only as the
  Terminal flow (`claude auth login` in the user's own Terminal window).
- Never write to, replace or touch a user's PDF: read its bytes once (`.mappedIfSafe`), no NSDocument,
  no `write(to:)`/FileWrapper/FileHandle(forWriting…) on a document path.
- Every child gets `CleanEnvironment.make()`; track our own PIDs; never `pkill codex`.
- Child stdin pipes are `F_SETNOSIGPIPE`: a write racing a child's exit must fail, not kill the app.
- Every model/effort/tier choice is passed explicitly on every turn.

## Viewer (sidebar, toolbar, find, page navigation)

Preview-style viewing around the same PDFView. Files: `App/ReaderController.swift`,
`Views/ReaderToolbar.swift`, `Views/ReaderSidebar.swift`, `Views/DocumentWindow.swift`
(`ReaderSplitViewController`), plus `ReaderWindows.swift`, `LecternApp.swift` (menus) and
`SessionStore.swift` (`ViewerState`). Where the App layer section above differs, this section wins:
`DocumentWindow(data:fileURL:reader:onConversationsReady:)`, the split layout below, and File > Print….
Nothing here writes to the PDF (no save; highlights are in-memory annotations on the UI copy only).

- **ReaderController** (`@MainActor @Observable`, one per window, owned by `ReaderWindowController`)
  owns the `PDFView` (`ReaderPDFView`: Esc / resize / layout hooks) and the `PDFThumbnailView`.
  State: `pageCount`, `currentPageIndex`, `currentPageLabel`, `scaleFactor`, `zoomMode`
  (fitWidth | fitPage | custom), `displayMode`, `sidebarVisible`, `sidebarMode` (thumbnails |
  contents | highlights | searchResults), `chatVisible`, `hasOutline`, `canGoBack/Forward`, search state
  (`searchText`, `searchStatus`, `matches`, `currentMatchIndex`, `matchesTruncated`, `searchID`).
  Actions: `goToPage(_:)`, `goToPage(text:)`, next/previous/first/last, `goBack/goForward`,
  `zoomIn/zoomOut/actualSize/zoomToFit/zoomToWidth`, `setDisplayMode`, `toggleSidebar`,
  `showSidebar(_:)`, `toggleChat`, `focusSearch`, `searchTextChanged/searchSubmitted`,
  `findNext/findPrevious/useSelectionForFind/endSearch`, `focusPageField`, `printDocument`.
  `attach(_:store:persists:)` runs once the ConversationStack exists (after the password for encrypted PDFs);
  until then every viewer command is disabled.
- **PDFReaderView** shows `controller.pdfView` in a container and still writes `ReadingState` and
  honors `passageRequest` (once per id); it reports the current page to the controller, and a request
  goes through `controller.showPassage` → `goToPage`, so citation jumps are recorded for Back. With a
  claim, `PassageLocator` finds the passage; the view scrolls to it and flashes it with orange
  annotations for 2.5 s (never `currentSelection`, never saved).
- **Selection menu**: `ReaderPDFView.menu(for:)` puts "Ask Lectern ▸" (one item per
  `SelectionAction`, → `ConversationStack.ask` (the focused conversation) through `ReaderController.onAsk`;
  shows the chat pane),
  "Highlight ▸" (5 colors) and "Add Note…" above PDFKit's items; on a highlight: Add/Edit Note…,
  Change Color ▸, Remove Highlight.
- **Highlights** (`HighlightStore`, `@Observable`, one per contentHash shared by windows through a weak
  registry): `AppPaths.appSupport/highlights/<contentHash>.json` = records {id, page (0-based),
  location/length in `PDFPage.string`, text, color, note?, createdAt}, in page order; the file is
  deleted with the last highlight and never overwritten when it can't be read. Drawn as `.highlight`
  annotations, one per line, on the UI document only (so page images for the AI never have them); a
  range that no longer holds its text is found again by searching the page. The note sheet is an
  `NSAlert` with a text field. Sidebar mode Highlights lists them (click → go, recorded for Back;
  context menu Edit Note…, Change Color, Delete). Export Highlights… writes Markdown through
  `NSSavePanel` (never to the PDF's path).
- **Toolbar**: an AppKit `NSToolbar` (unified, not customizable; SwiftUI bridges nothing): sidebar
  toggle · page box + "of N" ("(n of N)" next to a page label) · zoom − / + · scale pull-down (percent,
  Actual Size, Zoom to Fit, Zoom to Width) · display-mode menu · match counter + search field · chat
  toggle. A new window's focus goes to the PDF, not the page box.
- **Layout**: `ReaderSplitViewController` (an `NSSplitViewController` in a representable): sidebar item
  (140–320 pt, starts at 180, collapsible), PDF (min 260, lowest holding priority, so it takes window
  resizing), chat (`ConversationColumnController`; min 340, starts at 440, collapsible). Hiding collapses a pane and keeps its views
  (the chat's web view isn't reloaded); dragging a divider closed updates the controller. SwiftUI's
  `HSplitView` was dropped: it can't set initial divider positions and rebuilt hidden panes.
- **Sidebar**: segmented picker at the top: Thumbnails, Table of Contents (only when the PDF has an
  outline), Search Results (only while searching). Thumbnails = `PDFThumbnailView` bound to the
  PDFView (lazy rendering; `allowsDragging = false`, which would reorder the in-memory document), one
  column sized to the sidebar, kept alive (hidden) under the other modes so it keeps following the
  current page. Table of Contents = `OutlineGroup` over `outlineRoot`, built on first show (≤ 20 000
  entries, depth ≤ 32), page labels on the right, the current entry (last one starting at or before
  the current page) in the accent color and its ancestors semibold; click → go. Search results =
  `NSTableView` (a SwiftUI `List` re-diffed every row each time results arrived and froze the window on
  searches with thousands of hits): rows "p. <label>" + ~60 characters of context with the match in
  bold, cells built only for visible rows; the selected row is the current match.
- **Find**: ⌘F focuses the search field from anywhere in the window (a menu key equivalent, so it also
  works from the chat input or transcript). Typing searches after 250 ms with
  `PDFDocument.beginFindString(_, [.caseInsensitive, .diacriticInsensitive])` and a delegate; matches are
  batched every 100 ms, capped at 5 000 ("5000+"). All matches are drawn with
  `pdfView.highlightedSelections` (yellow; the current one orange) and the view scrolls with
  `go(to:on:)`; `currentSelection` is never set, so search hits never become the chat's "selection".
  The first current match is the first one at or after the page the search started on. Counter
  "3 of 27" / "Searching…" / "No results". ⌘G / ⇧⌘G and Return / ⇧Return = next / previous, wrapping.
  Esc (in the field or the PDF) ends the search, removes the highlights, restores the sidebar mode
  from before the search and focuses the PDF. The first jump to a match records the pre-search place
  for Back.
- **Page box**: a page label (checked first when the PDF defines labels; case-insensitive) or a
  1-based number; Return jumps, anything else beeps and reverts (text stays selected); Esc reverts.
- **History**: Lectern's own Back/Forward stacks (≤ 100 places, page + point from
  `currentDestination`), pushed by page-box jumps, First/Last Page, table-of-contents clicks, citation
  jumps and the first jump to a search match; not by next/previous page or scrolling.
- **Zoom**: fitWidth = PDFView autoscaling in the continuous modes, fitPage = autoscaling in the
  non-continuous modes; the other two combinations are computed (and recomputed on resize). Zoom steps
  ×1.25 within 0.1–16. Setting `minScaleFactor`/`maxScaleFactor` turns `autoScales` off (verified), so
  the limits are set first. A pinch switches to custom.
- **Menus** (act on `ReaderWindowManager.activeReader`, the key reader window's controller, set from
  `windowDidBecomeKey/ResignKey`; disabled when no reader window is key or its PDF isn't showing yet;
  `@FocusedValue` isn't used, the windows aren't SwiftUI scenes):

  | Menu | Item | Key |
  |---|---|---|
  | File | New Conversation · Close Conversation (the focused one) — see Conversations | ⌥⌘N · ⌥⌘W |
  | File | Print… (the PDF via `PDFDocument.printOperation`, scaled down to fit; disabled if the PDF forbids printing) | ⌘P |
  | Edit > Find | Find… / Find Next / Find Previous / Use Selection for Find | ⌘F / ⌘G / ⇧⌘G / ⌘E |
  | File | Export Highlights… (disabled without highlights) | ⇧⌘E |
  | Edit | Ask Lectern ▸ · Highlight Selection · Add Note to Selection… (need a text selection) | – · ⌃⌘H · – |
  | View | Hide/Show Sidebar · Thumbnails · Table of Contents · Highlights | ⌥⌘1 · ⌥⌘2 · ⌥⌘3 · ⌥⌘4 |
  | View | Hide/Show Chat | ⌃⌘C |
  | View | Actual Size · Zoom to Fit · Zoom to Width · Zoom In · Zoom Out | ⌘0 · ⌘9 · – · ⌘+ (and ⌘=) · ⌘− |
  | View | Single Page / Single Page Continuous / Two Pages / Two Pages Continuous (checkmark) | – |
  | Go | Previous Page · Next Page · First Page · Last Page | ⌥⌘↑ · ⌥⌘↓ · ⌥⌘Home · ⌥⌘End |
  | Go | Back · Forward · Go to Page… (focuses and selects the page box) | ⌘[ · ⌘] · ⌥⌘G |

  ⌘= comes from a local key-down monitor in `ReaderWindowManager` (only for a key reader window
  without a sheet). PDFView's own keys (arrows, Space, Page Up/Down, Home/End) work when it has focus.
  The zoom and Go shortcuts are menu key equivalents, so they act on the PDF even while the chat input
  or transcript has focus (none of them is a typing key; the web view never zooms).
- **Restore**: `ViewerState` = `{page, zoom, scale, displayMode, sidebarVisible, sidebarMode,
  chatVisible}` in the document's `sessions/<contentHash>.json` under `"viewer"` (every field optional;
  `StoredSession` decodes a missing or unreadable `viewer` as nil and missing `messages` as []).
  The stack's saves keep the viewer state on disk; `saveViewer` never rewrites a file it can't decode.
  Saved 1 s after a change, when the window closes and at quit; the search-results sidebar is saved as
  the mode from before the search. A second window on the same bytes restores but doesn't save (like
  its chat). Restoring applies the page after the PDFView's first layout (retried while PDFKit lays out
  a long document).
