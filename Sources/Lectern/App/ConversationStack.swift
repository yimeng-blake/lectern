import Foundation
import Observation
import LecternCore

/// The conversations of one document window, stacked top to bottom in the chat pane (at most
/// `maxConversations`). Each ChatModel is one conversation with its own provider choice, Claude
/// session / Codex thread, context builders and messages. The stack owns what they share: the reader's
/// position (written by PDFReaderView), citation jumps, which conversation has the focus (Ask Lectern
/// goes there), and the document's saved file.
@MainActor @Observable
final class ConversationStack {
    static let maxConversations = 4
    static let secondaryWindowNotice =
        "This PDF is also open in another window. Questions here start new conversations, and this window's chat won't be saved."

    let document: ReaderDocument
    /// Written by PDFReaderView; every conversation asks with it.
    var readingState = ReadingState(currentPage: 0, visiblePages: [], selectionText: nil, selectionPages: [])
    /// Set by citation clicks in any conversation; the viewer goes to the page, highlights the
    /// claim's passage, then sets it nil.
    var passageRequest: PassageRequest?

    /// Top to bottom.
    private(set) var conversations: [ChatModel] = []
    /// The conversation whose input last had the keyboard focus or that was last clicked; new
    /// conversations take it.
    private(set) var focusedID: UUID?

    var focused: ChatModel? { conversations.first { $0.id == focusedID } ?? conversations.first }
    var canAddConversation: Bool { conversations.count < Self.maxConversations }
    var canCloseConversation: Bool { conversations.count > 1 }

    /// Another window already shows these bytes and owns their saved conversations.
    @ObservationIgnored let isSecondaryWindow: Bool
    @ObservationIgnored private let services: [Provider: ProviderService]
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let titler: ChatModel.Titler?
    @ObservationIgnored private let onConversationCreated: ((ChatModel) -> Void)?
    /// Window closing: the conversations shut down one by one; the file is written once at the end.
    @ObservationIgnored private var persistSuspended = false

    /// Restores the document's saved conversations (at least one). `secondary`: see ChatModel.
    init(document: ReaderDocument, services: [Provider: ProviderService], settings: SettingsStore,
         sessionStore: SessionStore, secondary: Bool = false, titler: ChatModel.Titler? = nil,
         onConversationCreated: ((ChatModel) -> Void)? = nil) {
        self.document = document
        self.services = services
        self.settings = settings
        self.sessionStore = sessionStore
        isSecondaryWindow = secondary
        self.titler = titler
        self.onConversationCreated = onConversationCreated
        let saved = sessionStore.load(contentHash: document.contentHash)
        conversations = (saved?.conversations ?? []).map(makeConversation)
        if conversations.isEmpty { conversations = [makeConversation(nil)] }
        focusedID = conversations.contains { $0.id == saved?.focusedID } ? saved?.focusedID : conversations.first?.id
        if secondary { focused?.appendNotice(Self.secondaryWindowNotice) }
    }

    convenience init(document: ReaderDocument, services app: AppServices) {
        self.init(document: document, services: app.providerServices, settings: app.settings,
                  sessionStore: app.sessions, secondary: app.isOpen(contentHash: document.contentHash),
                  titler: { question, answer, provider in
                      await ConversationTitler.title(question: question, answer: answer, provider: provider,
                                                     claude: app.claude, codex: app.codex)
                  },
                  onConversationCreated: { app.register($0) })
    }

    private func makeConversation(_ stored: StoredConversation?) -> ChatModel {
        let model = ChatModel(stack: self, stored: stored, services: services, settings: settings,
                              secondary: isSecondaryWindow, titler: titler)
        onConversationCreated?(model)
        return model
    }

    // MARK: Conversations

    /// "New Conversation": added at the bottom with the keyboard focus. Nil at the limit.
    @discardableResult
    func addConversation() -> ChatModel? {
        guard canAddConversation else { return nil }
        let model = makeConversation(nil)
        conversations.append(model)
        focusedID = model.id
        model.requestInputFocus()
        persist()
        return model
    }

    /// Stops the conversation's backend sessions and removes it with its messages. The last one stays.
    func closeConversation(_ id: UUID) {
        guard canCloseConversation, let i = index(of: id) else { return }
        let model = conversations.remove(at: i)
        // Detached first: its shutdown (and a context build still finishing) must not save it back.
        model.stack = nil
        model.shutdown()
        if focusedID == id { focusedID = conversations[min(i, conversations.count - 1)].id }
        persist()
    }

    func canMoveConversation(_ id: UUID, by offset: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        return conversations.indices.contains(i + offset)
    }

    /// Move Up (-1) / Move Down (+1).
    func moveConversation(_ id: UUID, by offset: Int) {
        guard canMoveConversation(id, by: offset), let i = index(of: id) else { return }
        var reordered = conversations
        reordered.insert(reordered.remove(at: i), at: i + offset)
        conversations = reordered
        persist()
    }

    /// Saved with the next change (and when the window closes), not on every click.
    func focus(_ id: UUID) {
        guard focusedID != id, index(of: id) != nil else { return }
        focusedID = id
    }

    // MARK: Shared reading actions

    /// "Ask Lectern" on a PDF selection (`pages` 1-based) goes to the focused conversation, opened if
    /// it was collapsed.
    func ask(_ action: SelectionAction, selection: String, pages: [Int]) {
        guard let model = focused else { return }
        focusedID = model.id
        if model.isCollapsed { model.isCollapsed = false }
        model.ask(action, selection: selection, pages: pages)
    }

    /// 1-based page from a citation in any conversation; `claim` is the sentence that carried it.
    func goTo(page: Int, claim: String? = nil) {
        guard page >= 1, page <= document.pageCount else { return }
        let trimmed = claim?.trimmingCharacters(in: .whitespacesAndNewlines)
        passageRequest = PassageRequest(page: page - 1, claim: trimmed?.isEmpty == false ? trimmed : nil)
    }

    // MARK: Lifecycle

    /// Every conversation has shut down (window closed or app quitting).
    var isShutDown: Bool { conversations.allSatisfy(\.isShutDown) }

    /// Window closed: stop every conversation's backend processes, then save once. A later send
    /// starts new sessions that resume the saved conversations.
    func shutdown() {
        persistSuspended = true
        for model in conversations { model.shutdown() }
        persistSuspended = false
        persist()
    }

    /// Writes every conversation, top to bottom (never from a second window on the same bytes).
    func persist() {
        guard !isSecondaryWindow, !persistSuspended else { return }
        let session = StoredSession(conversations: conversations.map(\.stored), focusedID: focused?.id)
        sessionStore.save(session, contentHash: document.contentHash)
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }
}
