import Foundation

/// The local Ollama server's HTTP API: /api/version, /api/tags, /api/show, /api/chat and /api/pull
/// (NDJSON streams). Lectern only uses models that run on this Mac; cloud models are filtered out.
struct OllamaClient: Sendable {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        // Idle time between bytes: loading a large model before the first token can take minutes.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Server version, or nil when nothing answers on the port.
    func version() async -> String? {
        (try? await get("/api/version", timeout: 2))?.str("version")
    }

    /// Installed models that run locally (no `-cloud` / remote models).
    func tags() async throws -> [OllamaModel] {
        try await get("/api/tags", timeout: 5).objs("models").compactMap { m in
            guard let name = m.str("name") ?? m.str("model"),
                  m["remote_host"] == nil, m["remote_model"] == nil,
                  !name.hasSuffix("-cloud"), !name.hasSuffix(":cloud") else { return nil }
            return OllamaModel(name: name, digest: m.str("digest") ?? name,
                               sizeBytes: (m["size"] as? NSNumber)?.int64Value ?? 0,
                               modified: OllamaModel.date(m.str("modified_at")),
                               family: m.obj("details")?.str("family") ?? "")
        }
    }

    /// (capabilities, the model's own context window) from /api/show.
    func show(_ name: String) async -> (capabilities: [String], contextLength: Int?)? {
        guard let obj = try? await post("/api/show", ["model": name], timeout: 10) else { return nil }
        let info = obj.obj("model_info") ?? [:]
        let ctx = info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
        return ((obj["capabilities"] as? [String]) ?? [], ctx)
    }

    /// Opens an NDJSON stream; a non-200 reply throws with the server's message.
    func openStream(_ path: String, _ body: JSONObject) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request(path, body: body, timeout: 600))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw OllamaError.server(status: status, message: JSONLine.parse(text)?.str("error") ?? "HTTP \(status)")
        }
        return bytes
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> JSONObject {
        try await call(request(path, body: nil, timeout: timeout))
    }

    private func post(_ path: String, _ body: JSONObject, timeout: TimeInterval) async throws -> JSONObject {
        try await call(request(path, body: body, timeout: timeout))
    }

    private func call(_ req: URLRequest) async throws -> JSONObject {
        let (data, response) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OllamaError.server(status: status, message: obj.str("error") ?? "HTTP \(status)") }
        return obj
    }

    private func request(_ path: String, body: JSONObject?, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(JSONLine.encode(body).utf8)
        }
        return req
    }
}

enum OllamaError: Error {
    case server(status: Int, message: String)

    /// Nothing listens on the port (Ollama quit) or the connection dropped.
    static func isUnreachable(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet].contains(e.code)
    }
}

struct OllamaModel: Equatable, Sendable {
    let name: String
    let digest: String
    let sizeBytes: Int64
    let modified: Date?
    let family: String
    var capabilities: [String] = []
    var contextLength: Int?

    /// Chat-capable; embedding-only models (e.g. nomic-embed-text) can't answer questions.
    var canChat: Bool {
        if !capabilities.isEmpty { return capabilities.contains("completion") }
        return !family.contains("bert") && !name.contains("embed")
    }

    /// "2026-04-11T22:00:01.939896323-07:00" (nanoseconds, which ISO8601DateFormatter can't read).
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// Context sizes for "On This Mac" models. Nonisolated so ContextBuilder can ask for budgets.
public enum LocalModelLimits {
    /// Apple's on-device model: instructions, conversation and answer share ~4K tokens.
    public static let appleContextTokens = 4_096

    /// Model tokens for prompt text. ContextBuilder's estimate (chars/4 for Latin text) runs 15–35% low
    /// for these models' tokenizers on page text, and ~2.3x low on outlines (numbers, symbols).
    static func tokens(_ text: String) -> Int {
        ContextBuilder.estimateTokens(text) * 7 / 5
    }

    /// num_ctx for an Ollama model: by this Mac's memory (the KV cache grows with it), capped at the
    /// model's own window. Ollama's default can be as small as 4K, which silently drops page text.
    public static func ollamaContextLength(modelMax: Int?) -> Int {
        let gb = ProcessInfo.processInfo.physicalMemory >> 30
        let byMemory = gb >= 32 ? 32_768 : gb >= 16 ? 16_384 : 8_192
        return max(2_048, min(byMemory, modelMax ?? byMemory))
    }

    /// ContextBuilder's whole-document budget (estimated tokens) for "apple.on-device", "ollama:<name>"
    /// or "" (the service's current default model): what's left of the window after instructions,
    /// conversation and the answer, with the estimate's undercount.
    public static func contextBudget(for modelId: String) -> Int {
        let id = modelId.isEmpty ? (store.read { $0.defaultModel } ?? "") : modelId
        guard id.hasPrefix("ollama:") else { return 2_000 }
        let name = String(id.dropFirst("ollama:".count))
        return ollamaContextLength(modelMax: store.read { $0.contextLengths[name] }) * 2 / 5
    }

    static func remember(contextLengths: [String: Int], defaultModel: String?) {
        store.write {
            $0.contextLengths = contextLengths
            $0.defaultModel = defaultModel
        }
    }

    private struct State {
        var contextLengths: [String: Int] = [:]
        var defaultModel: String?
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()
        func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
        func write(_ body: (inout State) -> Void) { lock.lock(); body(&state); lock.unlock() }
    }

    private static let store = Store()
}
