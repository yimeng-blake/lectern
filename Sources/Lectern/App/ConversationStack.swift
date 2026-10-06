import Foundation
import Observation
import LecternCore

/// A conversation's color: the dot before its title, the line over its title bar and its focus ring.
/// A new conversation gets the first one no other conversation has; it is saved with it.
enum ConversationTag: Int, CaseIterable, Codable {
    case blue, green, orange, purple

    /// 0xRRGGBB: #2F5BEA, #2E9E6B, #E07A2E, #8A4FD8.
    var hex: UInt32 {
        switch self {
        case .blue: return 0x2F5BEA
        case .green: return 0x2E9E6B
        case .orange: return 0xE07A2E
        case .purple: return 0x8A4FD8
        }
    }
}

/// The conversations of one document window (at most `maxConversations`), laid out in the chat pane
/// by `gridRows`. Each ChatModel is one conversation with its own provider choice, Claude
/// session / Codex thread, context builders and messages. The stack owns what they share: the reader's
/// position (written by PDFReaderView), citation jumps, which conversation has the focus (Ask Lectern
/// goes there), the one shown alone, and the document's saved file.
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

    /// In order; the order is the position in the grid (`gridRows`).
    private(set) var conversations: [ChatModel] = []
    /// The conversation whose input last had the keyboard focus or that was last clicked; new
    /// conversations take it.
    private(set) var focusedID: UUID?
    /// The conversation shown alone in the whole chat pane (title bar ⤢); nil shows them all. Not saved.
    private(set) var maximizedID: UUID?

    var focused: ChatModel? { conversations.first { $0.id == focusedID } ?? conversations.first }
    var canAddConversation: Bool { conversations.count < Self.maxConversations }
    var canCloseConversation: Bool { conversations.count > 1 }
    /// Three or four conversations: two side by side in a row.
    var usesTwoColumns: Bool { conversations.count > 2 }

    /// Where `count` conversations go, as indices into `conversations`, top row first: 1 fills the pane,
    /// 2 are stacked, 3 are two side by side over one full width, 4 are a 2×2 grid.
    static func gridRows(count: Int) -> [[Int]] {
        guard count > 2 else { return (0..<max(count, 0)).map { [$0] } }
        return stride(from: 0, to: count, by: 2).map { Array($0..<min($0 + 2, count)) }
    }

    /// Only a conversation alone in its row, with others in the pane, folds to its title bar.
    func canCollapse(_ id: UUID) -> Bool {
        guard conversations.count > 1, let i = index(of: id) else { return false }
        return Self.gridRows(count: conversations.count).contains([i])
    }

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
        assignColorTags(saved: saved?.conversations.map(\.colorTag) ?? [])
        focusedID = conversations.contains { $0.id == saved?.focusedID } ? saved?.focusedID : conversations.first?.id
        openUnfoldable()  // saved with the next change
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

    /// Saved colors stay; conversations from before colors (or sharing one) get the first free color, in order.
    private func assignColorTags(saved: [ConversationTag?]) {
        var used = Set<ConversationTag>()
        var untagged: [ChatModel] = []
        for (i, model) in conversations.enumerated() {
            if i < saved.count, let tag = saved[i], used.insert(tag).inserted {
                model.colorTag = tag
            } else {
                untagged.append(model)
            }
        }
        for model in untagged {
            let tag = ConversationTag.allCases.first { !used.contains($0) } ?? .blue
            used.insert(tag)
            model.colorTag = tag
        }
    }

    // MARK: Conversations

    /// "New Conversation": added last (shown with all the others) with the keyboard focus and the
    /// first free color. Nil at the limit.
    @discardableResult
    func addConversation() -> ChatModel? {
        guard canAddConversation else { return nil }
        let model = makeConversation(nil)
        let used = Set(conversations.map(\.colorTag))
        model.colorTag = ConversationTag.allCases.first { !used.contains($0) } ?? .blue
        conversations.append(model)
        maximizedID = nil
        focusedID = model.id
        model.requestInputFocus()
        gridChanged()
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
        if maximizedID == id || conversations.count < 2 { maximizedID = nil }
        gridChanged()
    }

    func canMoveConversation(_ id: UUID, by offset: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        return conversations.indices.contains(i + offset)
    }

    /// Move Earlier (-1) / Move Later (+1): one place in the grid order.
    func moveConversation(_ id: UUID, by offset: Int) {
        guard canMoveConversation(id, by: offset), let i = index(of: id) else { return }
        var reordered = conversations
        reordered.insert(reordered.remove(at: i), at: i + offset)
        conversations = reordered
        gridChanged()
    }

    /// Saved with the next change (and when the window closes), not on every click.
    func focus(_ id: UUID) {
        guard focusedID != id, index(of: id) != nil else { return }
        focusedID = id
    }

    /// ⌃⌘1–4: the conversation at `index` takes the focus and its input the keyboard. Another one shown
    /// alone gives way to the grid; a folded one opens.
    func focusConversation(at index: Int) {
        guard conversations.indices.contains(index) else { return }
        let model = conversations[index]
        if maximizedID != nil, maximizedID != model.id { maximizedID = nil }
        if model.isCollapsed { model.isCollapsed = false }
        focusedID = model.id
        model.requestInputFocus()
    }

    /// The title bar's ⤢ / ⤡: shows the conversation alone in the chat pane (focused, opened), or all again.
    func toggleMaximize(_ id: UUID) {
        if maximizedID == id {
            maximizedID = nil
            return
        }
        guard conversations.count > 1, let model = conversations.first(where: { $0.id == id }) else { return }
        if model.isCollapsed { model.isCollapsed = false }
        maximizedID = id
        focusedID = id
    }

    /// After an add, close or move. Saves once.
    private func gridChanged() {
        openUnfoldable()
        persist()
    }

    /// A folded conversation that can no longer fold (it now shares a row, or is the only one) opens.
    private func openUnfoldable() {
        persistSuspended = true
        for model in conversations where model.isCollapsed && !canCollapse(model.id) { model.isCollapsed = false }
        persistSuspended = false
    }

    // MARK: Shared reading actions

    /// "Ask Lectern" on a PDF selection (`pages` 1-based) goes to the focused conversation, opened if
    /// it was collapsed.
    func ask(_ action: SelectionAction, selection: String, pages: [Int]) {
        guard let model = focused else { return }
        focusedID = model.id
        if maximizedID != nil, maximizedID != model.id { maximizedID = nil }
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

    /// Writes every conversation, in order (never from a second window on the same bytes).
    func persist() {
        guard !isSecondaryWindow, !persistSuspended else { return }
        let session = StoredSession(conversations: conversations.map(\.stored), focusedID: focused?.id)
        sessionStore.save(session, contentHash: document.contentHash)
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }
}

extension Array {
    /// nil past the end.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
