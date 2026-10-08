import Foundation
import LecternCore

// `--grok-home DIR` sets GROK_HOME for every grok process (a scratch install's ~/.grok), so tests never
// touch the real one. `grok-login-dryrun` lets the CLI start a real sign-in; the CLI opens a browser
// itself, so run it where that is blocked (e.g. under sandbox-exec denying LaunchServices).

@MainActor
func grokProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(name: "grok-status", help: "binary, sign-in, account, models  [--path P] [--grok-home DIR]",
                     run: grokStatus),
        ProbeCommand(name: "grok-ask",
                     help: "[--model M] [--effort E] [--image page.png] [--followup Q] [--interrupt-after-ms N] "
                         + "[--resume-id ID] [--trace out.jsonl] [--expect completed|auth] [--path P] [--grok-home DIR] \"question\"",
                     run: grokAsk),
        ProbeCommand(name: "grok-login-dryrun",
                     help: "start the sign-in (--device for a device code), print the link's host only, cancel  "
                         + "[--wait S] [--path P] [--grok-home DIR]",
                     run: grokLoginDryRun),
        ProbeCommand(name: "grok-replay",
                     help: "feed recorded streaming-json (raw or {t,ev} lines) through the interpreter  "
                         + "[--interrupted] [--exit N] [--stderr TEXT] file.jsonl",
                     run: grokReplay),
        ProbeCommand(name: "grok-selftest", help: "offline checks: stream interpreter, errors, status/login parsing, flags",
                     run: grokSelfTest),
        ProbeCommand(name: "installer-run", help: "--command C [--env K=V]…: OfficialInstaller.run (clean env + extras)",
                     run: installerRun),
    ]
}

private let grokValueOptions: Set<String> = ["model", "effort", "image", "followup", "interrupt-after-ms", "resume-id",
                                             "trace", "expect", "path", "grok-home", "wait", "exit", "stderr"]

// MARK: - Live commands

@MainActor
private func makeGrok(_ args: [String]) -> GrokService {
    let path = option("path", in: args)
    let service = GrokService(pathOverride: { path })
    if let home = option("grok-home", in: args) {
        service.extraEnvironment["GROK_HOME"] = (home as NSString).expandingTildeInPath
        service.refreshAuth()
    }
    return service
}

@MainActor
private func settled(_ service: GrokService, timeout: TimeInterval = 40) async -> AuthState {
    let deadline = Date().addingTimeInterval(timeout)
    // The init's check may predate --grok-home; wait for the one scheduled after it too.
    try? await Task.sleep(nanoseconds: 300_000_000)
    while Date() < deadline {
        switch service.authState {
        case .unknown, .checking: try? await Task.sleep(nanoseconds: 100_000_000)
        default: return service.authState
        }
    }
    return service.authState
}

@MainActor
private func grokStatus(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let service = makeGrok(args)
    let state = await settled(service)
    print("binary:        \(service.binaryPath ?? "-")")
    print("install issue: \(service.installIssue ?? "none")")
    print("auth:          \(grokDescribe(state))")
    print("account:       \(service.accountLabel ?? "-")")
    print("models:")
    for m in service.models {
        print("  \((m.id.isEmpty ? "\"\"" : m.id).padding(toLength: 14, withPad: " ", startingAt: 0)) \(m.displayName)"
              + "  efforts=\(m.efforts.joined(separator: ","))\(m.isDefault ? "  (default)" : "")")
    }
    return service.installIssue == nil ? 0 : 1
}

@MainActor
private func grokAsk(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let question = positional(args, valueOptions: grokValueOptions).first else {
        print("usage: lectern-probe grok-ask [options] \"question\"")
        return 2
    }
    let service = makeGrok(args)
    let state = await settled(service)
    print("binary: \(service.binaryPath ?? "-")  auth: \(grokDescribe(state))")
    if let issue = service.installIssue {
        print("install issue: \(issue)")
        return 1
    }
    let expectation = option("expect", in: args) ?? "completed"
    let images = option("image", in: args).map { [URL(fileURLWithPath: $0)] } ?? []
    let settings = TurnSettings(model: option("model", in: args) ?? "", effort: option("effort", in: args) ?? "")
    let session = service.makeSession(conversationId: option("resume-id", in: args))
    let start = Date()
    let stamp = { String(format: "[%6ld ms]", Int(Date().timeIntervalSince(start) * 1000)) }
    if let grok = session as? GrokSession {
        let handle = option("trace", in: args).flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        grok.traceHandler = { line in
            handle?.write(Data("{\"t\":\(Int(Date().timeIntervalSince(start) * 1000)),\"ev\":\(line)}\n".utf8))
        }
    }
    var turns = [TurnRequest(text: question, imagePNGs: images)]
    if let q = option("followup", in: args) { turns.append(TurnRequest(text: q)) }
    var ok = true
    for (i, request) in turns.enumerated() {
        let interruptAfter = i == 0 ? option("interrupt-after-ms", in: args).flatMap(Int.init) : nil
        var result = await grokTurn(session, request, settings, interruptAfterMs: interruptAfter, stamp: stamp)
        if case .conversationReset = result {
            result = await grokTurn(session, request, settings, interruptAfterMs: interruptAfter, stamp: stamp)
        }
        if let grok = session as? GrokSession {
            print("args: " + grok.lastArguments.map { $0.contains(" ") || $0.isEmpty ? "'\($0.prefix(40))…'" : $0 }
                .joined(separator: " "))
        }
        switch (expectation, result) {
        case ("completed", .completed), ("interrupted", .interrupted): break
        case ("auth", .failed(let error)) where error.isAuth: break
        default: ok = false
        }
        print("conversation id: \(session.conversationId ?? "nil")   auth now: \(grokDescribe(service.authState))")
    }
    session.shutdown()
    try? await Task.sleep(nanoseconds: 500_000_000)
    print(ok ? "OK (expected \(expectation))" : "UNEXPECTED (expected \(expectation))")
    return ok ? 0 : 1
}

@MainActor
private func grokTurn(_ session: ChatSession, _ request: TurnRequest, _ settings: TurnSettings,
                      interruptAfterMs: Int?, stamp: @escaping () -> String) async -> BackendEvent {
    await withCheckedContinuation { (cont: CheckedContinuation<BackendEvent, Never>) in
        var terminals = 0
        session.onEvent = { event in
            print("\(stamp()) \(grokDescribe(event))")
            guard grokIsTerminal(event) else { return }
            terminals += 1
            if terminals == 1 {
                // Catch a second terminal event before handing back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cont.resume(returning: event) }
            } else {
                print("ERROR: more than one terminal event")
            }
        }
        print("\(stamp()) send model=\(settings.model.isEmpty ? "(default)" : settings.model) "
              + "effort=\(settings.effort.isEmpty ? "(default)" : settings.effort) images=\(request.imagePNGs.count)")
        session.send(request, settings: settings)
        if let ms = interruptAfterMs {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                print("\(stamp()) interrupt()")
                session.interrupt()
            }
        }
    }
}

@MainActor
private func grokLoginDryRun(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let service = makeGrok(args)
    let before = await settled(service)
    print("before: \(grokDescribe(before))")
    let device = flag("device", in: args)
    service.startLogin(device ? .deviceCode : .browser)
    let deadline = Date().addingTimeInterval(option("wait", in: args).flatMap(Double.init) ?? 20)
    var progress: LoginProgress?
    while Date() < deadline {
        if case .loggingIn(let p) = service.authState, p.url != nil, !device || p.userCode != nil { progress = p; break }
        if case .loggingIn = service.authState {} else { break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    if let p = progress {
        print("sign-in link host: \(p.url?.host ?? "-")  path: \(p.url?.path ?? "-")")
        print("device code shown: \(p.userCode.map { _ in "yes" } ?? "no")")
    } else {
        print("no sign-in link: \(grokDescribe(service.authState))")
    }
    service.cancelLogin()
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    print("after cancel: \(grokDescribe(service.authState))")
    return progress == nil ? 1 : 0
}

@MainActor
private func installerRun(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let command = option("command", in: args) else {
        print("usage: lectern-probe installer-run --command C [--env K=V]…")
        return 2
    }
    var env: [String: String] = [:]
    for (i, a) in args.enumerated() where a == "--env" && i + 1 < args.count {
        let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { env[kv[0]] = kv[1] }
    }
    let start = Date()
    let result = await OfficialInstaller.run(command, environment: env)
    print(String(format: "%.1f s", Date().timeIntervalSince(start)))
    switch result {
    case .success: print("SUCCESS"); return 0
    case .failure(let error): print("FAILURE \(error)"); return 1
    }
}

// MARK: - Offline

@MainActor
private func grokReplay(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let path = positional(args, valueOptions: grokValueOptions).first,
          let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("usage: lectern-probe grok-replay [--interrupted] [--exit N] [--stderr TEXT] file.jsonl")
        return 2
    }
    var interpreter = GrokStreamInterpreter()
    interpreter.interruptRequested = flag("interrupted", in: args)
    var lines: [String] = []
    for raw in content.split(separator: "\n") {
        if let obj = JSONLine.parse(String(raw)), let ev = obj.obj("ev") { lines.append(JSONLine.encode(ev)) } else { lines.append(String(raw)) }
    }
    let outputs = replay(&interpreter, lines, exit: option("exit", in: args).flatMap { Int32($0) } ?? 0,
                         stderr: option("stderr", in: args) ?? "")
    for o in outputs { print(o) }
    let terminals = outputs.filter { !$0.hasPrefix("event ") }.count
    print("model: \(interpreter.model ?? "-")  session: \(interpreter.sessionId ?? "-")  terminal outputs: \(terminals)")
    return terminals == 1 ? 0 : 1
}

private func replay(_ interpreter: inout GrokStreamInterpreter, _ lines: [String], exit: Int32, stderr: String) -> [String] {
    var out = lines.flatMap { interpreter.consume(line: $0) }.map(grokDescribe)
    if let last = interpreter.processExited(status: exit, stderr: stderr) { out.append(grokDescribe(last)) }
    return out
}

@MainActor
private func grokSelfTest(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : "  \(detail())")")
        if !ok { failures += 1 }
    }
    func run(_ lines: [String], exit: Int32 = 0, stderr: String = "", interrupted: Bool = false) -> [String] {
        var i = GrokStreamInterpreter()
        i.interruptRequested = interrupted
        return replay(&i, lines, exit: exit, stderr: stderr)
    }

    // streaming-json as documented (grok 1.0.46 user guide, 14-headless-mode).
    let doc = [
        #"{"type":"thought","data":"Analyzing the directory structure..."}"#,
        #"{"type":"tool_call","toolCallId":"call_1","title":"Read","kind":"read","status":"in_progress","toolName":"read_file","rawInput":{"path":"src/main.rs"},"content":[],"locations":[]}"#,
        #"{"type":"tool_call_update","toolCallId":"call_1","status":"completed","content":[],"rawOutput":{"lines":42},"locations":[]}"#,
        #"{"type":"text","data":"Here's a summary"}"#,
        #"{"type":"text","data":" [p. 2]."}"#,
        #"{"type":"usage","messageId":"resp_1","stopReason":"end_turn","usage":{"input_tokens":812,"output_tokens":45,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_tokens":0},"signature":"..."}"#,
        #"{"type":"end","stopReason":"end_turn","sessionId":"0f8fad5b-d9cb-469f-a165-70867728950e","requestId":"xyz789","usage":{"input_tokens":7210,"cache_read_input_tokens":41000,"cache_creation_input_tokens":0,"output_tokens":1893,"reasoning_tokens":412,"total_tokens":50103},"num_turns":1,"modelUsage":{"grok-4.6":{"inputTokens":7210,"outputTokens":1893,"cacheReadInputTokens":41000,"modelCalls":1}}}"#,
    ]
    var docInterpreter = GrokStreamInterpreter()
    let docOut = replay(&docInterpreter, doc, exit: 0, stderr: "")
    check("doc stream: events in order", docOut == [
        "event thinking", "event textDelta \"Here\\'s a summary\"", "event textDelta \" [p. 2].\"",
        "event sessionReady model=grok-4.6",
        "END COMPLETED \"Here\\'s a summary [p. 2].\" [in=48210 cached=41000 out=1893]",
    ], docOut.joined(separator: " | "))
    check("doc stream: session id from end", docInterpreter.sessionId == "0f8fad5b-d9cb-469f-a165-70867728950e")

    // Captured live from grok 1.0.46 signed out (stdout; exit 1).
    let signedOut = #"{"type":"error","message":"Not signed in. To authenticate without a browser, run:\n  grok login --device-code\n\nAlternatively, set the XAI_API_KEY environment variable or run `grok login` on a machine with a browser."}"#
    let so = run([signedOut], exit: 1, stderr: "Error: Not signed in. To authenticate without a browser, run:\n  grok login --device-code\n")
    check("signed out: one auth failure", so == ["END FAILED authRequired(\"\(GrokProtocol.signInPrompt)\")"], so.joined(separator: " | "))

    let stopped = run([#"{"type":"text","data":"Partial"}"#], exit: 143, interrupted: true)
    check("stop: interrupted after SIGTERM", stopped.last == "END INTERRUPTED" && stopped.count == 2, stopped.joined(separator: " | "))
    let cancelled = run([#"{"type":"end","stopReason":"cancelled","sessionId":"x"}"#])
    check("end cancelled: interrupted", cancelled == ["END INTERRUPTED"], cancelled.joined(separator: " | "))
    let inUse = run([], exit: 1, stderr: "Error: Session ID 0f8fad5b-d9cb-469f-a165-70867728950e is already in use.\n")
    check("-s clash: session in use", inUse.first?.hasPrefix("SESSION IN USE") == true, inUse.joined(separator: " | "))
    let missing = run([], exit: 1, stderr: "Error: No session found with id 0f8fad5b-d9cb-469f-a165-70867728950e.\n")
    check("-r unknown: session missing", missing.first?.hasPrefix("SESSION MISSING") == true, missing.joined(separator: " | "))
    let limit = run([#"{"type":"error","message":"You've hit the rate limit for your plan."}"#], exit: 1)
    check("rate limit: usageLimit", limit.first?.contains("usageLimit") == true, limit.joined(separator: " | "))
    let expired = run([#"{"type":"error","message":"Authentication required: Authentication failed: Unauthorized (401)"}"#], exit: 1)
    check("401: auth expired", expired == ["END FAILED authRequired(\"\(GrokProtocol.authExpiredMessage)\")"], expired.joined(separator: " | "))
    let noEnd = run([#"{"type":"text","data":"Answer"}"#], exit: 0)
    check("exit 0 without end: completed", noEnd.last == "END COMPLETED \"Answer\"", noEnd.joined(separator: " | "))
    let crash = run([], exit: 9)
    check("silent crash: processExited", crash.first?.contains("processExited") == true, crash.joined(separator: " | "))
    let cut = run([#"{"type":"text","data":"Long"}"#, #"{"type":"end","stopReason":"max_tokens","sessionId":"x"}"#])
    check("max_tokens: warning + completed", cut.count == 3 && cut[1].hasPrefix("event warning") && cut[2].hasPrefix("END COMPLETED"), cut.joined(separator: " | "))
    let refusal = run([#"{"type":"end","stopReason":"refusal","sessionId":"x"}"#])
    check("empty refusal: failed", refusal.first?.contains("FAILED api") == true, refusal.joined(separator: " | "))
    let oldCLI = run([], exit: 2, stderr: "error: unexpected argument '--no-plan' found\n\nUsage: grok [OPTIONS] [PROMPT] [COMMAND]\n")
    check("unknown flag: notInstalled (update Grok)", oldCLI.first?.contains("notInstalled") == true, oldCLI.joined(separator: " | "))
    let afterError = run([signedOut, #"{"type":"end","stopReason":"end_turn","sessionId":"x"}"#], exit: 1)
    check("exactly one terminal after error", afterError.count == 1, afterError.joined(separator: " | "))

    // `grok models`, captured live signed out; the signed-in line follows the CLI's own wording.
    let modelsOut = "You are not authenticated.\n\nDefault model: grok-4.6\n\nAvailable models:\n  * grok-4.6 (default)\n  - grok-4.5\n"
    let s = GrokStatus(output: modelsOut)
    check("status: signed out + models", s?.signedIn == false && s?.defaultModel == "grok-4.6" && s?.models == ["grok-4.6", "grok-4.5"],
          String(describing: s))
    let s2 = GrokStatus(output: "You are logged in with reader@example.com.\n\nDefault model: grok-4.7\n\nAvailable models:\n  * grok-4.7 (default)\n")
    check("status: signed in", s2?.signedIn == true && s2?.account == "reader@example.com" && s2?.models == ["grok-4.7"], String(describing: s2))
    check("status: garbage is nil", GrokStatus(output: "segfault") == nil)

    // `grok login` stderr, captured live (code and query replaced).
    let device = "\nTo sign in, open this URL in your browser:\n\n  https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH\n\n"
        + "2026-10-08T00:45:16.557448Z ERROR failed to get default browser, falling back to Safari\n"
        + "  (Could not open browser automatically — open the URL above manually.)\n\nConfirm this code in your browser:\n\n  ABCD-EFGH\n\n"
        + "Only continue with a code you requested. Don't share it with anyone.\n\nWaiting for authorization...\n"
    check("device login: link + code", GrokLoginOutput.url(in: device)?.host == "accounts.x.ai" && GrokLoginOutput.userCode(in: device) == "ABCD-EFGH")
    let oauth = "\nSigning in with Grok...\n\nOpen this URL to sign in:\n  https://auth.x.ai/oauth2/authorize?client_id=c&state=s\n"
    check("oauth login: link, no code", GrokLoginOutput.url(in: oauth)?.host == "auth.x.ai" && GrokLoginOutput.userCode(in: oauth) == nil)
    check("foreign link ignored", GrokLoginOutput.url(in: "Open this URL to sign in:\n  https://evil.example.com/x.ai\n") == nil)

    // Lock-down on every turn.
    let a = GrokProtocol.turnArguments(promptFile: URL(fileURLWithPath: "/tmp/t.json"), model: "grok-4.6", effort: "high",
                                       sessionId: "0f8fad5b-d9cb-469f-a165-70867728950e", resume: false, cwd: URL(fileURLWithPath: "/tmp/cwd"))
    func value(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
    let removed = Set((value("--disallowed-tools") ?? "").split(separator: ",").map(String.init))
    check("flags: tools removed", value("--tools").map { removed.contains($0) } == true
          && removed.isSuperset(of: ["read_file", "list_dir", "grep", "web_search", "run_terminal_cmd", "Agent"]))
    check("flags: deny all + no web/subagents", value("--deny") == "*" && value("--permission-mode") == "dontAsk"
          && ["--disable-web-search", "--no-subagents", "--no-auto-update", "--verbatim"].allSatisfy(a.contains))
    check("flags: reader prompt, model, effort, -s", value("--system-prompt-override") == ReaderPrompt.system && value("-m") == "grok-4.6"
          && value("--effort") == "high" && value("-s") == "0f8fad5b-d9cb-469f-a165-70867728950e" && !a.contains("-r")
          && value("--output-format") == "streaming-json" && value("--prompt-file") == "/tmp/t.json")
    let r = GrokProtocol.turnArguments(promptFile: URL(fileURLWithPath: "/tmp/t.json"), model: "", effort: "", sessionId: "id",
                                       resume: true, cwd: URL(fileURLWithPath: "/tmp/cwd"))
    check("flags: resume, defaults omitted", r.contains("-r") && !r.contains("-s") && !r.contains("-m") && !r.contains("--effort"))
    let env = GrokProtocol.environment(extra: ["GROK_MEMORY": "1", "GROK_HOME": "/tmp/gh"])
    check("env: lock-down wins, extras kept", env["GROK_MEMORY"] == "0" && env["GROK_HOME"] == "/tmp/gh"
          && env["GROK_CLAUDE_RULES_ENABLED"] == "0" && env["GROK_CLAUDE_HOOKS_ENABLED"] == "0"
          && env["GROK_CLAUDE_MCPS_ENABLED"] == "0" && env["GROK_TELEMETRY_TRACE_UPLOAD"] == "0" && env["XAI_API_KEY"] == nil)

    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

// MARK: - Helpers

private func grokIsTerminal(_ event: BackendEvent) -> Bool {
    switch event {
    case .completed, .interrupted, .failed, .conversationReset: return true
    default: return false
    }
}

private func grokDescribe(_ output: GrokStreamOutput) -> String {
    switch output {
    case .event(let e): return "event " + grokDescribe(e)
    case .turnEnded(let e): return "END " + grokDescribe(e)
    case .sessionInUse(let d): return "SESSION IN USE \(d)"
    case .sessionMissing(let d): return "SESSION MISSING \(d)"
    }
}

private func grokDescribe(_ event: BackendEvent) -> String {
    switch event {
    case .sessionReady(let model): return "sessionReady model=\(model)"
    case .thinking: return "thinking"
    case .textDelta(let t): return "textDelta \(t.debugDescription)"
    case .completed(let text, let usage):
        guard let u = usage else { return "COMPLETED \(text.debugDescription)" }
        return "COMPLETED \(text.debugDescription) [in=\(u.inputTokens.map(String.init) ?? "-") cached=\(u.cachedInputTokens.map(String.init) ?? "-")"
            + " out=\(u.outputTokens.map(String.init) ?? "-")\(u.durationMs.map { " \($0)ms" } ?? "")]"
    case .interrupted: return "INTERRUPTED"
    case .failed(let error): return "FAILED \(error)"
    case .quota(let q): return "quota exhausted=\(q.includedUsageExhausted)"
    case .warning(let w): return "warning \(w)"
    case .conversationReset: return "conversationReset"
    }
}

private func grokDescribe(_ state: AuthState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .checking: return "checking"
    case .signedIn(let account): return "signedIn(\(account))"
    case .signedOut(let reason): return "signedOut(\(reason))"
    case .loggingIn(let p): return "loggingIn(\(p.message))"
    case .failed(let message): return "failed(\(message))"
    }
}
