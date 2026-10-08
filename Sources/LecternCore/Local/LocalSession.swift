import Foundation

/// One "On This Mac" conversation. Ollama is stateless, so the session keeps the conversation's messages
/// and sends them every turn; Apple's model keeps its own transcript in one LanguageModelSession per
/// conversation. When the conversation no longer fits the model's window, the turn ends with
/// `.conversationReset` and the app resends a rebuilt prompt to a fresh conversation. Conversations live
/// in memory only (`conversationId` is nil), so a relaunch starts fresh, as SessionStore expects.
@MainActor
public final class LocalSession: ChatSession {
    public let provider: Provider = .local
    public private(set) var isBusy = false
    public var conversationId: String? { nil }
    public var onEvent: ((BackendEvent) -> Void)?

    private struct Exchange {
        let user: String
        /// Base64 PNGs, sent again every turn so a vision model can still see them.
        let images: [String]
        let answer: String
        let viaApple: Bool
    }

    private struct Turn {
        let id: Int
        var task: Task<Void, Never>?
        var stopRequested = false
        var said = ""
    }

    private let service: LocalService
    private var exchanges: [Exchange] = []
    /// Estimated tokens of `exchanges`.
    private var memoryTokens = 0
    /// AppleConversation (macOS 26+); valid while every exchange so far went through it.
    private var apple: AnyObject?
    private var turn: Turn?
    private var turnCounter = 0
    private var warnedNoImages = false

    init(service: LocalService) {
        self.service = service
    }

    deinit {
        turn?.task?.cancel()
    }

    // MARK: - ChatSession

    public func send(_ request: TurnRequest, settings: TurnSettings) {
        guard turn == nil else { return }
        turnCounter += 1
        let id = turnCounter
        turn = Turn(id: id)
        isBusy = true
        let modelId = settings.model.isEmpty ? service.defaultModelId : settings.model
        guard request.skill == nil else {
            finishLater(.failed(.api("Skills aren't available for models on this Mac.")))
            return
        }
        guard let modelId else {
            let reason = service.unusableReason
            finishLater(.failed(.notInstalled(reason.isEmpty ? "No model on this Mac is ready yet." : reason)))
            return
        }
        turn?.task = Task { [weak self] in
            guard let self else { return }
            if modelId == LocalService.appleModelId {
                await self.runApple(id: id, request: request)
            } else if modelId.hasPrefix("ollama:") {
                await self.runOllama(id: id, name: String(modelId.dropFirst("ollama:".count)), request: request)
            } else {
                self.finish(id, .failed(.api("Unknown model “\(modelId)”. Pick a model on this Mac.")))
            }
        }
    }

    public func interrupt() {
        guard var current = turn, !current.stopRequested else { return }
        current.stopRequested = true
        turn = current
        current.task?.cancel()
        // Text already shown counts as said: the app then treats its pages as sent.
        if !current.said.isEmpty, let pending = pendingUser {
            remember(Exchange(user: pending.text, images: pending.images, answer: current.said, viaApple: pending.viaApple))
        }
        finishLater(.interrupted)
    }

    public func resetConversation() {
        if let id = turn?.id {
            turn?.task?.cancel()
            finish(id, .interrupted)
        }
        forget()
    }

    public func shutdown() {
        if let id = turn?.id {
            turn?.task?.cancel()
            finish(id, .interrupted)
        }
        apple = nil
    }

    // MARK: - Ollama

    /// The current turn's message as sent, for recording an interrupted exchange.
    private var pendingUser: (text: String, images: [String], viaApple: Bool)?

    private func runOllama(id: Int, name: String, request: TurnRequest) async {
        guard let model = await service.ollamaModel(name) else {
            if case .ready = service.ollamaStatus {
                finish(id, .failed(.api("“\(name)” isn't downloaded on this Mac. Pick another model or download it again.")))
            } else {
                finish(id, .failed(.notInstalled("Ollama isn't running. Open Ollama, then ask again.")))
            }
            return
        }
        guard isCurrent(id) else { return }
        emit(.sessionReady(model: "ollama:\(name)"))
        emit(.thinking)

        var images: [String] = []
        if !request.imagePNGs.isEmpty {
            if model.capabilities.contains("vision") {
                images = request.imagePNGs.compactMap { try? Data(contentsOf: $0).base64EncodedString() }
            } else {
                warnNoImages(LocalService.displayName(name))
            }
        }
        let numCtx = LocalModelLimits.ollamaContextLength(modelMax: model.contextLength)
        let answerRoom = min(2_048, numCtx / 4)
        let room = numCtx - answerRoom - LocalModelLimits.tokens(ReaderPrompt.system)
        let imageCost = images.count * ContextBuilder.imageTokenAllowance
        var text = request.text
        if memoryTokens + LocalModelLimits.tokens(text) + imageCost > room {
            guard exchanges.isEmpty else {
                forget()
                finish(id, .conversationReset)
                return
            }
            let fitted = LocalPromptFitter.fit(text, maxTokens: room - imageCost)
            text = fitted.text
            if fitted.trimmed {
                emit(.warning("\(LocalService.displayName(name)) can read about \(Self.words(room)) words at a time, so some page text was left out."))
            }
        }
        pendingUser = (text, images, false)

        var messages: [JSONObject] = [["role": "system", "content": ReaderPrompt.system]]
        for e in exchanges {
            var user: JSONObject = ["role": "user", "content": e.user]
            if !e.images.isEmpty { user["images"] = e.images }
            messages.append(user)
            messages.append(["role": "assistant", "content": e.answer])
        }
        var user: JSONObject = ["role": "user", "content": text]
        if !images.isEmpty { user["images"] = images }
        messages.append(user)
        var body: JSONObject = ["model": name, "messages": messages, "stream": true, "keep_alive": "10m",
                                "options": ["num_ctx": numCtx, "num_predict": answerRoom]]
        // Quick answers: reasoning on a small Mac can take minutes.
        if model.capabilities.contains("thinking") { body["think"] = false }

        var filter = ThinkTagFilter()
        var answer = ""
        var usage: TurnUsage?
        do {
            let bytes = try await service.client.openStream("/api/chat", body)
            for try await line in bytes.lines {
                guard isCurrent(id) else { return }
                guard let obj = JSONLine.parse(line) else { continue }
                if let error = obj.str("error") { throw OllamaError.server(status: 200, message: error) }
                // `.thinking` went out at the start; the app shows it until text arrives (reasoning included).
                if let message = obj.obj("message") {
                    say(filter.consume(message.str("content") ?? ""), id: id, into: &answer)
                }
                if obj.bool("done") == true {
                    usage = TurnUsage(inputTokens: obj.int("prompt_eval_count"), outputTokens: obj.int("eval_count"),
                                      durationMs: obj.int("total_duration").map { $0 / 1_000_000 })
                    break
                }
            }
            say(filter.flush(), id: id, into: &answer)
        } catch {
            guard isCurrent(id) else { return }
            if OllamaError.isUnreachable(error) {
                service.markAuthExpired("Ollama stopped")
                finish(id, .failed(.notInstalled("Ollama isn't running. Open Ollama, then ask again.")))
            } else if case OllamaError.server(let status, let message) = error {
                if status == 404 { service.reloadModels() }
                finish(id, .failed(.api(status == 404
                    ? "“\(name)” isn't downloaded on this Mac anymore. Pick another model or download it again."
                    : "Ollama couldn't answer: \(message)")))
            } else {
                finish(id, .failed(.api("Ollama couldn't answer: \(error.localizedDescription)")))
            }
            return
        }
        guard isCurrent(id) else { return }
        complete(id, answer: answer, usage: usage)
    }

    // MARK: - Apple

    private func runApple(id: Int, request: TurnRequest) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            await runAppleModel(id: id, request: request)
            return
        }
        #endif
        finish(id, .failed(.notInstalled("Apple's on-device model needs macOS 26 with Apple Intelligence.")))
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func runAppleModel(id: Int, request: TurnRequest) async {
        guard case .available = AppleModel.status() else {
            service.markAuthExpired("Apple Intelligence unavailable")
            let reason: String
            if case .unavailable(let why) = AppleModel.status() { reason = why } else {
                reason = "Apple Intelligence isn't available on this Mac."
            }
            finish(id, .failed(.notInstalled(reason)))
            return
        }
        // Apple's session only knows what went through it; a conversation started on an Ollama model
        // can't continue here.
        if !exchanges.isEmpty, !(apple is AppleConversation) || exchanges.contains(where: { !$0.viaApple }) {
            forget()
            finish(id, .conversationReset)
            return
        }
        emit(.sessionReady(model: LocalService.appleModelId))
        emit(.thinking)
        if !request.imagePNGs.isEmpty { warnNoImages("Apple's on-device model") }

        let answerRoom = 900
        let room = LocalModelLimits.appleContextTokens - LocalModelLimits.tokens(AppleModel.instructions) - answerRoom
        var text = request.text
        if memoryTokens + LocalModelLimits.tokens(text) > room, !exchanges.isEmpty {
            forget()
            finish(id, .conversationReset)
            return
        }
        for attempt in 0..<2 {
            let limit = attempt == 0 ? room : room * 2 / 3
            let fitted = LocalPromptFitter.fit(text, maxTokens: limit)
            if fitted.trimmed, attempt == 0 {
                emit(.warning("Apple's on-device model can read about \(Self.words(room)) words at a time, so some page text was left out."))
            }
            text = fitted.text
            pendingUser = (text, [], true)
            let conversation = (apple as? AppleConversation) ?? AppleConversation()
            apple = conversation
            var answer = ""
            do {
                let full = try await conversation.respond(to: text, maxAnswerTokens: answerRoom) { [weak self] delta in
                    self?.say(delta, id: id, into: &answer)
                }
                guard isCurrent(id) else { return }
                complete(id, answer: full.isEmpty ? answer : full, usage: nil)
                return
            } catch AppleModel.Failure.contextExceeded where exchanges.isEmpty && attempt == 0 && answer.isEmpty {
                apple = nil   // the failed prompt may sit in its transcript
                continue
            } catch {
                guard isCurrent(id) else { return }
                switch error as? AppleModel.Failure {
                case .contextExceeded where !exchanges.isEmpty:
                    forget()
                    finish(id, .conversationReset)
                case .contextExceeded:
                    if exchanges.isEmpty { apple = nil }
                    finish(id, .failed(.api("This is too long for Apple's on-device model. Select a shorter passage, or pick an Ollama model.")))
                case .cancelled:
                    finish(id, .interrupted)
                case .failed(let e):
                    if exchanges.isEmpty { apple = nil }
                    if case .notInstalled = e { service.markAuthExpired(e.message) }
                    finish(id, .failed(e))
                case nil:
                    finish(id, .failed(.api(error.localizedDescription)))
                }
                return
            }
        }
    }
    #endif

    // MARK: - Turn plumbing

    private func say(_ piece: String, id: Int, into answer: inout String) {
        let delta = answer.isEmpty ? String(piece.drop { $0.isWhitespace }) : piece
        guard !delta.isEmpty, isCurrent(id) else { return }
        answer += delta
        turn?.said = answer
        onEvent?(.textDelta(delta))
    }

    private func complete(_ id: Int, answer: String, usage: TurnUsage?) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finish(id, .failed(.api("The model finished without an answer. Try asking again.")))
            return
        }
        if let pending = pendingUser {
            remember(Exchange(user: pending.text, images: pending.images, answer: text, viaApple: pending.viaApple))
        }
        finish(id, .completed(text: text, usage: usage))
    }

    private func remember(_ e: Exchange) {
        exchanges.append(e)
        memoryTokens += LocalModelLimits.tokens(e.user) + LocalModelLimits.tokens(e.answer)
            + e.images.count * ContextBuilder.imageTokenAllowance
        pendingUser = nil
    }

    private func forget() {
        exchanges = []
        memoryTokens = 0
        apple = nil
        pendingUser = nil
    }

    /// Live and not stopped: events for this turn may still be delivered.
    private func isCurrent(_ id: Int) -> Bool {
        guard let t = turn, t.id == id, !t.stopRequested else { return false }
        return !Task.isCancelled
    }

    private func emit(_ event: BackendEvent) {
        onEvent?(event)
    }

    private func warnNoImages(_ model: String) {
        guard !warnedNoImages else { return }
        warnedNoImages = true
        emit(.warning("\(model) can't see page images, so it reads the page text only."))
    }

    /// Delivers the turn's single terminal event. After Stop, only `.interrupted` (already on its way).
    private func finish(_ id: Int, _ event: BackendEvent) {
        guard let current = turn, current.id == id else { return }
        if current.stopRequested, !Self.isInterrupted(event) { return }
        turn = nil
        isBusy = false
        pendingUser = nil
        onEvent?(event)
    }

    /// Terminal event decided inside send()/interrupt(): delivered on the next main-queue pass.
    private func finishLater(_ event: BackendEvent) {
        guard let id = turn?.id else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.finish(id, event) }
        }
    }

    private static func isInterrupted(_ event: BackendEvent) -> Bool {
        if case .interrupted = event { return true }
        return false
    }

    private static func words(_ tokens: Int) -> String {
        let n = max(100, tokens * 3 / 4 / 100 * 100)
        return ContextBuilder.formatted(n)
    }
}
