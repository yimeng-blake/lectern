import Foundation
import LecternCore

/// One conversation panel as saved: its title, provider, backend conversation ids and transcript.
struct StoredConversation: Codable, Equatable, Identifiable {
    static let defaultTitle = "New conversation"

    var id: UUID
    var title: String
    /// The user named it; automatic titles never replace a custom one.
    var titleIsCustom: Bool
    /// The provider the panel showed; nil means the app's last provider.
    var provider: Provider?
    /// Claude session UUID; only set once a turn completed under it.
    var claudeSessionId: String?
    var grokSessionId: String?
    /// Codex thread id; only set once a turn completed in it.
    var codexThreadId: String?
    var messages: [ChatMessage]
    /// The panel showed only its title bar.
    var collapsed: Bool
    /// The conversation's color; nil in files from before colors (the stack assigns them by order).
    var colorTag: ConversationTag?

    init(id: UUID = UUID(), title: String = Self.defaultTitle, titleIsCustom: Bool = false,
         provider: Provider? = nil, claudeSessionId: String? = nil, codexThreadId: String? = nil,
         messages: [ChatMessage] = [], collapsed: Bool = false, colorTag: ConversationTag? = nil) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.provider = provider
        self.claudeSessionId = claudeSessionId
        self.codexThreadId = codexThreadId
        self.messages = messages
        self.collapsed = collapsed
        self.colorTag = colorTag
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleIsCustom, provider, claudeSessionId, codexThreadId, grokSessionId, messages, collapsed, colorTag
    }

    /// Lenient: a missing or unknown field (a newer Lectern's provider, say) must not cost the messages.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        let title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultTitle : title
        titleIsCustom = (try? c.decodeIfPresent(Bool.self, forKey: .titleIsCustom)) ?? false
        provider = try? c.decodeIfPresent(Provider.self, forKey: .provider)
        claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        codexThreadId = try c.decodeIfPresent(String.self, forKey: .codexThreadId)
        grokSessionId = try c.decodeIfPresent(String.self, forKey: .grokSessionId)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        colorTag = try? c.decodeIfPresent(ConversationTag.self, forKey: .colorTag)
    }

    func conversationId(for provider: Provider) -> String? {
        switch provider {
        case .claude: return claudeSessionId
        case .codex: return codexThreadId
        case .grok: return grokSessionId
        case .local: return nil
        }
    }
}

/// What is remembered about one document between launches:
/// `{version: 2, conversations: [StoredConversation], focusedID, viewer}`.
/// Version 1 files (`{claudeSessionId, codexThreadId, messages, viewer}`, one conversation per
/// document) decode as a single conversation and are written back as version 2.
struct StoredSession: Codable, Equatable {
    static let currentVersion = 2
    /// Title of a migrated conversation that has no question to name it after.
    static let migratedTitle = "Conversation"

    /// In order: the panels' positions in the chat pane (see ConversationStack.gridRows).
    var conversations: [StoredConversation]
    /// The conversation Ask Lectern went to.
    var focusedID: UUID?
    /// Where the reader was (page, zoom, layout). Optional: files from before it existed decode as nil.
    var viewer: ViewerState?

    init(conversations: [StoredConversation] = [], focusedID: UUID? = nil, viewer: ViewerState? = nil) {
        self.conversations = conversations
        self.focusedID = focusedID
        self.viewer = viewer
    }

    private enum CodingKeys: String, CodingKey { case version, conversations, focusedID, viewer }
    private enum LegacyKeys: String, CodingKey { case claudeSessionId, codexThreadId, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A viewer entry that can't be read must not cost the saved chat.
        viewer = try? c.decodeIfPresent(ViewerState.self, forKey: .viewer)
        if c.contains(.conversations) {
            conversations = try c.decode([StoredConversation].self, forKey: .conversations)
            focusedID = try? c.decodeIfPresent(UUID.self, forKey: .focusedID)
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let messages = try legacy.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        let claude = try legacy.decodeIfPresent(String.self, forKey: .claudeSessionId)
        let codex = try legacy.decodeIfPresent(String.self, forKey: .codexThreadId)
        guard !messages.isEmpty || claude != nil || codex != nil else {
            // Viewer state only: there was no conversation yet.
            conversations = []
            focusedID = nil
            return
        }
        let question = messages.first { $0.role == .user }?.text
        let migrated = StoredConversation(
            title: question.map { ConversationTitler.fallbackTitle(question: $0) } ?? Self.migratedTitle,
            claudeSessionId: claude, codexThreadId: codex, messages: messages)
        conversations = [migrated]
        focusedID = migrated.id
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(conversations, forKey: .conversations)
        try c.encodeIfPresent(focusedID, forKey: .focusedID)
        try c.encodeIfPresent(viewer, forKey: .viewer)
    }
}

/// One JSON file per document, keyed by the SHA-256 of its bytes so renamed or moved copies of the
/// same PDF reopen the same conversations.
final class SessionStore: Sendable {
    let directory: URL

    init(directory: URL = AppPaths.sessions) {
        self.directory = directory
    }

    func url(for contentHash: String) -> URL {
        directory.appendingPathComponent("\(contentHash).json")
    }

    func load(contentHash: String) -> StoredSession? {
        guard let data = try? Data(contentsOf: url(for: contentHash)) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Saves the chat. A session without viewer state keeps the one already on disk (the
    /// conversations don't track it; ReaderController saves it with `saveViewer`).
    func save(_ session: StoredSession, contentHash: String) {
        var merged = session
        if merged.viewer == nil { merged.viewer = load(contentHash: contentHash)?.viewer }
        write(merged, contentHash: contentHash)
    }

    /// Updates only the viewer state, keeping the saved chat and conversation ids.
    func saveViewer(_ viewer: ViewerState, contentHash: String) {
        let file = url(for: contentHash)
        var session = StoredSession()
        if FileManager.default.fileExists(atPath: file.path) {
            // A file this version can't read (damaged, or written by a newer Lectern) keeps its chat:
            // the viewer state is simply not saved.
            guard let stored = load(contentHash: contentHash) else { return }
            session = stored
        }
        guard session.viewer != viewer else { return }
        session.viewer = viewer
        write(session, contentHash: contentHash)
    }

    private func write(_ session: StoredSession, contentHash: String) {
        do {
            let data = try JSONEncoder().encode(session)
            AppPaths.ensure(directory)
            try data.write(to: url(for: contentHash), options: .atomic)
        } catch {
            NSLog("Lectern: could not save session \(contentHash): \(error)")
        }
    }
}

/// Per-document viewer state (SessionStore). Every field is optional so older or newer files decode.
struct ViewerState: Codable, Equatable {
    /// 0-based page.
    var page: Int?
    /// ReaderController.ZoomMode raw value: "fitWidth", "fitPage" or "custom" (with `scale`).
    var zoom: String?
    var scale: Double?
    /// ReaderController.DisplayMode raw value.
    var displayMode: String?
    var sidebarVisible: Bool?
    /// "thumbnails", "contents" or "highlights".
    var sidebarMode: String?
    var chatVisible: Bool?
}
