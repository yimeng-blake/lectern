import Foundation
import Observation
import LecternCore

/// One conversation of a document window (a panel in its ConversationStack): both providers'
/// conversations, context building, auth gating, the purchased-credits guard, and the panel's title.
@MainActor @Observable
final class ChatModel: Identifiable {
    static let maxAutomaticAuthRetries = 2
    static let defaultTitle = StoredConversation.defaultTitle
    /// Longest title kept (automatic or renamed).
    static let maxTitleLength = 80

    /// Writes a topic title from the first question and answer (ConversationTitler in the app);
    /// nil keeps the local fallback.
    typealias Titler = @MainActor (_ question: String, _ answer: String, _ provider: Provider) async -> String?

    /// Whole-document budget in estimated tokens for the model the turn uses.
    static func tokenBudget(for provider: Provider, model: String) -> Int {
        ContextOptions.defaultTokenBudget(for: provider, model: model)
    }

    enum CreditsGuardReason: Equatable {
        /// Included usage is used up: sending would spend purchased credits.
        case exhausted
        /// The usage read failed or is unavailable, so Lectern can't tell.
        case unknown
    }

    let id: UUID
    let document: ReaderDocument
    /// The window's conversations. It owns what they share: the reading state (written by
    /// PDFReaderView), citation jumps, focus, and the saved file. Cleared when this one is closed.
    @ObservationIgnored weak var stack: ConversationStack?
    /// What the reader is looking at (the stack's).
    var readingState: ReadingState { stack?.readingState ?? Self.noReadingState }

    /// The panel's title: automatic (from the first question, then the model) until renamed.
    private(set) var title: String
    /// The user named this conversation; automatic titles never replace the name.
    private(set) var titleIsCustom: Bool
    /// The panel shows only its title bar.
    var isCollapsed: Bool {
        didSet { if isCollapsed != oldValue { persist() } }
    }
    /// Bumped to put the keyboard focus in this conversation's input (a new conversation).
    private(set) var inputFocusRequest = 0
    /// Ask Lectern and the conversation commands go to this conversation.
    var isFocused: Bool { stack?.focusedID == id }

    /// Switching keeps both conversations.
    var provider: Provider {
        didSet {
            guard provider != oldValue else { return }
            settingsStore.lastProvider = provider
            persist()
        }
    }

    /// Settings for `provider`; setting them persists them as the new default.
    var settings: TurnSettings {
        get { turnSettings(for: provider) }
        set { settingsStore.setTurnSettings(newValue, for: provider, models: models) }
    }
    var models: [ModelOption] { service(provider).models }
    var selectedModel: ModelOption? { ModelCatalog.selected(settings.model, in: models) }
    var effortChoices: [String] { selectedModel?.efforts ?? [] }
    var authState: AuthState { service(provider).authState }
    /// Any provider's sign-in state, for the provider picker.
    func authState(for p: Provider) -> AuthState { service(p).authState }
    /// Whether a turn is running for `p` (it keeps streaming while another provider is shown).
    func isBusy(_ p: Provider) -> Bool { activeTurns[p] != nil }
    var quota: QuotaSnapshot? { quota(for: provider) }
    var installIssue: String? { service(provider).installIssue }
    var resolvedModel: String? { resolvedModels[provider] }

    private(set) var messages: [ChatMessage] = []
    var isBusy: Bool { activeTurns[provider] != nil }
    /// A turn is running for either provider.
    var isAnyBusy: Bool { !activeTurns.isEmpty }
    var hasUserMessages: Bool { messages.contains { $0.role == .user } }
    var draft = ""
    var attachPageImage = false
    var includeWholeDocument = false
    var creditsGuardActive: Bool { blockedTurn?.provider == provider }
    /// Why the credits guard holds the current provider's question; nil when it doesn't.
    var creditsGuardReason: CreditsGuardReason? { creditsGuardActive ? blockedReason : nil }
    private(set) var lastWarning: String?

    // MARK: Private state

    /// A question with the reading position captured when it was asked, so a send delayed by
    /// login or the credits guard still uses the pages the user was looking at.
    private struct PendingTurn {
        let userMessageId: UUID
        let provider: Provider
        let question: String
        let readingState: ReadingState
        let attachPageImage: Bool
        let wholeDocument: Bool
        var creditsConfirmed = false
        var authFailures = 0
        /// Prompt of an attempt rejected for auth. It is resent as is: the ContextBuilder already
        /// counts its pages as sent.
        var builtPrompt: BuiltPrompt?
    }

    private struct ActiveTurn {
        let token: UUID
        var pending: PendingTurn
        let assistantMessageId: UUID
        var sent = false
        var stopRequested = false
    }

    private var activeTurns: [Provider: ActiveTurn] = [:]
    private var blockedTurn: PendingTurn?
    private var blockedReason = CreditsGuardReason.exhausted
    private var resolvedModels: [Provider: String] = [:]
    private var eventQuotas: [Provider: QuotaSnapshot] = [:]

    @ObservationIgnored private let services: [Provider: ProviderService]
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let titler: Titler?
    @ObservationIgnored private var builders: [Provider: ContextBuilder] = [:]
    @ObservationIgnored private var sessions: [Provider: ChatSession] = [:]
    @ObservationIgnored private var queues: [Provider: [PendingTurn]] = [:]
    /// Conversation ids under which a turn has completed; only these are worth resuming.
    @ObservationIgnored private var conversationIds: [Provider: String] = [:]
    @ObservationIgnored private var pendingNewChat: Set<Provider> = []
    @ObservationIgnored private(set) var isShutDown = false
    /// An answer completed in this conversation, so it has been titled (or will keep its title).
    @ObservationIgnored private var hasTitledAnswer = false
    /// The latest automatic title (fallback or model), for going back to it after a rename.
    @ObservationIgnored private var autoTitle: String?
    /// Bumped by renames and clears, so a model title that arrives afterwards is dropped.
    @ObservationIgnored private var titleGeneration = 0
    /// A ChatGPT question waits for account/rateLimits/read before the credits guard decides.
    @ObservationIgnored private var codexQuotaCheckRunning = false
    /// The question whose quota read just finished; the guard decides on that read without another.
    @ObservationIgnored private var codexQuotaCheckedFor: UUID?
    /// How long Stop may wait for the backend to confirm before the session is discarded.
    @ObservationIgnored var interruptTimeout: Duration = .seconds(15)

    /// Made by its ConversationStack, which saves it. `stored` restores a saved conversation.
    /// `secondary`: the same PDF is open in another window. This one shows the saved chat but starts
    /// new conversations (the stack saves nothing), so the windows never overwrite each other's file or
    /// share a Claude session / Codex thread.
    init(stack: ConversationStack, stored: StoredConversation? = nil, services: [Provider: ProviderService],
         settings: SettingsStore, secondary: Bool = false, titler: Titler? = nil) {
        precondition(Provider.allCases.allSatisfy { services[$0] != nil }, "a service per provider")
        id = stored?.id ?? UUID()
        document = stack.document
        self.stack = stack
        self.services = services
        self.settingsStore = settings
        self.titler = titler
        provider = stored?.provider ?? settings.lastProvider
        title = stored?.title ?? Self.defaultTitle
        titleIsCustom = stored?.titleIsCustom ?? false
        isCollapsed = stored?.collapsed ?? false
        for p in Provider.allCases {
            builders[p] = ContextBuilder(document: document)
        }
        if let stored {
            messages = stored.messages.map(Self.restored)
            if !secondary {
                for p in Provider.allCases {
                    conversationIds[p] = stored.conversationId(for: p)
                }
            }
        }
        hasTitledAnswer = messages.contains(where: Self.isAnswer)
        for p in Provider.allCases {
            services[p]?.addAuthObserver { [weak self] state in
                self?.authChanged(state, for: p)
            }
        }
    }

    /// What the stack saves for this conversation.
    var stored: StoredConversation {
        StoredConversation(id: id, title: title, titleIsCustom: titleIsCustom, provider: provider,
                           claudeSessionId: conversationIds[.claude], codexThreadId: conversationIds[.codex],
                           messages: messages, collapsed: isCollapsed)
    }

    // MARK: Actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, !creditsGuardActive else { return }
        guard submit(question: text, title: text, state: readingState, wholeDocument: includeWholeDocument) else { return }
        draft = ""
    }

    /// "Ask Lectern" on a PDF selection (`pages` 1-based). The selection is captured now, so the
    /// question uses it even if the reader's selection changes before the turn starts. While a turn
    /// runs, the question waits in the queue.
    func ask(_ action: SelectionAction, selection: String, pages: [Int]) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var state = readingState
        state.selectionText = text
        state.selectionPages = pages.map { $0 - 1 }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let excerpt = collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
        submit(question: action.prompt, title: "\(action.title): \u{201C}\(excerpt)\u{201D}", state: state,
               wholeDocument: includeWholeDocument)
    }

    /// Presets menu: the preset's question, with the whole document for this send only when it asks.
    func runPreset(_ preset: ChatPreset) {
        guard !isBusy, !creditsGuardActive else { return }
        submit(question: preset.prompt, title: preset.title, state: readingState,
               wholeDocument: preset.wholeDocument || includeWholeDocument)
    }

    func stop() {
        let p = provider
        guard var turn = activeTurns[p], !turn.stopRequested else { return }
        turn.stopRequested = true
        activeTurns[p] = turn
        // Not sent yet: the context build finishes the turn as interrupted.
        guard turn.sent else { return }
        sessions[p]?.interrupt()
        let token = turn.token
        let timeout = interruptTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.interruptTimedOut(p, token: token)
        }
    }

    func newChat() {
        let p = provider
        if activeTurns[p] != nil {
            pendingNewChat.insert(p)
            stop()
            return
        }
        performNewChat(p)
    }

    /// Only ever called from an explicit user action.
    func startLogin(_ method: LoginMethod) {
        service(provider).startLogin(method)
    }

    func cancelLogin() {
        service(provider).cancelLogin()
    }

    /// Re-reads the login status (no login).
    func recheckAuth() {
        service(provider).refreshAuth()
    }

    func confirmSpendCredits() {
        guard var turn = blockedTurn else { return }
        blockedTurn = nil
        isShutDown = false
        turn.creditsConfirmed = true
        queues[turn.provider, default: []].insert(turn, at: 0)
        pump(turn.provider)
    }

    /// Withdraws the blocked question and puts it back in the input field (ahead of anything typed since).
    func cancelBlockedSend() {
        guard let turn = blockedTurn else { return }
        blockedTurn = nil
        messages.removeAll { $0.id == turn.userMessageId }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? turn.question : turn.question + "\n\n" + draft
        persist()
        pump(turn.provider)
    }

    /// 1-based, from [p. N] links; `claim` is the sentence that carried the citation. A page the
    /// document doesn't have (e.g. a printed page number) is reported instead of jumping somewhere unrelated.
    func goTo(page: Int, claim: String? = nil) {
        guard page >= 1, page <= document.pageCount else {
            let count = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
            lastWarning = "This document has no page \(page) (it has \(count))."
            return
        }
        stack?.goTo(page: page, claim: claim)
    }

    // MARK: Panel

    /// This conversation was clicked or its input got the keyboard focus.
    func takeFocus() {
        stack?.focus(id)
    }

    /// Asks the panel to put the keyboard focus in its input.
    func requestInputFocus() {
        inputFocusRequest += 1
    }

    /// A notice in the transcript (e.g. the second-window note).
    func appendNotice(_ text: String) {
        append(ChatMessage(role: .notice, provider: provider, text: text))
    }

    /// A name chosen by the user; an empty one goes back to the automatic title.
    func rename(_ newTitle: String) {
        if let custom = Self.cleanTitle(newTitle) {
            guard !(titleIsCustom && title == custom) else { return }
            titleGeneration += 1
            titleIsCustom = true
            title = custom
        } else {
            guard titleIsCustom else { return }
            titleGeneration += 1
            titleIsCustom = false
            if let autoTitle {
                title = autoTitle
            } else if let first = firstExchange() {
                setAutoTitle(ConversationTitler.fallbackTitle(question: first.question), save: false)
                requestModelTitle(question: first.question, answer: first.answer, provider: first.provider)
            } else {
                title = Self.defaultTitle
            }
        }
        persist()
    }

    /// "New Chat" in the panel's menu: removes this conversation's messages and starts both providers'
    /// conversations over. An automatic title goes back to the default. Not while a turn runs.
    func clearConversation() {
        guard activeTurns.isEmpty else { return }
        blockedTurn = nil
        queues.removeAll()
        pendingNewChat.removeAll()
        for p in Provider.allCases {
            sessions[p]?.resetConversation()
            conversationIds[p] = nil
            resetContext(p)
        }
        messages.removeAll()
        lastWarning = nil
        hasTitledAnswer = false
        autoTitle = nil
        titleGeneration += 1
        if !titleIsCustom { title = Self.defaultTitle }
        persist()
    }

    /// Window closed (or app quitting): stop backend processes and save. A later send starts new
    /// sessions that resume the saved conversations. Calling it again before such a send does nothing.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for (p, turn) in activeTurns {
            if turn.sent {
                update(turn.assistantMessageId) { $0.status = .interrupted }
                activeTurns[p] = nil
            } else {
                // The context build is still running; it finishes the turn when it returns.
                activeTurns[p]?.stopRequested = true
            }
        }
        for session in sessions.values {
            session.onEvent = nil
            session.shutdown()
        }
        sessions.removeAll()
        persist()
    }

    // MARK: Turn pipeline

    /// Shows `title` as the user's message and queues `question` with the given reading state.
    @discardableResult
    private func submit(question: String, title: String, state: ReadingState, wholeDocument: Bool) -> Bool {
        let p = provider
        if let issue = service(p).installIssue {
            append(ChatMessage(role: .notice, provider: p, text: issue))
            return false
        }
        isShutDown = false
        let message = ChatMessage(role: .user, provider: p, text: title)
        append(message)
        queues[p, default: []].append(PendingTurn(
            userMessageId: message.id, provider: p, question: question, readingState: state,
            attachPageImage: attachPageImage, wholeDocument: wholeDocument))
        pump(p)
        return true
    }

    /// Starts the next queued question for `p` when the provider is idle, signed in and not
    /// blocked by the credits guard.
    private func pump(_ p: Provider) {
        guard !isShutDown, activeTurns[p] == nil, blockedTurn?.provider != p,
              !(p == .codex && codexQuotaCheckRunning), let next = queues[p]?.first else { return }
        let svc = service(p)
        guard svc.authState.isSignedIn else {
            for turn in queues[p] ?? [] { setStatus(turn.userMessageId, .waitingForLogin) }
            switch svc.authState {
            case .unknown, .failed: svc.refreshAuth()
            default: break
            }
            return
        }
        if p == .codex, settingsStore.protectCredits, !next.creditsConfirmed, let codex = svc as? CodexService {
            // Fails closed: an unknown or old quota is read first, and a read that can't tell asks the user.
            let justRead = codexQuotaCheckedFor == next.userMessageId
            codexQuotaCheckedFor = nil
            switch codex.creditsCheck() {
            case .notApplicable, .available:
                break
            case .exhausted:
                block(next, .exhausted)
                return
            case .needsRefresh where !justRead:
                setStatus(next.userMessageId, .done)
                codexQuotaCheckRunning = true
                Task { [weak self] in
                    await codex.refreshQuota()
                    guard let self else { return }
                    self.codexQuotaCheckRunning = false
                    self.codexQuotaCheckedFor = next.userMessageId
                    self.pump(p)
                }
                return
            case .needsRefresh:
                block(next, codex.quota?.includedUsageExhausted == true ? .exhausted : .unknown)
                return
            }
        }
        queues[p]?.removeFirst()
        start(next)
    }

    /// Holds the queue's first question until confirmSpendCredits()/cancelBlockedSend().
    private func block(_ turn: PendingTurn, _ reason: CreditsGuardReason) {
        queues[turn.provider]?.removeFirst()
        setStatus(turn.userMessageId, .done)
        blockedReason = reason
        blockedTurn = turn
    }

    private func start(_ pending: PendingTurn) {
        let p = pending.provider
        setStatus(pending.userMessageId, .done)
        lastWarning = nil
        let requested = turnSettings(for: p).model
        let reply = ChatMessage(role: .assistant, provider: p, text: "", status: .thinking,
                                model: requested.isEmpty ? nil : requested)
        // Right after its question, which may not be last when it waited for login or the guard.
        if let i = messages.firstIndex(where: { $0.id == pending.userMessageId }) {
            messages.insert(reply, at: i + 1)
        } else {
            append(reply)
        }
        let turn = ActiveTurn(token: UUID(), pending: pending, assistantMessageId: reply.id)
        activeTurns[p] = turn
        Task { [weak self] in
            await self?.buildAndSend(p, token: turn.token)
        }
    }

    private func buildAndSend(_ p: Provider, token: UUID) async {
        guard let turn = activeTurns[p], turn.token == token else { return }
        let built: BuiltPrompt
        let builtNow: Bool
        if let cached = turn.pending.builtPrompt {
            built = cached
            builtNow = false
        } else {
            let requested = turnSettings(for: p).model
            let options = ContextOptions(neighborRadius: settingsStore.contextRadius,
                                         attachPageImage: turn.pending.attachPageImage,
                                         wholeDocument: turn.pending.wholeDocument,
                                         tokenBudget: Self.tokenBudget(for: p, model: requested.isEmpty
                                                                       ? resolvedModels[p] ?? "" : requested))
            built = await builder(p).build(question: turn.pending.question,
                                           state: turn.pending.readingState, options: options)
            builtNow = true
        }
        guard var current = activeTurns[p], current.token == token else { return }
        if current.stopRequested {
            // The builder now counts these pages as sent, but they never were.
            if builtNow { resetContext(p) }
            update(current.assistantMessageId) { $0.status = .interrupted }
            finish(p)
            return
        }
        let pages = built.pagesIncluded.map { $0 + 1 }
        update(current.pending.userMessageId) { $0.pages = pages }
        current.pending.builtPrompt = built
        current.sent = true
        activeTurns[p] = current
        session(for: p).send(built.request, settings: turnSettings(for: p))
    }

    private func handle(_ event: BackendEvent, from p: Provider) {
        switch event {
        case .quota(let snapshot):
            eventQuotas[p] = snapshot
            return
        case .warning(let text):
            lastWarning = text
            return
        case .conversationReset:
            conversationReset(p)
            return
        case .sessionReady(let model):
            resolvedModels[p] = model
        default:
            break
        }
        guard let turn = activeTurns[p] else { return }
        let replyId = turn.assistantMessageId
        switch event {
        case .sessionReady(let model):
            update(replyId) { $0.model = model }
        case .thinking:
            update(replyId) { if $0.text.isEmpty { $0.status = .thinking } }
        case .textDelta(let delta):
            update(replyId) {
                $0.text += delta
                $0.status = .streaming
            }
        case .completed(let text, _):
            update(replyId) {
                if !text.isEmpty { $0.text = text }
                $0.status = .done
            }
            if let id = sessions[p]?.conversationId { conversationIds[p] = id }
            titleAfterFirstAnswer(turn, replyId: replyId)
            finish(p)
            verifyCitations(replyId)
        case .interrupted:
            update(replyId) { $0.status = .interrupted }
            // No answer text: the prompt may never have reached the backend (Stop before turn/start), so
            // send its pages again next time rather than call them "provided earlier".
            if messages.first(where: { $0.id == replyId })?.text.isEmpty != false,
               let built = turn.pending.builtPrompt {
                builder(p).discard(built)
            }
            finish(p)
        case .failed(let error):
            failed(turn, error)
        case .quota, .warning, .conversationReset:
            break
        }
    }

    private func failed(_ turn: ActiveTurn, _ error: BackendError) {
        let p = turn.pending.provider
        if error.isAuth, turn.pending.authFailures < Self.maxAutomaticAuthRetries {
            // Not the model's answer: the question waits for login and is retried automatically.
            messages.removeAll { $0.id == turn.assistantMessageId }
            var retry = turn.pending
            retry.authFailures += 1
            setStatus(retry.userMessageId, .waitingForLogin)
            queues[p, default: []].insert(retry, at: 0)
            let svc = service(p)
            if svc.authState.isSignedIn { svc.markAuthExpired(error.message) }
            finish(p)
            return
        }
        update(turn.assistantMessageId) {
            $0.status = .failed
            $0.errorText = error.message
        }
        // Unknown whether the prompt reached the conversation; send its pages again next time.
        resetContext(p)
        finish(p)
    }

    // MARK: Titles

    /// The first answer names the conversation: the local fallback at once (saved with the turn), then,
    /// when Settings allow, a short model title off the critical path.
    private func titleAfterFirstAnswer(_ turn: ActiveTurn, replyId: UUID) {
        guard !hasTitledAnswer,
              let answer = messages.first(where: { $0.id == replyId })?.text, !answer.isEmpty else { return }
        hasTitledAnswer = true
        guard !titleIsCustom else { return }
        let question = messages.first(where: { $0.id == turn.pending.userMessageId })?.text ?? turn.pending.question
        setAutoTitle(ConversationTitler.fallbackTitle(question: question), save: false)
        requestModelTitle(question: question, answer: answer, provider: turn.pending.provider)
    }

    private func requestModelTitle(question: String, answer: String, provider p: Provider) {
        guard settingsStore.aiConversationTitles, let titler else { return }
        let generation = titleGeneration
        let excerpt = String(answer.prefix(4000))
        Task { [weak self] in
            let proposed = await titler(question, excerpt, p)
            guard let self, self.titleGeneration == generation, !self.titleIsCustom,
                  let clean = Self.cleanTitle(proposed) else { return }
            self.setAutoTitle(clean, save: true)
        }
    }

    private func setAutoTitle(_ newTitle: String, save: Bool) {
        autoTitle = newTitle
        guard title != newTitle else { return }
        title = newTitle
        if save { persist() }
    }

    /// The first answered question, for titling a conversation that lost its automatic title.
    private func firstExchange() -> (question: String, answer: String, provider: Provider)? {
        guard let i = messages.firstIndex(where: Self.isAnswer) else { return nil }
        let answer = messages[i]
        let asked = messages[..<i].last { $0.role == .user && $0.provider == answer.provider }
            ?? messages.first { $0.role == .user }
        guard let question = asked?.text else { return nil }
        return (question, answer.text, answer.provider)
    }

    private static func isAnswer(_ m: ChatMessage) -> Bool {
        m.role == .assistant && m.status == .done && !m.text.isEmpty
    }

    /// One line, collapsed whitespace, at most `maxTitleLength` characters; nil when empty.
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > maxTitleLength ? String(line.prefix(maxTitleLength - 1)) + "\u{2026}" : line
    }

    /// Checks the answer's citations against the cited pages (off the main actor) and keeps the
    /// result with the message, for the transcript's badges.
    private func verifyCitations(_ id: UUID) {
        guard let text = messages.first(where: { $0.id == id })?.text, !text.isEmpty else { return }
        let document = self.document
        Task { [weak self] in
            let checks = await Task.detached(priority: .utility) {
                await CitationVerifier.verify(answer: text, in: document)
            }.value
            guard let self, !checks.isEmpty,
                  self.messages.first(where: { $0.id == id })?.text == text else { return }
            self.update(id) { $0.citationChecks = checks }
            self.persist()
        }
    }

    private func finish(_ p: Provider) {
        activeTurns[p] = nil
        persist()
        if pendingNewChat.remove(p) != nil { performNewChat(p) }
        pump(p)
    }

    private func interruptTimedOut(_ p: Provider, token: UUID) {
        guard let turn = activeTurns[p], turn.token == token else { return }
        update(turn.assistantMessageId) { $0.status = .interrupted }
        // The session never confirmed the stop; replace it so the next send gets a fresh process.
        if let session = sessions.removeValue(forKey: p) {
            session.onEvent = nil
            session.shutdown()
        }
        if conversationIds[p] == nil {
            // The replacement session starts a new conversation: nothing sent so far is in it.
            resetContext(p)
        } else if let built = turn.pending.builtPrompt {
            // Unknown whether this prompt was recorded; its pages go again next time.
            builder(p).discard(built)
        }
        finish(p)
    }

    private func performNewChat(_ p: Provider) {
        sessions[p]?.resetConversation()
        conversationIds[p] = nil
        resetContext(p)
        if hasConversation(p) {
            append(ChatMessage(role: .notice, provider: p,
                               text: "New \(p.displayName) conversation. Earlier messages are not remembered."))
        }
        persist()
    }

    /// The session could not resume the conversation and ended the attempt without sending: its
    /// prompt was built for the old conversation. Rebuild it (all pages, outline) and send it again.
    private func conversationReset(_ p: Provider) {
        conversationIds[p] = nil
        resetContext(p)
        let notice = ChatMessage(role: .notice, provider: p, text:
            "The earlier \(p.displayName) conversation could not be resumed, so a new one was started. Pages will be sent again.")
        if let turn = activeTurns[p], let i = messages.firstIndex(where: { $0.id == turn.pending.userMessageId }) {
            messages.insert(notice, at: i)
        } else {
            append(notice)
        }
        guard let turn = activeTurns[p], turn.sent else { return }
        if turn.stopRequested {
            update(turn.assistantMessageId) { $0.status = .interrupted }
        } else {
            messages.removeAll { $0.id == turn.assistantMessageId }
            queues[p, default: []].insert(turn.pending, at: 0)
        }
        finish(p)
    }

    /// Forget which pages were sent; prompts cached for auth retries assumed the old state.
    private func resetContext(_ p: Provider) {
        builder(p).reset()
        if var turn = activeTurns[p] {
            turn.pending.builtPrompt = nil
            activeTurns[p] = turn
        }
        if var queue = queues[p] {
            for i in queue.indices { queue[i].builtPrompt = nil }
            queues[p] = queue
        }
        if blockedTurn?.provider == p { blockedTurn?.builtPrompt = nil }
    }

    private func authChanged(_ state: AuthState, for p: Provider) {
        // A snapshot an earlier turn reported may belong to another login.
        if p == .codex { eventQuotas[p] = nil }
        if state.isSignedIn { pump(p) }
    }

    // MARK: Helpers

    private func service(_ p: Provider) -> ProviderService { services[p]! }

    private func builder(_ p: Provider) -> ContextBuilder { builders[p]! }

    private func turnSettings(for p: Provider) -> TurnSettings {
        settingsStore.turnSettings(for: p, models: service(p).models)
    }

    private func quota(for p: Provider) -> QuotaSnapshot? {
        service(p).quota ?? eventQuotas[p]
    }

    private func session(for p: Provider) -> ChatSession {
        if let existing = sessions[p] {
            if !existing.isBusy { return existing }
            existing.onEvent = nil
            existing.shutdown()
        }
        let session = service(p).makeSession(conversationId: conversationIds[p])
        session.onEvent = { [weak self] event in
            self?.handle(event, from: p)
        }
        sessions[p] = session
        return session
    }

    private func hasConversation(_ p: Provider) -> Bool {
        for m in messages.reversed() where m.provider == p {
            if m.role == .notice { return false }
            return true
        }
        return false
    }

    /// The stack saves every conversation of the document (not in a second window on the same bytes).
    private func persist() {
        stack?.persist()
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    private func setStatus(_ id: UUID, _ status: ChatMessage.Status) {
        update(id) { if $0.status != status { $0.status = status } }
    }

    private static let noReadingState = ReadingState(currentPage: 0, visiblePages: [], selectionText: nil,
                                                     selectionPages: [])

    /// Messages saved mid-turn or while waiting cannot continue after a relaunch.
    private static func restored(_ message: ChatMessage) -> ChatMessage {
        var m = message
        switch m.status {
        case .streaming, .thinking:
            m.status = .interrupted
        case .waitingForLogin:
            m.status = .failed
            m.errorText = "Not sent: the window was closed before sign-in finished."
        case .done, .interrupted, .failed:
            break
        }
        return m
    }
}
