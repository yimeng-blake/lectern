import Foundation
import LecternCore

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, notice }
    enum Status: String, Codable { case streaming, thinking, done, interrupted, failed, waitingForLogin }

    let id: UUID
    var role: Role
    var provider: Provider
    /// Resolved model name for assistant messages.
    var model: String?
    /// Markdown for assistant messages, plain text for user messages and notices.
    var text: String
    var status: Status
    /// Set when status == .failed.
    var errorText: String?
    /// 1-based pages sent as context with this user message.
    var pages: [Int]
    var createdAt: Date
    /// Assistant messages: the answer's [p. N] citations checked against the cited pages, in order.
    /// Optional, so sessions saved before it existed still decode.
    var citationChecks: [CitationCheck]?
}

extension ChatMessage {
    init(role: Role, provider: Provider, text: String, status: Status = .done, model: String? = nil) {
        self.init(id: UUID(), role: role, provider: provider, model: model, text: text, status: status,
                  errorText: nil, pages: [], createdAt: Date(), citationChecks: nil)
    }
}
