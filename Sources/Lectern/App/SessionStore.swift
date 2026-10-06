import Foundation
import LecternCore

/// What is remembered about one document between launches.
struct StoredSession: Codable, Equatable {
    /// Claude session UUID; only set once a turn completed under it.
    var claudeSessionId: String?
    /// Codex thread id; only set once a turn completed in it.
    var codexThreadId: String?
    var messages: [ChatMessage]
    /// Where the reader was (page, zoom, layout). Optional: files from before it existed decode as nil.
    var viewer: ViewerState?

    init(claudeSessionId: String? = nil, codexThreadId: String? = nil, messages: [ChatMessage] = [],
         viewer: ViewerState? = nil) {
        self.claudeSessionId = claudeSessionId
        self.codexThreadId = codexThreadId
        self.messages = messages
        self.viewer = viewer
    }

    private enum CodingKeys: String, CodingKey { case claudeSessionId, codexThreadId, messages, viewer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        codexThreadId = try c.decodeIfPresent(String.self, forKey: .codexThreadId)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        // A viewer entry that can't be read must not cost the saved chat.
        viewer = try? c.decodeIfPresent(ViewerState.self, forKey: .viewer)
    }

    func conversationId(for provider: Provider) -> String? {
        switch provider {
        case .claude: return claudeSessionId
        case .codex: return codexThreadId
        }
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

    /// Saves the chat. A session without viewer state keeps the one already on disk (ChatModel doesn't
    /// track it; ReaderController saves it with `saveViewer`).
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
    /// "thumbnails" or "contents".
    var sidebarMode: String?
    var chatVisible: Bool?
}
