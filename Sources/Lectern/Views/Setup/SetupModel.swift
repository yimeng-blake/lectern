import AppKit
import LecternCore
import Observation
import SwiftUI

/// Where a provider stands, in plain words: the pill on its card and the dot in the provider picker.
enum SetupStatus: Equatable {
    case ready
    case signIn
    case setUp
    case unavailable
    /// Something runs: a status check, an installation, a sign-in or a download.
    case busy(String)

    /// From the service state. `setup` is the provider's installation, when Lectern runs one.
    static func make(_ provider: Provider, auth: AuthState, installIssue: String?,
                     setup: SetupState = .idle) -> SetupStatus {
        if case .running = setup { return .busy("Setting up…") }
        if installIssue != nil { return .setUp }
        switch auth {
        case .signedIn: return .ready
        // On This Mac has no account: signed out means no model is ready yet.
        case .signedOut: return provider == .local ? .setUp : .signIn
        case .loggingIn(let progress):
            // On This Mac "signs in" by starting Ollama; its message says so.
            guard provider == .local else { return .busy("Signing in…") }
            return .busy(progress.message.isEmpty ? "Starting…" : progress.message)
        case .checking, .unknown: return .busy("Checking…")
        case .failed: return .unavailable
        }
    }

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .signIn: return "Not signed in"
        case .setUp: return "Not set up"
        case .unavailable: return "Unavailable"
        case .busy(let text): return text
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .signIn: return .orange
        case .setUp: return .secondary
        case .unavailable: return .red
        case .busy: return .secondary
        }
    }

    var isReady: Bool { self == .ready }
}

extension Provider {
    /// Card order in the setup window: free first, then the accounts people have most often.
    static let setupOrder: [Provider] = [.local, .codex, .claude, .grok]

    var setupTagline: String {
        switch self {
        case .local: return "Free and private. Nothing to sign in."
        case .codex: return "Use your ChatGPT account."
        case .claude: return "Use your Claude account."
        case .grok: return "Use your X or Grok account."
        }
    }

    /// Generic symbols only (no vendor logos).
    var setupSymbol: String {
        switch self {
        case .local: return "laptopcomputer"
        case .codex: return "bubble.left.and.bubble.right.fill"
        case .claude: return "sparkle"
        case .grok: return "bolt.fill"
        }
    }

    var setupTint: Color {
        switch self {
        case .local: return .teal
        case .codex: return .green
        case .claude: return .orange
        case .grok: return .indigo
        }
    }
}

/// The card's one button. `expands`: the card opens to show the next step or the progress.
struct SetupAction {
    let title: String
    var prominent = true
    var expands = true
    let perform: @MainActor () -> Void
}

/// State and actions of the setup window and of Settings > Accounts. Logins, installations and
/// downloads only start from the user's clicks.
@MainActor @Observable
final class SetupModel {
    static let shared = SetupModel(app: .shared)

    static let chatGPTDownloadPage = URL(string: "https://chatgpt.com/download")!

    let app: AppServices
    /// The card the setup window shows open; nil shows all four.
    var focused: Provider?

    /// A model download that ended, for one line under the list.
    struct DownloadResult: Equatable {
        let suggestion: LocalService.Suggestion
        let succeeded: Bool
    }
    private(set) var downloadResult: DownloadResult?
    private(set) var waitingForOllama = false
    /// The user went to a download page; the next time Lectern is active, it looks again.
    @ObservationIgnored private var lookAgainOnActivate: Set<Provider> = []
    @ObservationIgnored private var cancelledDownload = false
    @ObservationIgnored private var activation: NSObjectProtocol?

    init(app: AppServices) {
        self.app = app
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAgainAfterDownloadPage() }
        }
    }

    // MARK: Status

    func status(_ p: Provider) -> SetupStatus {
        switch p {
        case .claude:
            return .make(p, auth: app.claude.authState, installIssue: app.claude.installIssue,
                         setup: app.claude.setupState)
        case .codex:
            return .make(p, auth: app.codex.authState, installIssue: app.codex.installIssue)
        case .grok:
            return .make(p, auth: app.grok.authState, installIssue: app.grok.installIssue,
                         setup: app.grok.setupState)
        case .local:
            if app.local.download != nil { return .busy("Downloading…") }
            if waitingForOllama { return .busy("Opening Ollama…") }
            return .make(p, auth: app.local.authState, installIssue: app.local.installIssue)
        }
    }

    /// New conversations start with this provider.
    func isInUse(_ p: Provider) -> Bool { app.settings.lastProvider == p }

    /// The signed-in account, e.g. "you@example.com · Max"; nil when there is none to show.
    func account(_ p: Provider) -> String? {
        guard p != .local, case .signedIn(let account) = app.service(for: p).authState,
              !account.isEmpty else { return nil }
        return account
    }

    func primaryAction(_ p: Provider) -> SetupAction? {
        switch status(p) {
        case .ready:
            return isInUse(p) ? nil : SetupAction(title: "Use", prominent: false, expands: false) { self.use(p) }
        case .signIn:
            return SetupAction(title: p == .claude ? "Log in" : "Sign in") { self.signIn(p) }
        case .setUp:
            switch p {
            case .claude, .grok: return SetupAction(title: "Set up") { self.install(p) }
            case .codex: return SetupAction(title: "Set up") {}
            case .local:
                if case .ready = app.local.ollamaStatus { return SetupAction(title: "Download a model") {} }
                return SetupAction(title: "Set up") {}
            }
        case .unavailable:
            return SetupAction(title: "Try again", prominent: false) { self.checkAgain(p) }
        case .busy:
            guard canCancel(p) else { return nil }
            return SetupAction(title: "Cancel", prominent: false, expands: false) { self.cancel(p) }
        }
    }

    // MARK: Actions

    func use(_ p: Provider) {
        app.settings.lastProvider = p
    }

    func signIn(_ p: Provider, method: LoginMethod? = nil) {
        let service = app.service(for: p)
        switch p {
        case .claude: service.startLogin(.terminal)
        case .codex, .grok: service.startLogin(method ?? .browser)
        case .local: break
        }
    }

    func install(_ p: Provider) {
        switch p {
        case .claude:
            if case .running = app.claude.setupState { return }
            Task {
                await app.claude.install()
                app.claude.refreshAuth()
            }
        case .grok:
            if case .running = app.grok.setupState { return }
            Task {
                await app.grok.install()
                app.grok.refreshAuth()
                app.grok.reloadModels()
            }
        case .codex, .local:
            break
        }
    }

    /// Reads the status again (no login): after a fix outside Lectern, or after an error.
    func checkAgain(_ p: Provider) {
        switch p {
        case .claude:
            if app.claude.installIssue != nil { app.claude.relocateBinary() } else { app.claude.refreshAuth() }
        case .codex:
            // The ChatGPT app may have been installed since: find Codex again.
            if app.codex.installIssue != nil { app.codex.restart() }
            app.codex.refreshAuth()
            app.codex.reloadModels()
        case .grok, .local:
            let service = app.service(for: p)
            service.refreshAuth()
            service.reloadModels()
        }
    }

    func canCancel(_ p: Provider) -> Bool {
        if p == .local { return app.local.download != nil }
        if case .loggingIn = app.service(for: p).authState { return true }
        return false
    }

    func cancel(_ p: Provider) {
        if p == .local {
            cancelDownload()
        } else {
            app.service(for: p).cancelLogin()
        }
    }

    func getChatGPTApp() {
        lookAgainOnActivate.insert(.codex)
        NSWorkspace.shared.open(Self.chatGPTDownloadPage)
    }

    func getOllama() {
        lookAgainOnActivate.insert(.local)
        app.local.openOllamaDownloadPage()
    }

    /// Opens Ollama.app in the background (LocalService finds it by either bundle id, and opens the
    /// download page if it is gone), then shows progress until its server answers (up to 30 seconds).
    func openOllama() {
        waitingForOllama = true
        app.local.openOllama()
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if app.local.ollamaStatus != .notRunning { break }
            }
            waitingForOllama = false
        }
    }

    func download(_ suggestion: LocalService.Suggestion) {
        guard app.local.download == nil else { return }
        downloadResult = nil
        cancelledDownload = false
        Task {
            let succeeded = await app.local.downloadModel(suggestion.id)
            app.local.reloadModels()
            if succeeded {
                // The model the user just chose to download is the one they want to use.
                app.settings.setTurnSettings(TurnSettings(model: "ollama:" + suggestion.id), for: .local,
                                             models: app.local.models)
            }
            if !cancelledDownload {
                downloadResult = DownloadResult(suggestion: suggestion, succeeded: succeeded)
            }
        }
    }

    func cancelDownload() {
        cancelledDownload = true
        app.local.cancelDownload()
    }

    /// The model that new On This Mac conversations use.
    var localModel: String {
        app.settings.turnSettings(for: .local, models: app.local.models).model
    }

    func selectLocalModel(_ id: String) {
        app.settings.setTurnSettings(TurnSettings(model: id), for: .local, models: app.local.models)
    }

    /// The setup window closed: if new conversations would start with a provider that can't answer,
    /// they start with the first one that can.
    func windowClosed() {
        focused = nil
        guard !app.isReady(app.settings.lastProvider),
              let ready = Provider.setupOrder.first(where: app.isReady) else { return }
        app.settings.lastProvider = ready
    }

    private func lookAgainAfterDownloadPage() {
        for p in lookAgainOnActivate {
            if p == .codex, app.codex.installIssue == nil { lookAgainOnActivate.remove(p); continue }
            if p == .local, app.local.ollamaStatus != .notInstalled { lookAgainOnActivate.remove(p); continue }
            checkAgain(p)
        }
    }
}

/// The "Choose your AI" window: on first launch, from Lectern > Set Up AI… and from the provider
/// picker's "Set Up …" items (open on that provider's card).
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()
    static let size = NSSize(width: 680, height: 560)

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(focus: Provider? = nil) {
        let app = AppServices.shared
        let model = SetupModel.shared
        app.settings.setupShown = true
        model.focused = focus
        // Cheap re-checks: something may have changed outside Lectern (e.g. Ollama opened).
        for p in Provider.allCases where !app.isReady(p) && !model.status(p).isBusy {
            model.checkAgain(p)
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: ChooseAIView(model: model) { [weak self] in self?.close() })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Choose Your AI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = host
        window.setContentSize(Self.size)
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        SetupModel.shared.windowClosed()
        window?.delegate = nil
        window = nil
        // First launch: after Done, offer a PDF as Lectern does at every launch.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ReaderWindowManager.shared.showOpenPanelIfIdle()
        }
    }

    /// At launch: the first time, or when no provider is ready and no document opened.
    func showAtLaunchIfNeeded() async -> Bool {
        let app = AppServices.shared
        if !app.settings.setupShown {
            show()
            return true
        }
        // Status checks answer within a second or two; a ready provider ends the wait at once.
        for _ in 0..<20 {
            if app.anyProviderReady || !app.isCheckingStatus { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !app.anyProviderReady, !ReaderWindowManager.shared.hasReaderWindows else { return false }
        show()
        return true
    }
}

extension SetupStatus {
    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}
