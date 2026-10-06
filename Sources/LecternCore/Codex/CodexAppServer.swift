import Foundation

/// JSON-RPC client for one `codex app-server` process (JSONL over stdio).
///
/// The process starts lazily on the first request, and after a crash it is restarted lazily with
/// exponential backoff. Every server→client request is answered (approvals are declined: Lectern
/// never lets the model run commands or edit files).
@MainActor
final class CodexAppServer {
    struct Launch {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL
    }

    enum Failure: Error, Equatable {
        case notInstalled(String)
        case launchFailed(String)
        case exited(String)
        case timedOut(String)
        case rpc(code: Int, message: String)

        var message: String {
            switch self {
            case .notInstalled(let m), .launchFailed(let m), .exited(let m): return m
            case .timedOut(let method): return "Codex did not answer \(method) in time."
            case .rpc(_, let m): return m
            }
        }
    }

    typealias NotificationHandler = @MainActor (_ method: String, _ params: JSONObject) -> Void

    /// Resolves binary, arguments and environment for each spawn (paths and home mode can change).
    var makeLaunch: (@MainActor () throws -> Launch)?
    /// Raw wire traffic, for debugging: (outgoing, line).
    var trace: (@MainActor (Bool, String) -> Void)?

    /// Bumped on every spawn and stop; callbacks from an older process are ignored, and sessions use
    /// it to tell whether their thread is loaded in the current process.
    private(set) var generation = 0
    private(set) var pid: Int32?

    private var process: ManagedProcess?
    private var ready = false
    private var startTask: Task<Void, Error>?
    private var startedAt = Date.distantPast
    private var crashCount = 0
    private var lastExitMessage: String?

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONObject, Error>
    }
    private var nextId = 0
    private var pending: [Int: Pending] = [:]

    private var listeners: [UUID: NotificationHandler] = [:]
    private var threadListeners: [String: [UUID: NotificationHandler]] = [:]
    private var exitListeners: [UUID: @MainActor (String) -> Void] = [:]

    /// Large prompts can exceed the pipe buffer; keep blocking writes off the main thread, in order.
    private let writeQueue = DispatchQueue(label: "lectern.codex.app-server.stdin")

    init() {}

    var isRunning: Bool { ready && process?.isRunning == true }

    // MARK: Requests

    /// Sends a request (starting the process if needed) and returns its `result` object.
    func request(_ method: String, _ params: JSONObject? = [:], timeout: TimeInterval = 30) async throws -> JSONObject {
        try await ensureStarted()
        return try await send(method, params, timeout: timeout)
    }

    /// Fire-and-forget request to the process running now (interrupt, unsubscribe, login cancel).
    /// Never starts a process; the reply is ignored.
    func post(_ method: String, _ params: JSONObject? = [:]) {
        guard isRunning else { return }
        nextId += 1
        var msg: JSONObject = ["id": nextId, "method": method]
        if let params { msg["params"] = params }
        write(JSONLine.encode(msg))
    }

    func notify(_ method: String, _ params: JSONObject? = nil) {
        var msg: JSONObject = ["method": method]
        if let params { msg["params"] = params }
        write(JSONLine.encode(msg))
    }

    func ensureStarted() async throws {
        if isRunning { return }
        if let startTask { return try await startTask.value }
        // Died, but its exit callback hasn't arrived yet: report it now, or a respawn would make
        // the late callback stale and leave its pending requests and turns hanging.
        if let dead = process, !dead.isRunning {
            handleExit(generation: generation, status: nil, stderr: dead.stderrTail)
        }
        let task = Task { @MainActor in try await self.spawn() }
        startTask = task
        defer { if startTask == task { startTask = nil } }
        try await task.value
    }

    /// Terminates the process. Pending requests fail; the next request starts a new process.
    func stop() {
        startTask?.cancel()
        startTask = nil
        generation += 1
        crashCount = 0
        let hadProcess = process != nil
        process?.terminate()
        process = nil
        pid = nil
        ready = false
        let message = "Codex was restarted."
        failPending(.exited(message))
        if hadProcess { notifyExit(message) }
    }

    // MARK: Listeners

    @discardableResult
    func addListener(_ handler: @escaping NotificationHandler) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    /// Notifications whose `params.threadId` (or `params.thread.id`) matches.
    @discardableResult
    func addThreadListener(_ threadId: String, _ handler: @escaping NotificationHandler) -> UUID {
        let token = UUID()
        threadListeners[threadId, default: [:]][token] = handler
        return token
    }

    func removeThreadListener(_ threadId: String, _ token: UUID) {
        threadListeners[threadId]?[token] = nil
        if threadListeners[threadId]?.isEmpty == true { threadListeners[threadId] = nil }
    }

    func hasThreadListeners(_ threadId: String) -> Bool { threadListeners[threadId] != nil }

    /// Called with a user-facing message whenever the process exits or is stopped.
    @discardableResult
    func addExitListener(_ handler: @escaping @MainActor (String) -> Void) -> UUID {
        let token = UUID()
        exitListeners[token] = handler
        return token
    }

    func removeListener(_ token: UUID) {
        listeners[token] = nil
        exitListeners[token] = nil
    }

    // MARK: Process lifecycle

    private func spawn() async throws {
        if crashCount > 0 {
            let delay = min(10, 0.5 * pow(2, Double(crashCount - 1)))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { throw Failure.exited("Codex was stopped.") }
        }
        guard let makeLaunch else { throw Failure.notInstalled("Codex is not configured.") }
        let launch = try makeLaunch()
        generation += 1
        let gen = generation
        let p = ManagedProcess(executable: launch.executable, arguments: launch.arguments,
                               environment: launch.environment, currentDirectory: launch.currentDirectory,
                               keepStdinOpen: true)
        p.onStdoutLine = { [weak self] line in self?.handleLine(line, generation: gen) }
        p.onExit = { [weak self] status, stderr in self?.handleExit(generation: gen, status: status, stderr: stderr) }
        do {
            try p.start()
        } catch {
            throw Failure.launchFailed("Couldn't start Codex at \(launch.executable.path): \(error.localizedDescription)")
        }
        process = p
        pid = p.pid
        startedAt = Date()
        do {
            _ = try await send("initialize", [
                "clientInfo": ["name": "lectern", "title": "Lectern", "version": "0.1"],
                "capabilities": NSNull(),
            ], timeout: 20)
            guard gen == generation else { throw Failure.exited("Codex was restarted.") }
            notify("initialized")
            ready = true
        } catch {
            // If the process already exited, handleExit has done the bookkeeping.
            if process === p {
                process = nil
                pid = nil
                crashCount += 1
            }
            p.terminate()
            throw error
        }
    }

    private func handleExit(generation gen: Int, status: Int32?, stderr: String) {
        guard gen == generation, process != nil else { return }
        let uptime = Date().timeIntervalSince(startedAt)
        process = nil
        pid = nil
        ready = false
        crashCount = uptime > 60 ? 1 : crashCount + 1
        let message = Self.exitMessage(status: status, stderr: stderr)
        lastExitMessage = message
        failPending(.exited(message))
        notifyExit(message)
    }

    private func notifyExit(_ message: String) {
        for handler in Array(exitListeners.values) { handler(message) }
    }

    private func failPending(_ failure: Failure) {
        let all = pending
        pending.removeAll()
        for entry in all.values { entry.continuation.resume(throwing: failure) }
    }

    static func exitMessage(status: Int32?, stderr: String) -> String {
        let plain = stderr.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let tail = plain.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        let base = status.map { "Codex app-server exited (status \($0))." } ?? "Codex app-server exited."
        return tail.isEmpty ? base : "\(base)\n\(String(tail.suffix(600)))"
    }

    // MARK: Wire

    private func send(_ method: String, _ params: JSONObject?, timeout: TimeInterval) async throws -> JSONObject {
        guard let p = process, p.isRunning else {
            throw Failure.exited(lastExitMessage ?? "Codex is not running.")
        }
        nextId += 1
        let id = nextId
        var msg: JSONObject = ["id": id, "method": method]
        if let params { msg["params"] = params }
        guard JSONSerialization.isValidJSONObject(msg) else {
            throw Failure.rpc(code: -32700, message: "Lectern built an invalid \(method) request.")
        }
        let line = JSONLine.encode(msg)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = Pending(method: method, continuation: cont)
            write(line, to: p)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let entry = self.pending.removeValue(forKey: id) else { return }
                entry.continuation.resume(throwing: Failure.timedOut(entry.method))
            }
        }
    }

    private func write(_ line: String, to target: ManagedProcess? = nil) {
        guard let p = target ?? process else { return }
        trace?(true, line)
        writeQueue.async { p.write(line: line) }
    }

    private func handleLine(_ line: String, generation gen: Int) {
        guard gen == generation else { return }
        trace?(false, line)
        guard let msg = JSONLine.parse(line) else { return }
        let method = msg.str("method")
        if let id = msg["id"], !(id is NSNull) {
            if let method {
                answerServerRequest(id: id, method: method)
                return
            }
            guard let n = (id as? NSNumber)?.intValue, let entry = pending.removeValue(forKey: n) else { return }
            if let err = msg.obj("error") {
                entry.continuation.resume(throwing: Failure.rpc(code: err.int("code") ?? 0,
                                                                message: err.str("message") ?? "Codex error"))
            } else {
                entry.continuation.resume(returning: msg.obj("result") ?? [:])
            }
            return
        }
        guard let method else { return }
        let params = msg.obj("params") ?? [:]
        for handler in Array(listeners.values) { handler(method, params) }
        if let threadId = params.str("threadId") ?? params.obj("thread")?.str("id"),
           let handlers = threadListeners[threadId] {
            for handler in Array(handlers.values) { handler(method, params) }
        }
    }

    /// Declines approvals with the exact decision values from the 0.159.2 schema; everything else
    /// gets a method-not-supported error so the server never waits on us.
    private func answerServerRequest(id: Any, method: String) {
        var reply: JSONObject = ["id": id]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            reply["result"] = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval":
            reply["result"] = ["decision": ["denied": ["rejection": "Lectern is a read-only reader."]]]
        default:
            reply["error"] = ["code": -32601, "message": "Not supported by Lectern"]
        }
        write(JSONLine.encode(reply))
    }
}
