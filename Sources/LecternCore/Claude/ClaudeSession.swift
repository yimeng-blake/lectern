import Foundation
import Observation

/// One Claude conversation about one document, backed by a long-lived `claude -p` stream-json process.
/// The process is spawned lazily on the first send and respawned with `--resume` when the model, effort,
/// binary or login changes, after an hour idle, or after it died. A skill turn (`TurnRequest.skill`)
/// respawns with the skill configuration (ClaudeSkills) in the output folder, still `--resume`-ing the same
/// session, and the next normal turn respawns with the tool-free flags again: one conversation, one memory.
@MainActor @Observable
public final class ClaudeSession: ChatSession {
    public let provider: Provider = .claude
    public private(set) var isBusy = false
    /// The Claude Code session UUID once a turn completed under it (or the id this session resumed).
    public private(set) var conversationId: String?
    @ObservationIgnored public var onEvent: ((BackendEvent) -> Void)?
    /// Every stdout line from the CLI, for diagnostics (lectern-probe `--trace`).
    @ObservationIgnored public var traceHandler: ((String) -> Void)?

    static let idleLimit: TimeInterval = 60 * 60
    /// How long an interrupt may take before the process is dropped instead.
    @ObservationIgnored var interruptGrace: TimeInterval = 5

    @ObservationIgnored private let service: ClaudeService
    @ObservationIgnored private var sessionId: String
    /// Claude Code has a transcript under `sessionId`, so spawns must `--resume` rather than `--session-id`.
    @ObservationIgnored private var transcriptExists: Bool
    @ObservationIgnored private var process: ManagedProcess?
    /// Identifies `process`; callbacks from retired processes carry an older value and are ignored.
    @ObservationIgnored private var processGeneration = 0
    @ObservationIgnored private var spawnKey: SpawnKey?
    /// The latest process was spawned with `--resume` (not `--session-id`).
    @ObservationIgnored private var spawnedWithResume = false
    @ObservationIgnored private var turn: Turn?
    @ObservationIgnored private var turnCounter = 0
    @ObservationIgnored private var interpreter = ClaudeEventInterpreter()
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var interruptWatchdog: Task<Void, Never>?
    /// Serializes stdin writes off the main thread (a page image can be megabytes of base64).
    @ObservationIgnored private let stdinQueue = DispatchQueue(label: "Lectern.ClaudeSession.stdin")

    /// Everything baked into a process's command line; a change means respawn.
    private struct SpawnKey: Equatable {
        var binary: String
        var model: String
        var effort: String
        var loginGeneration: Int
        /// Set for a skill turn's process (other flags, working directory and environment).
        var skill: ClaudeSkills.Launch?
    }

    private struct Turn {
        let id: Int
        let settings: TurnSettings
        let message: String
        let skill: ClaudeSkills.Launch?
        /// One automatic restart per turn (session-id clash).
        var restarted = false
    }

    init(service: ClaudeService, conversationId: String?) {
        self.service = service
        if let id = conversationId, ClaudeProtocol.isValidSessionId(id) {
            sessionId = id
            transcriptExists = true
            self.conversationId = id
        } else {
            sessionId = ClaudeProtocol.newSessionId()
            transcriptExists = false
        }
    }

    /// Safety net for a session dropped without shutdown(): don't leave the CLI running.
    deinit {
        process?.terminate()
    }

    // MARK: - ChatSession

    public func send(_ request: TurnRequest, settings: TurnSettings) {
        guard turn == nil else { return }
        turnCounter += 1
        var text = request.text
        var launch: ClaudeSkills.Launch?
        var setupError: String?
        if let skill = request.skill {
            do {
                let l = try ClaudeSkills.launch(for: skill)
                launch = l
                text = ClaudeSkills.prompt(for: skill, launch: l) + "\n\n" + request.text
            } catch {
                setupError = "Couldn't prepare the \(skill.skill.name) skill: \(error.localizedDescription)"
            }
        }
        let (line, missingImages) = ClaudeProtocol.userMessageLine(text: text, imagePNGs: request.imagePNGs)
        turn = Turn(id: turnCounter, settings: settings, message: line, skill: launch)
        isBusy = true
        idleTask?.cancel()
        if let setupError {
            finishLater(.failed(.api(setupError)))
            return
        }
        if missingImages > 0 {
            emitLater(.warning("Couldn't attach \(missingImages) page image\(missingImages == 1 ? "" : "s")."))
        }
        startTurn()
    }

    public func interrupt() {
        guard let current = turn, !interpreter.interruptRequested else { return }
        interpreter.interruptRequested = true
        guard process != nil else { return }   // a start failure is already on its way
        write(ClaudeProtocol.interruptLine())
        interruptWatchdog?.cancel()
        let grace = interruptGrace
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self, self.turn?.id == current.id else { return }
            // The CLI didn't wind the turn down. Drop the process; the next send resumes the session.
            self.retireProcess()
            self.finish(.interrupted)
        }
    }

    public func resetConversation() {
        if turn != nil { finish(.interrupted) }
        retireProcess()
        sessionId = ClaudeProtocol.newSessionId()
        transcriptExists = false
        conversationId = nil
    }

    public func shutdown() {
        if turn != nil { finish(.interrupted) }
        idleTask?.cancel()
        idleTask = nil
        retireProcess()
    }

    // MARK: - Turn lifecycle

    private func startTurn() {
        guard let current = turn else { return }
        interpreter = ClaudeEventInterpreter()
        guard let binary = service.currentBinary() else {
            finishLater(.failed(.notInstalled(service.installIssue ?? "Claude Code CLI not found.")))
            return
        }
        let key = SpawnKey(binary: binary.path, model: current.settings.model, effort: current.settings.effort,
                           loginGeneration: service.loginGeneration, skill: current.skill)
        if process != nil, key != spawnKey || Date().timeIntervalSince(lastActivity) > Self.idleLimit {
            retireProcess()
        }
        if process == nil {
            do {
                try spawn(binary: binary, key: key)
            } catch {
                finishLater(.failed(.processExited("Couldn't start Claude Code: \(error.localizedDescription)")))
                return
            }
        }
        write(current.message)
    }

    private func spawn(binary: URL, key: SpawnKey) throws {
        let p: ManagedProcess
        if let skill = key.skill {
            let args = ClaudeSkills.arguments(skill, model: key.model, effort: key.effort, sessionId: sessionId,
                                              resume: transcriptExists)
            p = ManagedProcess(executable: binary, arguments: args, environment: ClaudeSkills.environment(),
                               currentDirectory: URL(fileURLWithPath: skill.outputFolder, isDirectory: true),
                               keepStdinOpen: true)
        } else {
            let args = ClaudeProtocol.sessionArguments(model: key.model, effort: key.effort, sessionId: sessionId,
                                                       resume: transcriptExists)
            p = ManagedProcess(executable: binary, arguments: args, environment: CleanEnvironment.make(),
                               currentDirectory: AppPaths.claudeCwd, keepStdinOpen: true)
        }
        processGeneration += 1
        let generation = processGeneration
        p.onStdoutLine = { [weak self] line in self?.received(line, generation: generation) }
        p.onExit = { [weak self] status, stderr in self?.exited(generation: generation, status: status, stderr: stderr) }
        try p.start()
        process = p
        spawnKey = key
        spawnedWithResume = transcriptExists
    }

    private func received(_ line: String, generation: Int) {
        guard generation == processGeneration, process != nil else { return }
        traceHandler?(line)
        if line.contains("\"control_request\""), let obj = JSONLine.parse(line), obj.str("type") == "control_request",
           let id = obj.str("request_id") {
            // Claude Code asks the host when nothing pre-approved a call. Only a skill turn's sandbox may
            // reach the network (the owner's decision); anything else needing a person's approval is refused.
            write(ClaudeProtocol.controlAnswer(requestId: id, request: obj.obj("request") ?? [:],
                                               allowNetwork: spawnKey?.skill != nil))
            return
        }
        guard let current = turn else {
            // Between turns only usage-limit info matters.
            if let obj = JSONLine.parse(line), obj.str("type") == "rate_limit_event",
               let info = obj.obj("rate_limit_info"), let q = ClaudeEventInterpreter.quota(from: info) {
                service.updateQuota(q)
            }
            return
        }
        let outputs = interpreter.consume(line: line)
        // From init on, Claude Code keeps a transcript under this id.
        if interpreter.sawInit { transcriptExists = true }
        for output in outputs {
            guard turn?.id == current.id else { return }
            switch output {
            case .event(let event):
                if case .quota(let q) = event { service.updateQuota(q) }
                onEvent?(event)
            case .turnEnded(let event):
                if case .completed = event { conversationId = sessionId }
                if case .failed(let error) = event, error.isAuth { service.markAuthExpired(error.message) }
                finish(event)
            case .resumeFailed(let detail):
                restartWithNewConversation(detail)
            }
        }
    }

    private func exited(generation: Int, status: Int32, stderr: String) {
        guard generation == processGeneration, process != nil else { return }
        process = nil
        spawnKey = nil
        guard var current = turn else { return }
        if !interpreter.sawInit, !current.restarted, stderr.contains("is already in use") {
            // An earlier process took the message but died before we saw its init.
            current.restarted = true
            turn = current
            transcriptExists = true
            startTurn()
            return
        }
        if !interpreter.sawInit, stderr.contains("No conversation found") {
            restartWithNewConversation(stderr)
            return
        }
        if interpreter.interruptRequested {
            finish(.interrupted)
            return
        }
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(.failed(.processExited(tail.isEmpty ? "Claude Code exited unexpectedly (status \(status))."
                                                   : String(tail.suffix(600)))))
    }

    /// `--resume` failed: switch to a new Claude conversation and end the turn with `.conversationReset`.
    /// The message is not resent here: it was built for the old conversation (pages "provided earlier"),
    /// so the app resets its ContextBuilder and sends a rebuilt prompt as a new turn.
    private func restartWithNewConversation(_ detail: String) {
        guard turn != nil else { return }
        retireProcess()
        if interpreter.interruptRequested {
            finish(.interrupted)
            return
        }
        guard spawnedWithResume else {
            // Only --resume can name a missing conversation; never loop on a fresh --session-id.
            finish(.failed(.api(detail.trimmingCharacters(in: .whitespacesAndNewlines))))
            return
        }
        sessionId = ClaudeProtocol.newSessionId()
        transcriptExists = false
        conversationId = nil
        finish(.conversationReset)
    }

    /// Delivers the turn's single terminal event.
    private func finish(_ event: BackendEvent) {
        guard turn != nil else { return }
        turn = nil
        isBusy = false
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        lastActivity = Date()
        scheduleIdleStop()
        onEvent?(event)
    }

    /// Terminal event raised inside send(): deliver it on the next main-queue pass so the caller
    /// never gets a callback before send() returns.
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

    // MARK: - Process

    private func write(_ line: String) {
        guard let p = process else { return }
        stdinQueue.async { p.write(line: line) }
    }

    private func retireProcess() {
        guard let p = process else { return }
        process = nil
        spawnKey = nil
        processGeneration += 1
        ClaudeProcess.retire(p)
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard process != nil else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleLimit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.turn == nil else { return }
            self.retireProcess()
        }
    }
}
