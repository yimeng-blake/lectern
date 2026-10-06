import Foundation

/// One Codex thread for one document, on the service's shared app-server.
@MainActor
final class CodexSession: ChatSession {
    let provider: Provider = .codex
    private(set) var isBusy = false
    /// The Codex thread id.
    private(set) var conversationId: String?
    var onEvent: ((BackendEvent) -> Void)?

    private let service: CodexService
    private var server: CodexAppServer { service.server }

    /// Server generation in which `conversationId` was started or resumed; anything else needs thread/resume.
    private var loadedGeneration: Int?
    private var subscription: (threadId: String, token: UUID)?
    private var exitToken: UUID?
    private var turn: Turn?
    /// Turns we already reported, so their late notifications are dropped.
    private var finishedTurnIds: Set<String> = []
    /// The thread may still carry a skill turn's cwd/sandbox overrides (they persist): after a skill turn
    /// and after thread/resume, the next reader turn sends the reader settings explicitly.
    private var restoreReaderMode = false
    /// A skill-mode developer note went into the thread; the next reader turn adds the note that ends it.
    private var skillNotePending = false

    private final class Turn {
        var threadId: String?
        var turnId: String?
        /// Set just before turn/start goes out; earlier thread notifications belong to older turns.
        var started = false
        var interruptRequested = false
        var interruptSent = false
        var sentThinking = false
        var streamed = ""
        var messages: [String] = []
        var lastError: JSONObject?
        var usage: TurnUsage?
        var quotaAtStart: QuotaSnapshot?
        var watchdog: Task<Void, Never>?
    }

    init(service: CodexService, conversationId: String?) {
        self.service = service
        self.conversationId = conversationId
        exitToken = service.server.addExitListener { [weak self] message in self?.serverExited(message) }
    }

    // MARK: ChatSession

    func send(_ request: TurnRequest, settings: TurnSettings) {
        guard turn == nil else { return }
        let t = Turn()
        t.quotaAtStart = service.quota
        turn = t
        isBusy = true
        Task { await run(t, request, settings) }
    }

    func interrupt() {
        guard let t = turn else { return }
        t.interruptRequested = true
        sendInterrupt(t, watchdog: true)
    }

    func resetConversation() {
        if let t = turn { abandon(t) }
        unsubscribe()
        conversationId = nil
        loadedGeneration = nil
    }

    func shutdown() {
        if let t = turn { abandon(t) }
        unsubscribe()
        loadedGeneration = nil
        if let exitToken { server.removeListener(exitToken) }
        exitToken = nil
    }

    // MARK: Turn

    private func run(_ t: Turn, _ request: TurnRequest, _ settings: TurnSettings) async {
        if let error = await service.preflight() {
            finish(t, .failed(error))
            return
        }
        if let skill = request.skill, let problem = CodexSkillMode.problem(skill) {
            finish(t, .failed(.api(problem)))
            return
        }
        let config = await service.turnConfig(for: settings)
        guard isCurrent(t) else { return }
        guard let config else {
            finish(t, .failed(.api(CodexService.noTurnConfigMessage)))
            return
        }
        do {
            guard let threadId = try await ensureThread(config, for: t), isCurrent(t) else { return }
            t.threadId = threadId
            if request.skill != nil {
                try? await service.prepareSkillRoots()
                let servers = await service.mcpServersWithTools(threadId: threadId)
                guard isCurrent(t) else { return }
                if !servers.isEmpty {
                    finish(t, .failed(.api("This conversation still has Codex tools from MCP servers or apps (\(servers.joined(separator: ", "))), so Lectern won't run a skill in it. Start a new chat and try again.")))
                    return
                }
            }
            // The thread's developer instructions forbid tools; a developer note (thread history, not the
            // user's message) lifts that for the skill turn, and another one restores it afterwards.
            if let skill = request.skill {
                skillNotePending = true
                await injectDeveloperNote(CodexSkillMode.startNote(skill), threadId: threadId)
            } else if skillNotePending, await injectDeveloperNote(CodexSkillMode.endNote, threadId: threadId) {
                skillNotePending = false
            }
            guard isCurrent(t) else { return }
            if t.interruptRequested {
                finish(t, .interrupted)
                return
            }
            if let warning = service.billingWarning { emit(.warning(warning)) }
            emit(.sessionReady(model: config.model))

            var input: [JSONObject] = []
            var text = request.text
            if let skill = request.skill {
                input.append(CodexSkillMode.input(skill.skill))
                text = CodexSkillMode.preamble(skill) + "\n\n" + text
            }
            input.append(["type": "text", "text": text, "text_elements": [Any]()])
            for image in request.imagePNGs {
                input.append(["type": "localImage", "path": image.path, "detail": "high"])
            }
            var params: JSONObject = ["threadId": threadId, "input": input, "serviceTier": config.serviceTier,
                                      "model": config.model, "effort": config.effort]
            if let skill = request.skill {
                params.merge(CodexSkillMode.overrides(skill)) { $1 }
                restoreReaderMode = true
            } else if restoreReaderMode {
                params.merge(CodexSkillMode.readerOverrides(cwd: service.workingDirectory())) { $1 }
            }

            t.started = true
            let result = try await server.request("turn/start", params, timeout: 60)
            if request.skill == nil { restoreReaderMode = false }
            // Notifications for this turn may already have been handled (even turn/completed).
            if t.turnId == nil, let id = result.obj("turn")?.str("id") { t.turnId = id }
            if t.interruptRequested { sendInterrupt(t, watchdog: isCurrent(t)) }
        } catch {
            // If the thread was unloaded under us, the next send re-attaches with thread/resume.
            if case CodexAppServer.Failure.rpc = error { loadedGeneration = nil }
            finish(t, .failed(CodexService.backendError(error)))
        }
    }

    /// Starts the thread, or resumes it when it isn't loaded in the current app-server process.
    /// nil = this attempt is over: the session was shut down or reset meanwhile, or the thread could not
    /// be resumed (`.conversationReset` ended the turn so the app rebuilds the prompt for a new thread).
    private func ensureThread(_ config: CodexService.TurnConfig, for t: Turn) async throws -> String? {
        if let threadId = conversationId {
            if loadedGeneration == server.generation, server.isRunning { return threadId }
            var params = await threadParams(config)
            guard isCurrent(t) else { return nil }
            params["threadId"] = threadId
            params["excludeTurns"] = true
            subscribe(threadId)
            do {
                _ = try await server.request("thread/resume", params, timeout: 60)
                guard isCurrent(t) else {
                    // Shut down or reset meanwhile: its unsubscribe skipped thread/unsubscribe because the
                    // thread was not loaded yet.
                    if subscription?.threadId != threadId { release(threadId) }
                    return nil
                }
                loadedGeneration = server.generation
                // Its last turn may have been a skill turn (overrides persist in the rollout).
                restoreReaderMode = true
                return threadId
            } catch CodexAppServer.Failure.rpc {
                unsubscribe()
                guard isCurrent(t) else { return nil }
                // Thread missing or unreadable. The prompt was built for it (pages "provided earlier"), so
                // don't send it to a new thread: end the attempt and let the app rebuild it.
                conversationId = nil
                loadedGeneration = nil
                finish(t, .conversationReset)
                return nil
            }
        }
        var params = await threadParams(config)
        guard isCurrent(t) else { return nil }
        params["ephemeral"] = false
        let result = try await server.request("thread/start", params, timeout: 60)
        guard let threadId = result.obj("thread")?.str("id") else {
            throw CodexAppServer.Failure.rpc(code: -32603, message: "Codex did not return a thread id.")
        }
        guard isCurrent(t) else {
            // Shut down or reset while the thread was starting: nobody will use it.
            release(threadId)
            return nil
        }
        conversationId = threadId
        loadedGeneration = server.generation
        restoreReaderMode = false
        skillNotePending = false
        subscribe(threadId)
        return threadId
    }

    /// thread/inject_items: one developer message appended to the thread's model-visible history.
    @discardableResult
    private func injectDeveloperNote(_ text: String, threadId: String) async -> Bool {
        let item: JSONObject = ["type": "message", "role": "developer",
                                "content": [["type": "input_text", "text": text] as JSONObject]]
        return (try? await server.request("thread/inject_items", ["threadId": threadId, "items": [item]])) != nil
    }

    /// Reader settings for thread/start and thread/resume; `config` keeps apps, plugins, hooks and MCP
    /// servers off the thread (CodexService.threadConfig).
    private func threadParams(_ config: CodexService.TurnConfig) async -> JSONObject {
        let threadConfig = await service.threadConfig()
        return [
            "model": config.model,
            "serviceTier": config.serviceTier,
            "cwd": service.workingDirectory().path,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "developerInstructions": ReaderPrompt.system,
            "config": threadConfig,
        ]
    }

    /// thread/unsubscribe for a loaded thread no session listens to.
    private func release(_ threadId: String) {
        if !server.hasThreadListeners(threadId) { server.post("thread/unsubscribe", ["threadId": threadId]) }
    }

    private func sendInterrupt(_ t: Turn, watchdog: Bool) {
        guard !t.interruptSent, let threadId = t.threadId, let turnId = t.turnId else { return }
        t.interruptSent = true
        server.post("turn/interrupt", ["threadId": threadId, "turnId": turnId])
        guard watchdog else { return }
        // turn/completed (interrupted) normally follows within a second; don't hang the UI if it doesn't.
        t.watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(t, .interrupted)
        }
    }

    /// Ends the turn now (reset/shutdown); the server-side turn is interrupted in the background.
    private func abandon(_ t: Turn) {
        t.interruptRequested = true
        sendInterrupt(t, watchdog: false)
        finish(t, .interrupted)
    }

    private func isCurrent(_ t: Turn) -> Bool { turn === t }

    private func finish(_ t: Turn, _ event: BackendEvent) {
        guard turn === t else { return }
        turn = nil
        isBusy = false
        t.watchdog?.cancel()
        if let id = t.turnId { finishedTurnIds.insert(id) }
        if let quota = service.quota, quota != t.quotaAtStart { emit(.quota(quota)) }
        emit(event)
    }

    private func emit(_ event: BackendEvent) { onEvent?(event) }

    // MARK: Notifications

    private func subscribe(_ threadId: String) {
        if subscription?.threadId == threadId { return }
        unsubscribe()
        let token = server.addThreadListener(threadId) { [weak self] method, params in
            self?.handle(method, params)
        }
        subscription = (threadId, token)
    }

    private func unsubscribe() {
        guard let subscription else { return }
        server.removeThreadListener(subscription.threadId, subscription.token)
        self.subscription = nil
        // Another session on the same thread (same document twice) keeps it loaded.
        if loadedGeneration == server.generation { release(subscription.threadId) }
    }

    private func handle(_ method: String, _ params: JSONObject) {
        guard let t = turn, t.started else { return }
        // Only turn/started (or the turn/start reply) names our turn: thread/resume replays
        // notifications such as thread/tokenUsage/updated that carry the previous turn's id.
        let id = params.str("turnId") ?? params.obj("turn")?.str("id")
        if method == "turn/started", t.turnId == nil, let id, !finishedTurnIds.contains(id) {
            t.turnId = id
            if t.interruptRequested { sendInterrupt(t, watchdog: true) }
        }
        if let id, id != t.turnId { return }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params.str("delta"), !delta.isEmpty {
                t.streamed += delta
                emit(.textDelta(delta))
            }
        case "item/started":
            switch params.obj("item")?.str("type") {
            case "reasoning":
                if !t.sentThinking {
                    t.sentThinking = true
                    emit(.thinking)
                }
            case "agentMessage":
                // Keep the streamed text shaped like the final one (messages joined by a blank line).
                if !t.streamed.isEmpty {
                    t.streamed += "\n\n"
                    emit(.textDelta("\n\n"))
                }
            case "commandExecution", "fileChange", "webSearch", "imageGeneration", "mcpToolCall",
                 "dynamicToolCall", "collabAgentToolCall":
                // Skill turns work with tools for a while before any text: show that something happens.
                if !t.sentThinking, t.streamed.isEmpty {
                    t.sentThinking = true
                    emit(.thinking)
                }
            default:
                break
            }
        case "item/completed":
            if let item = params.obj("item"), item.str("type") == "agentMessage", let text = item.str("text") {
                t.messages.append(text)
            }
        case "error":
            if params.bool("willRetry") != true { t.lastError = params.obj("error") }
        case "thread/tokenUsage/updated":
            if let last = params.obj("tokenUsage")?.obj("last") {
                t.usage = TurnUsage(inputTokens: last.int("inputTokens"), cachedInputTokens: last.int("cachedInputTokens"),
                                    outputTokens: last.int("outputTokens"))
            }
        case "model/rerouted":
            if let model = params.str("toModel") { emit(.sessionReady(model: model)) }
        case "turn/completed":
            completed(t, params.obj("turn") ?? [:])
        default:
            break
        }
    }

    private func completed(_ t: Turn, _ turnInfo: JSONObject) {
        switch turnInfo.str("status") {
        case "completed":
            var text = t.messages.joined(separator: "\n\n")
            if text.isEmpty {
                text = turnInfo.objs("items").filter { $0.str("type") == "agentMessage" }
                    .compactMap { $0.str("text") }.joined(separator: "\n\n")
            }
            if text.isEmpty { text = t.streamed }
            var usage = t.usage
            if let duration = turnInfo.int("durationMs") {
                if usage == nil { usage = TurnUsage() }
                usage?.durationMs = duration
            }
            let clean = ReaderPrompt.stripDirectives(text).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(t, .completed(text: clean, usage: usage))
        case "interrupted":
            finish(t, .interrupted)
        default:
            finish(t, .failed(failure(turnInfo.obj("error") ?? t.lastError)))
        }
    }

    /// Maps a TurnError. A missing login surfaces as `httpConnectionFailed` with status 401 rather
    /// than "unauthorized", so both count as auth failures.
    private func failure(_ error: JSONObject?) -> BackendError {
        let message = error?.str("message") ?? "The ChatGPT turn failed."
        let info = error?["codexErrorInfo"]
        if (info as? String) == "unauthorized" || Self.httpStatus(info) == 401 {
            service.markAuthExpired(CodexService.expiredMessage)
            return .authRequired(CodexService.expiredMessage)
        }
        if (info as? String) == "usageLimitExceeded" { return .usageLimit(message) }
        return .api(message)
    }

    static func httpStatus(_ info: Any?) -> Int? {
        guard let variant = (info as? JSONObject)?.values.first as? JSONObject else { return nil }
        return variant.int("httpStatusCode")
    }

    private func serverExited(_ message: String) {
        guard let t = turn else { return }
        finish(t, .failed(.processExited(message)))
    }
}
