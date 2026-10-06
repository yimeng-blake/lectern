import Foundation
import LecternCore

// Codex (ChatGPT) probes. They never open a browser: sign-in pages are only reported by host.

@MainActor
func codexProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(name: "codex-status",
                     help: "Codex binary, sign-in, models and quota [--home isolated|shared] [--codex-path P]",
                     run: codexStatus),
        ProbeCommand(name: "codex-models",
                     help: "Model catalog from model/list [--home isolated|shared]",
                     run: codexModels),
        ProbeCommand(name: "codex-quota",
                     help: "Plan usage windows and credits [--home isolated|shared]",
                     run: codexQuota),
        ProbeCommand(name: "codex-login-dryrun",
                     help: "Start a ChatGPT sign-in and cancel it at once; prints only the URL host and loginId [--device] [--home]",
                     run: codexLoginDryRun),
        ProbeCommand(name: "codex-ask",
                     help: "Ask a question [--home] [--model M] [--effort E] [--fast] [--image PNG] [--followup Q] [--interrupt-after-ms N] [--resume-id ID] \"question\"",
                     run: codexAsk),
        ProbeCommand(name: "codex-skills",
                     help: "Skills the Codex harness lists (skills/list; isolated: + ~/.codex/skills roots) [--home] [--codex-path P]",
                     run: codexSkills),
        ProbeCommand(name: "codex-skill-run",
                     help: "Run one skill turn --skill NAME --pdf P --question Q [--home] [--model M] [--effort E] [--out DIR] [--followup Q ({out} = output folder)] [--resume-id ID]",
                     run: codexSkillRun),
    ]
}

private let codexValueOptions: Set<String> = ["home", "codex-path", "model", "effort", "image", "followup",
                                              "interrupt-after-ms", "resume-id"]

@MainActor
private func makeCodexService(_ args: [String]) -> CodexService? {
    let name = option("home", in: args) ?? CodexHomeMode.isolated.rawValue
    guard let mode = CodexHomeMode(rawValue: name) else {
        print("unknown --home \(name) (use isolated or shared)")
        return nil
    }
    let path = option("codex-path", in: args)
    let service = CodexService(pathOverride: { path }, homeMode: { mode })
    service.urlOpener = { url in print("(not opening sign-in page on \(url.host ?? "?"))") }
    print("home: \(mode.rawValue)")
    return service
}

@MainActor
private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

private func describe(_ state: AuthState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .checking: return "checking"
    case .signedIn(let account): return "signed in (\(account))"
    case .signedOut(let reason): return "signed out: \(reason)"
    case .loggingIn(let progress): return "signing in: \(progress.message) [page host: \(progress.url?.host ?? "-")]"
    case .failed(let message): return "failed: \(message)"
    }
}

private func describe(_ quota: QuotaSnapshot) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = quota.windows.map { w in
        "  \(w.label): \(String(format: "%.0f", w.usedPercent))% used" + (w.resetsAt.map { ", resets \(formatter.string(from: $0))" } ?? "")
    }
    lines.append("  included usage exhausted: \(quota.includedUsageExhausted)")
    if let note = quota.note { lines.append("  note: \(note)") }
    return lines.joined(separator: "\n")
}

private func describe(_ error: BackendError) -> String {
    switch error {
    case .authRequired(let m): return "authRequired: \(m)"
    case .notInstalled(let m): return "notInstalled: \(m)"
    case .usageLimit(let m): return "usageLimit: \(m)"
    case .processExited(let m): return "processExited: \(m)"
    case .protocolError(let m): return "protocolError: \(m)"
    case .api(let m): return "api: \(m)"
    }
}

@MainActor
private func printModels(_ models: [ModelOption]) {
    for m in models {
        let marker = m.isDefault ? "*" : " "
        print(" \(marker) \(m.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(m.displayName) · efforts \(m.efforts.joined(separator: "/")) (default \(m.defaultEffort ?? "-")) · fast tier \(m.fastTierId ?? "-")")
    }
}

// MARK: Commands

@MainActor
private func codexStatus(_ args: [String]) async -> Int32 {
    guard let service = makeCodexService(args) else { return 2 }
    await service.refresh()
    _ = await waitUntil(seconds: 3) { service.binaryVersion != nil || service.binaryPath == nil }
    print("binary: \(service.binaryPath ?? "-") (\(service.binaryVersion ?? "version unknown"))")
    if let issue = service.installIssue { print("install issue: \(issue)") }
    print("auth: \(describe(service.authState))")
    print("account: \(service.accountEmail ?? "-") · plan \(service.planName ?? "-")")
    print("models: \(service.models.count) (default \(service.models.first { $0.isDefault }?.id ?? "-"))")
    if let quota = service.quota { print("quota:\n\(describe(quota))") } else { print("quota: -") }
    service.stop()
    return service.installIssue == nil ? 0 : 1
}

@MainActor
private func codexModels(_ args: [String]) async -> Int32 {
    guard let service = makeCodexService(args) else { return 2 }
    await service.refresh()
    printModels(service.models)
    service.stop()
    return service.models.isEmpty ? 1 : 0
}

@MainActor
private func codexQuota(_ args: [String]) async -> Int32 {
    guard let service = makeCodexService(args) else { return 2 }
    await service.refresh()
    print("auth: \(describe(service.authState))")
    guard let quota = service.quota else {
        print("quota: unavailable (sign-in required)")
        service.stop()
        return 1
    }
    print("quota:\n\(describe(quota))")
    service.stop()
    return 0
}

@MainActor
private func codexLoginDryRun(_ args: [String]) async -> Int32 {
    guard let service = makeCodexService(args) else { return 2 }
    var pageHost: String?
    service.urlOpener = { url in pageHost = url.host }
    await service.refresh()
    print("before: \(describe(service.authState))")
    service.addAuthObserver { state in print("  state -> \(describe(state))") }
    service.startLogin(flag("device", in: args) ? .deviceCode : .browser)
    let started = await waitUntil(seconds: 30) {
        if service.activeLoginId != nil { return true }
        if case .loggingIn = service.authState { return false }
        return true
    }
    guard started, let loginId = service.activeLoginId else {
        print("sign-in did not start: \(describe(service.authState))")
        service.stop()
        return 1
    }
    print("loginId: \(loginId)")
    print("sign-in page host: \(pageHost ?? "-") (not opened)")
    service.cancelLogin()
    // Give account/login/cancel and the server's login/completed time to arrive.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    print("after cancel: \(describe(service.authState)); active login: \(service.activeLoginId ?? "none")")
    service.stop()
    return service.activeLoginId == nil ? 0 : 1
}

@MainActor
private func codexAsk(_ args: [String]) async -> Int32 {
    guard let question = positional(args, valueOptions: codexValueOptions).first else {
        print("usage: codex-ask [--home isolated|shared] [--model M] [--effort E] [--fast] [--image PNG] [--followup Q] [--interrupt-after-ms N] [--resume-id ID] \"question\"")
        return 2
    }
    guard let service = makeCodexService(args) else { return 2 }
    await service.refresh()
    print("auth: \(describe(service.authState))")
    let settings = TurnSettings(model: option("model", in: args) ?? "", effort: option("effort", in: args) ?? "",
                                fastTier: flag("fast", in: args))
    print("settings: model \(settings.model.isEmpty ? "(default)" : settings.model) · effort \(settings.effort.isEmpty ? "(default)" : settings.effort) · fast tier \(settings.fastTier)")
    let images = option("image", in: args).map { [URL(fileURLWithPath: $0)] } ?? []
    let session = service.makeSession(conversationId: option("resume-id", in: args))

    var status: Int32 = 0
    let interruptMs = option("interrupt-after-ms", in: args).flatMap(Int.init)
    if !(await askTurn(session, TurnRequest(text: question, imagePNGs: images), settings, interruptAfterMs: interruptMs)) {
        status = 1
    }
    if let followup = option("followup", in: args) {
        print("\n>>> follow-up: \(followup)")
        if !(await askTurn(session, TurnRequest(text: followup), settings, interruptAfterMs: nil)) { status = 1 }
    }
    print("thread: \(session.conversationId ?? "-")")
    session.shutdown()
    service.stop()
    return status
}

/// Runs one turn, printing events as they arrive. Returns false for a failed turn.
@MainActor
private func askTurn(_ session: ChatSession, _ request: TurnRequest, _ settings: TurnSettings,
                     interruptAfterMs: Int?) async -> Bool {
    let start = Date()
    var firstDelta: TimeInterval?
    var terminals = 0
    let terminal: BackendEvent = await withCheckedContinuation { continuation in
        session.onEvent = { event in
            switch event {
            case .sessionReady(let model): print("[ready] model \(model)")
            case .thinking: print("[thinking]")
            case .textDelta(let delta):
                if firstDelta == nil { firstDelta = Date().timeIntervalSince(start) }
                print(delta, terminator: "")
                fflush(stdout)
            case .quota(let quota): print("\n[quota]\n\(describe(quota))")
            case .warning(let warning): print("\n[warning] \(warning)")
            case .completed, .interrupted, .failed, .conversationReset:
                terminals += 1
                if terminals == 1 { continuation.resume(returning: event) } else { print("\n[BUG] extra terminal event") }
            }
        }
        session.send(request, settings: settings)
        if let interruptAfterMs {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(interruptAfterMs) * 1_000_000)
                print("\n[interrupting]")
                session.interrupt()
            }
        }
    }
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    let first = firstDelta.map { String(format: "%.1f", $0) } ?? "-"
    if case .conversationReset = terminal {
        // The session ended the attempt unsent (the app would rebuild the prompt); send it again as is.
        print("[conversation reset: previous thread could not be resumed; resending]")
        return await askTurn(session, request, settings, interruptAfterMs: interruptAfterMs)
    }
    switch terminal {
    case .completed(let text, let usage):
        let tokens = usage.map { "in \($0.inputTokens ?? 0) (cached \($0.cachedInputTokens ?? 0)) / out \($0.outputTokens ?? 0)" } ?? "-"
        print("\n[completed] \(elapsed)s, first text \(first)s, tokens \(tokens)\n--- final text ---\n\(text)\n---")
        return true
    case .interrupted:
        print("\n[interrupted] after \(elapsed)s")
        return true
    case .failed(let error):
        print("\n[failed] after \(elapsed)s: \(describe(error))")
        return false
    default:
        return false
    }
}

// MARK: Skills

@MainActor
private func codexSkills(_ args: [String]) async -> Int32 {
    guard let service = makeCodexService(args) else { return 2 }
    let skills = await service.listSkills()
    for s in skills {
        print("\(s.name.padding(toLength: 30, withPad: " ", startingAt: 0)) [\(s.source)] \(s.path)")
        print("    \(s.description.prefix(120))")
    }
    print("\(skills.count) skills")
    service.stop()
    return skills.isEmpty ? 1 : 0
}

/// One skill turn on a new (or resumed) thread, like the app's: the document's text is written into the
/// output folder first. Lists the folder's files afterwards; `--followup` then sends a reader turn.
@MainActor
private func codexSkillRun(_ args: [String]) async -> Int32 {
    guard let name = option("skill", in: args), let pdfPath = option("pdf", in: args),
          let question = option("question", in: args) else {
        print("usage: codex-skill-run --skill NAME --pdf P --question Q [--home isolated|shared] [--model M] [--effort E] [--out DIR] [--followup Q] [--resume-id ID]")
        return 2
    }
    let pdf = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: pdf, options: .mappedIfSafe),
          let document = ReaderDocument(data: data, fileURL: pdf, title: pdf.deletingPathExtension().lastPathComponent) else {
        print("can't open \(pdf.path) as a PDF")
        return 2
    }
    guard let service = makeCodexService(args) else { return 2 }
    await service.refresh()
    print("auth: \(describe(service.authState))")
    let skills = await service.listSkills()
    guard let skill = skills.first(where: { $0.name == name })
            ?? skills.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        print("no skill named \(name) (\(skills.count) listed; see codex-skills)")
        service.stop()
        return 2
    }
    print("skill: \(skill.name) [\(skill.source)] \(skill.path)")

    let out = option("out", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("lectern-skill-run-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent(document.title, isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var text = ""
    for page in 0..<document.pageCount { text += "=== Page \(page + 1) ===\n\(await document.pageText(page))\n\n" }
    let textFile = out.appendingPathComponent("\(document.title) - text.txt")
    try? text.write(to: textFile, atomically: true, encoding: .utf8)
    print("output folder: \(out.path)")

    let settings = TurnSettings(model: option("model", in: args) ?? "", effort: option("effort", in: args) ?? "")
    print("settings: model \(settings.model.isEmpty ? "(default)" : settings.model) · effort \(settings.effort.isEmpty ? "(default)" : settings.effort) · standard tier")
    let session = service.makeSession(conversationId: option("resume-id", in: args))
    let request = TurnRequest(text: question, skill: SkillTurn(skill: skill, outputFolder: out, documentTextFile: textFile, pdfFile: pdf))
    var status: Int32 = await askTurn(session, request, settings, interruptAfterMs: nil) ? 0 : 1
    printFiles(in: out)
    if let followup = option("followup", in: args)?.replacingOccurrences(of: "{out}", with: out.path) {
        print("\n>>> reader follow-up: \(followup)")
        if !(await askTurn(session, TurnRequest(text: followup), settings, interruptAfterMs: nil)) { status = 1 }
        printFiles(in: out)
    }
    print("thread: \(session.conversationId ?? "-")")
    session.shutdown()
    service.stop()
    return status
}

private func printFiles(in folder: URL) {
    let fm = FileManager.default
    let files = (fm.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
    print("files in output folder:")
    for file in files {
        let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.size] as? Int) ?? nil
        print("  \(file)\(size.map { " (\($0) bytes)" } ?? "")")
    }
}
