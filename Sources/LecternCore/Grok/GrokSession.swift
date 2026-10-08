import Foundation
import Observation

/// One Grok conversation about one document: one headless `grok` process per turn, the first with
/// `-s <uuid>` and the rest with `-r <uuid>` (Grok keeps the transcript). Stop terminates the process.
@MainActor @Observable
public final class GrokSession: ChatSession {
    public let provider: Provider = .grok
    public private(set) var isBusy = false
    /// The Grok session UUID once a turn completed under it (or the id this session resumed).
    public private(set) var conversationId: String?
    @ObservationIgnored public var onEvent: ((BackendEvent) -> Void)?
    /// Every stdout line from the CLI, for diagnostics (lectern-probe `--trace`).
    @ObservationIgnored public var traceHandler: ((String) -> Void)?
    /// Command line of the latest spawn, for diagnostics.
    @ObservationIgnored public private(set) var lastArguments: [String] = []

    @ObservationIgnored var interruptGrace: TimeInterval = 5
    @ObservationIgnored private let service: GrokService
    @ObservationIgnored private var sessionId: String
    /// Grok has a session under `sessionId`, so spawns use `-r` rather than `-s`.
    @ObservationIgnored private var sessionExists: Bool
    @ObservationIgnored private var spawnedWithResume = false
    @ObservationIgnored private var process: ManagedProcess?
    /// The previous turn's process, if it is still persisting the session after its answer.
    @ObservationIgnored private var draining: ManagedProcess?
    /// Callbacks from retired processes carry an older generation and are ignored.
    @ObservationIgnored private var processGeneration = 0
    @ObservationIgnored private var turn: Turn?
    @ObservationIgnored private var turnCounter = 0
    @ObservationIgnored private var interpreter = GrokStreamInterpreter()
    @ObservationIgnored private var interruptWatchdog: Task<Void, Never>?

    private struct Turn {
        let id: Int
        let settings: TurnSettings
        let promptFile: URL
        let started = Date()
        /// One automatic rerun per turn (`-s` found the session already created).
        var restarted = false
    }

    init(service: GrokService, conversationId: String?) {
        self.service = service
        if let id = conversationId, UUID(uuidString: id) != nil {
            sessionId = id
            sessionExists = true
            self.conversationId = id
        } else {
            sessionId = UUID().uuidString.lowercased()
            sessionExists = false
        }
    }

    deinit {
        process?.terminate()
    }

    // MARK: - ChatSession

    public func send(_ request: TurnRequest, settings: TurnSettings) {
        guard turn == nil else { return }
        turnCounter += 1
        let file = GrokProtocol.promptDirectory.appendingPathComponent("\(UUID().uuidString).json")
        turn = Turn(id: turnCounter, settings: settings, promptFile: file)
        isBusy = true
        let missing: Int
        do {
            missing = try GrokProtocol.writePrompt(text: request.text, imagePNGs: request.imagePNGs, to: file)
        } catch {
            finishLater(.failed(.api("Couldn't prepare the message for Grok: \(error.localizedDescription)")))
            return
        }
        if request.skill != nil { emitLater(.warning("Skills aren't available with Grok; it answered as a reader.")) }
        if missing > 0 { emitLater(.warning("Couldn't attach \(missing) page image\(missing == 1 ? "" : "s").")) }
        startTurn()
    }

    public func interrupt() {
        guard let current = turn, !interpreter.interruptRequested else { return }
        interpreter.interruptRequested = true
        guard let p = process else { return }   // a start failure is already on its way
        p.terminate()
        interruptWatchdog?.cancel()
        let grace = interruptGrace
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self, self.turn?.id == current.id else { return }
            self.retireProcess()
            self.finish(.interrupted)
        }
    }

    public func resetConversation() {
        if turn != nil { finish(.interrupted) }
        retireProcess()
        sessionId = UUID().uuidString.lowercased()
        sessionExists = false
        conversationId = nil
    }

    public func shutdown() {
        if turn != nil { finish(.interrupted) }
        retireProcess()
    }

    // MARK: - Turn lifecycle

    private func startTurn() {
        guard let current = turn else { return }
        retireProcess()
        interpreter = GrokStreamInterpreter()
        guard let binary = service.currentBinary() else {
            finishLater(.failed(.notInstalled(service.installIssue ?? GrokProtocol.notFoundMessage)))
            return
        }
        let args = GrokProtocol.turnArguments(promptFile: current.promptFile, model: current.settings.model,
                                              effort: current.settings.effort, sessionId: sessionId,
                                              resume: sessionExists, cwd: GrokProtocol.workingDirectory)
        let p = ManagedProcess(executable: binary, arguments: args, environment: service.environment,
                               currentDirectory: GrokProtocol.workingDirectory, keepStdinOpen: false)
        processGeneration += 1
        let generation = processGeneration
        p.onStdoutLine = { [weak self] line in self?.received(line, generation: generation) }
        p.onExit = { [weak self] status, stderr in self?.exited(generation: generation, status: status, stderr: stderr) }
        lastArguments = args
        do {
            try p.start()
        } catch {
            finishLater(.failed(.processExited("Couldn't start Grok: \(error.localizedDescription)")))
            return
        }
        process = p
        spawnedWithResume = sessionExists
    }

    private func received(_ line: String, generation: Int) {
        guard generation == processGeneration, let current = turn else { return }
        traceHandler?(line)
        let outputs = interpreter.consume(line: line)
        if interpreter.sawOutput { sessionExists = true }
        for output in outputs {
            guard turn?.id == current.id else { return }
            handle(output)
        }
    }

    private func exited(generation: Int, status: Int32, stderr: String) {
        guard generation == processGeneration else { return }
        process = nil
        guard turn != nil, let output = interpreter.processExited(status: status, stderr: stderr) else { return }
        handle(output)
    }

    private func handle(_ output: GrokStreamOutput) {
        switch output {
        case .event(let event):
            onEvent?(event)
        case .turnEnded(let event):
            ended(event)
        case .sessionInUse(let detail):
            // An earlier process created the session before failing; continue it instead.
            guard var current = turn, !current.restarted, !spawnedWithResume else { return ended(.failed(.api(detail))) }
            current.restarted = true
            turn = current
            sessionExists = true
            startTurn()
        case .sessionMissing(let detail):
            retireProcess()
            // Only `-r` can name a missing session; never loop on a fresh `-s`.
            guard spawnedWithResume else { return ended(.failed(.api(detail))) }
            sessionId = UUID().uuidString.lowercased()
            sessionExists = false
            conversationId = nil
            finish(.conversationReset)
        }
    }

    private func ended(_ event: BackendEvent) {
        guard let current = turn else { return }
        switch event {
        case .completed(let text, let usage):
            if let id = interpreter.sessionId, UUID(uuidString: id) != nil { sessionId = id }
            conversationId = sessionId
            service.turnSucceeded()
            var timed = usage ?? TurnUsage()
            timed.durationMs = Int(Date().timeIntervalSince(current.started) * 1000)
            // The answer is in; the process may still be persisting the session. Give it a moment to exit.
            retireProcess(after: 10)
            finish(.completed(text: text, usage: timed))
        case .failed(let error):
            if error.isAuth { service.markAuthExpired(error.message) }
            retireProcess()
            finish(event)
        default:
            retireProcess()
            finish(event)
        }
    }

    /// Delivers the turn's single terminal event.
    private func finish(_ event: BackendEvent) {
        guard let current = turn else { return }
        turn = nil
        isBusy = false
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        try? FileManager.default.removeItem(at: current.promptFile)
        onEvent?(event)
    }

    /// Terminal event raised inside send(): delivered on the next main-queue pass, after send() returns.
    private func finishLater(_ event: BackendEvent) {
        guard let id = turn?.id else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.turn?.id == id else { return }
                self.finish(event)
            }
        }
    }

    private func emitLater(_ event: BackendEvent) {
        guard let id = turn?.id else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.turn?.id == id else { return }
                self.onEvent?(event)
            }
        }
    }

    /// `delay`: let a finished turn's process exit on its own first. The next turn ends it sooner, so two
    /// processes never hold the same session.
    private func retireProcess(after delay: TimeInterval = 0) {
        if delay <= 0, let d = draining {
            draining = nil
            if d.isRunning { d.terminate() }
        }
        guard let p = process else { return }
        process = nil
        processGeneration += 1
        GrokProcess.retire(p, after: delay)
        if delay > 0 { draining = p }
    }
}
