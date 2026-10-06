import Foundation
import LecternCore

@MainActor
func claudeProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(name: "claude-status",
                     help: "binary, login status, account, models  [--path P]",
                     run: claudeStatus),
        ProbeCommand(name: "claude-verify",
                     help: "one tiny real call (haiku) to prove the login works  [--path P]",
                     run: claudeVerify),
        ProbeCommand(name: "claude-ask",
                     help: "[--model M] [--effort E] [--image page.png] [--text-file f] [--followup q2] "
                         + "[--switch-model M2] [--interrupt-after-ms N] [--resume-id ID] [--trace out.jsonl] "
                         + "[--path P] \"question\"",
                     run: claudeAsk),
        ProbeCommand(name: "claude-replay",
                     help: "feed a recorded stream-json log (raw or {t,ev} lines) through the event interpreter  "
                         + "[--interrupted] file.jsonl",
                     run: claudeReplay),
    ]
}

private let askValueOptions: Set<String> = ["model", "effort", "image", "text-file", "followup", "switch-model",
                                             "interrupt-after-ms", "resume-id", "trace", "path"]

// MARK: - Commands

@MainActor
private func claudeStatus(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let service = makeService(args)
    let state = await settledAuth(service)
    print("binary:        \(service.binaryPath ?? "-")")
    print("install issue: \(service.installIssue ?? "none")")
    print("auth:          \(describe(state))")
    print("account:       \(service.accountEmail ?? "-")   plan: \(service.planName ?? "-")")
    print("models:")
    for m in service.models {
        let id = m.id.isEmpty ? "\"\"" : m.id
        print("  \(id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(m.displayName)"
              + "  efforts=\(m.efforts.joined(separator: ","))  default=\(m.defaultEffort ?? "-")\(m.isDefault ? "  (default)" : "")")
    }
    return service.installIssue == nil && state.isSignedIn ? 0 : 1
}

@MainActor
private func claudeVerify(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let service = makeService(args)
    _ = await settledAuth(service)
    let clock = ProbeClock()
    let ok = await service.verifyConnection()
    print("\(clock.stamp()) verifyConnection: \(ok)")
    print("auth: \(describe(service.authState))")
    return ok ? 0 : 1
}

@MainActor
private func claudeAsk(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let question = positional(args, valueOptions: askValueOptions).first else {
        print("usage: lectern-probe claude-ask [options] \"question\"")
        return 2
    }
    let service = makeService(args)
    let state = await settledAuth(service)
    print("binary: \(service.binaryPath ?? "-")  auth: \(describe(state))")
    if let issue = service.installIssue {
        print("install issue: \(issue)")
        return 1
    }

    var text = question
    if let file = option("text-file", in: args) {
        guard let body = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("can't read \(file)")
            return 2
        }
        text = "<pages>\n\(body)\n</pages>\nQuestion: \(question)"
    }
    let images = option("image", in: args).map { [URL(fileURLWithPath: $0)] } ?? []
    var settings = TurnSettings(model: option("model", in: args) ?? "", effort: option("effort", in: args) ?? "")
    let interruptAfter = option("interrupt-after-ms", in: args).flatMap { Int($0) }

    let session = service.makeSession(conversationId: option("resume-id", in: args))
    let clock = ProbeClock()
    if let tracePath = option("trace", in: args), let claude = session as? ClaudeSession {
        FileManager.default.createFile(atPath: tracePath, contents: nil)
        let handle = FileHandle(forWritingAtPath: tracePath)
        claude.traceHandler = { line in
            handle?.write(Data("{\"t\":\(clock.elapsedMs),\"ev\":\(line)}\n".utf8))
        }
    }
    print("conversation id at start: \(session.conversationId ?? "nil")")

    var ok = true
    var first = await runTurn(session, TurnRequest(text: text, imagePNGs: images), settings,
                              interruptAfterMs: interruptAfter, clock: clock)
    if case .conversationReset = first {
        // The session ended the attempt unsent; the app would rebuild the prompt. Resend as is.
        first = await runTurn(session, TurnRequest(text: text, imagePNGs: images), settings,
                              interruptAfterMs: interruptAfter, clock: clock)
    }
    ok = ok && expected(first, interrupted: interruptAfter != nil)
    print("conversation id: \(session.conversationId ?? "nil")")

    if let followup = option("followup", in: args) {
        if let model = option("switch-model", in: args) { settings.model = model }
        let second = await runTurn(session, TurnRequest(text: followup), settings, interruptAfterMs: nil, clock: clock)
        ok = ok && expected(second, interrupted: false)
        print("conversation id: \(session.conversationId ?? "nil")")
    }
    if let q = service.quota {
        print("quota: " + q.windows.map { "\($0.label) \($0.usedPercent)%" }.joined(separator: ", ")
              + "  exhausted=\(q.includedUsageExhausted)")
    }
    session.shutdown()
    try? await Task.sleep(nanoseconds: 1_000_000_000)   // let the child wind down after SIGTERM before we exit
    return ok ? 0 : 1
}

@MainActor
private func claudeReplay(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let path = positional(args, valueOptions: []).first,
          let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("usage: lectern-probe claude-replay [--interrupted] file.jsonl")
        return 2
    }
    var interpreter = ClaudeEventInterpreter()
    interpreter.interruptRequested = flag("interrupted", in: args)
    var terminals = 0
    for raw in content.split(separator: "\n") {
        guard var obj = JSONLine.parse(String(raw)) else { continue }
        var stamp = ""
        if let ev = obj.obj("ev") {
            stamp = obj.int("t").map { "[\(String($0).leftPad(6)) ms] " } ?? ""
            obj = ev
        }
        for output in interpreter.consume(obj) {
            switch output {
            case .event(let e): print(stamp + describe(e))
            case .turnEnded(let e): terminals += 1; print(stamp + describe(e))
            case .resumeFailed(let detail): print(stamp + "RESUME FAILED \(detail)")
            }
        }
    }
    print("model: \(interpreter.model ?? "-")  session: \(interpreter.sessionId ?? "-")  terminal events: \(terminals)")
    return terminals == 1 ? 0 : 1
}

// MARK: - Helpers

@MainActor
private func makeService(_ args: [String]) -> ClaudeService {
    let path = option("path", in: args)
    return ClaudeService(pathOverride: { path })
}

/// Waits for the service's initial `auth status` check.
@MainActor
private func settledAuth(_ service: ClaudeService, timeout: TimeInterval = 30) async -> AuthState {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        switch service.authState {
        case .unknown, .checking: try? await Task.sleep(nanoseconds: 100_000_000)
        default: return service.authState
        }
    }
    return service.authState
}

@MainActor
private func runTurn(_ session: ChatSession, _ request: TurnRequest, _ settings: TurnSettings,
                     interruptAfterMs: Int?, clock: ProbeClock) async -> BackendEvent {
    await withCheckedContinuation { (cont: CheckedContinuation<BackendEvent, Never>) in
        var done = false
        session.onEvent = { event in
            print("\(clock.stamp()) \(describe(event))")
            guard !done, isTerminal(event) else { return }
            done = true
            cont.resume(returning: event)
        }
        print("\(clock.stamp()) send model=\(settings.model.isEmpty ? "(default)" : settings.model)"
              + " effort=\(settings.effort.isEmpty ? "(default)" : settings.effort)"
              + " images=\(request.imagePNGs.count) chars=\(request.text.count)")
        session.send(request, settings: settings)
        if let ms = interruptAfterMs {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                print("\(clock.stamp()) interrupt()")
                session.interrupt()
            }
        }
    }
}

private func isTerminal(_ event: BackendEvent) -> Bool {
    switch event {
    case .completed, .interrupted, .failed, .conversationReset: return true
    default: return false
    }
}

private func expected(_ event: BackendEvent, interrupted: Bool) -> Bool {
    switch event {
    case .completed: return true
    case .interrupted: return interrupted
    default: return false
    }
}

private func describe(_ event: BackendEvent) -> String {
    switch event {
    case .sessionReady(let model): return "sessionReady model=\(model)"
    case .thinking: return "thinking"
    case .textDelta(let t): return "textDelta \(t.debugDescription)"
    case .completed(let text, let usage):
        var s = "COMPLETED \(text.debugDescription)"
        if let u = usage {
            s += "  [in=\(u.inputTokens.map(String.init) ?? "-") cached=\(u.cachedInputTokens.map(String.init) ?? "-")"
                + " out=\(u.outputTokens.map(String.init) ?? "-") \(u.durationMs.map(String.init) ?? "-")ms]"
        }
        return s
    case .interrupted: return "INTERRUPTED"
    case .failed(let error): return "FAILED \(error)"
    case .quota(let q):
        return "quota " + q.windows.map { "\($0.label)=\($0.usedPercent)%" }.joined(separator: " ")
            + " exhausted=\(q.includedUsageExhausted)" + (q.note.map { " note=\($0)" } ?? "")
    case .warning(let w): return "warning \(w)"
    case .conversationReset: return "conversationReset"
    }
}

private func describe(_ state: AuthState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .checking: return "checking"
    case .signedIn(let account): return "signedIn(\(account))"
    case .signedOut(let reason): return "signedOut(\(reason))"
    case .loggingIn(let p): return "loggingIn(\(p.message)\(p.url.map { " url=\($0.absoluteString)" } ?? ""))"
    case .failed(let message): return "failed(\(message))"
    }
}

private final class ProbeClock: @unchecked Sendable {
    private let start = Date()
    var elapsedMs: Int { Int(Date().timeIntervalSince(start) * 1000) }
    func stamp() -> String { "[\(String(elapsedMs).leftPad(6)) ms]" }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
