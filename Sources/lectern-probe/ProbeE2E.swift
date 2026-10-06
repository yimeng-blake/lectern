import Foundation
import LecternCore

// End-to-end question about a PDF through the same pieces a document window uses:
// ReaderDocument → ContextBuilder → ProviderService.makeSession → ChatSession, with ChatModel's
// gating (sign-in, purchased-credits guard) and context resets. Never starts a sign-in.

@MainActor
func e2eProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(
            name: "ask",
            help: "--provider claude|codex --pdf P --page N [--select text] [--home shared|isolated] [--model M] "
                + "[--effort E] [--fast] [--image] [--whole] [--radius R] [--followup Q [--followup-page N]] "
                + "[--expect \"a|b\"] [--followup-expect \"a|b\"] [--allow-credits] [--show-prompt] [--timeout S] \"question\"",
            run: e2eAsk),
        ProbeCommand(
            name: "title",
            help: "--provider claude|codex [--home shared|isolated] --question Q --answer A",
            run: e2eTitle),
    ]
}

private let e2eValueOptions: Set<String> = ["provider", "pdf", "page", "select", "home", "model", "effort", "radius",
                                            "followup", "followup-page", "expect", "followup-expect", "timeout",
                                            "codex-path", "claude-path", "resume-id"]

@MainActor
private func e2eAsk(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let question = positional(args, valueOptions: e2eValueOptions).first,
          let providerName = option("provider", in: args), let provider = Provider(rawValue: providerName),
          let pdfPath = option("pdf", in: args) else {
        print("usage: lectern-probe ask --provider claude|codex --pdf P --page N [options] \"question\"")
        return 2
    }
    let url = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url),
          let document = ReaderDocument(data: data, fileURL: url, title: url.deletingPathExtension().lastPathComponent) else {
        print("can't open \(url.path) as a PDF")
        return 2
    }
    let page = max(1, option("page", in: args).flatMap(Int.init) ?? 1)
    guard page <= document.pageCount else {
        print("--page \(page) is past the end (\(document.pageCount) pages)")
        return 2
    }
    print("document: \"\(document.title)\" · \(document.pageCount) pages · sha256 \(document.contentHash.prefix(12))…")

    // Service, as AppServices builds it.
    let service: ProviderService
    var codex: CodexService?
    switch provider {
    case .claude:
        let path = option("claude-path", in: args)
        let claude = ClaudeService(pathOverride: { path })
        service = claude
        _ = await waitForSettledAuth(claude)
        print("claude: \(claude.binaryPath ?? "-")")
    case .codex:
        let homeName = option("home", in: args) ?? CodexHomeMode.isolated.rawValue
        guard let mode = CodexHomeMode(rawValue: homeName) else {
            print("unknown --home \(homeName) (use isolated or shared)")
            return 2
        }
        let path = option("codex-path", in: args)
        let svc = CodexService(pathOverride: { path }, homeMode: { mode })
        svc.urlOpener = { url in print("(not opening sign-in page on \(url.host ?? "?"))") }
        await svc.refresh()
        codex = svc
        service = svc
        print("codex: \(svc.binaryPath ?? "-") · home \(mode.rawValue)")
    }
    defer { codex?.stop() }
    print("auth: \(e2eDescribe(service.authState))")

    // ChatModel.send step 1–3: install issue, sign-in, credits guard.
    if let issue = service.installIssue {
        print("NOT SENT: \(issue)")
        return 1
    }
    guard service.authState.isSignedIn else {
        print("NOT SENT: the question would wait for login (status .waitingForLogin); the banner offers Log in.")
        return 3
    }
    if let codex, !flag("allow-credits", in: args) {
        // ChatModel's guard fails closed: an unknown or old quota is read once more, then decides.
        var check = codex.creditsCheck()
        if check == .needsRefresh {
            await codex.refreshQuota()
            check = codex.creditsCheck()
        }
        switch check {
        case .exhausted:
            print("NOT SENT: included usage is used up; the credits guard holds the question (pass --allow-credits).")
            return 4
        case .needsRefresh:
            print("NOT SENT: couldn't check the ChatGPT usage; the credits guard asks first (pass --allow-credits).")
            return 4
        case .available, .notApplicable:
            break
        }
    }
    if let quota = service.quota {
        print("quota: " + quota.windows.map { "\($0.label) \(String(format: "%.0f", $0.usedPercent))%" }.joined(separator: ", ")
              + (quota.note.map { " · \($0)" } ?? ""))
    }

    let settings = e2eSettings(args, provider: provider, models: service.models)
    print("settings: model \(settings.model.isEmpty ? "(default)" : settings.model) · effort "
          + "\(settings.effort.isEmpty ? "(default)" : settings.effort)" + (provider == .codex ? " · fast tier \(settings.fastTier)" : ""))

    var options = ContextOptions(tokenBudget: ContextOptions.defaultTokenBudget(for: provider, model: settings.model))
    options.neighborRadius = option("radius", in: args).flatMap(Int.init) ?? 1
    options.attachPageImage = flag("image", in: args)
    options.wholeDocument = flag("whole", in: args)

    let builder = ContextBuilder(document: document)
    let session = service.makeSession(conversationId: option("resume-id", in: args))
    let timeout = option("timeout", in: args).flatMap(Double.init) ?? 180
    let showPrompt = flag("show-prompt", in: args)
    var turns: [(page: Int, question: String, expect: String?)] = [(page, question, option("expect", in: args))]
    if let followup = option("followup", in: args) {
        let followupPage = option("followup-page", in: args).flatMap(Int.init) ?? page
        turns.append((min(max(followupPage, 1), document.pageCount), followup, option("followup-expect", in: args)))
    }

    var status: Int32 = 0
    for (index, turn) in turns.enumerated() {
        let selection = index == 0 ? option("select", in: args) : nil
        let state = ReadingState(currentPage: turn.page - 1, visiblePages: [turn.page - 1],
                                 selectionText: selection, selectionPages: selection == nil ? [] : [turn.page - 1])
        let built = await builder.build(question: turn.question, state: state, options: options)
        print("\n>>> turn \(index + 1) · page \(turn.page)\(selection == nil ? "" : " · selection") · \(turn.question)")
        print("context: pages \(built.pagesIncluded.map { $0 + 1 }) (new \(built.newlySentPages.map { $0 + 1 }))"
              + " · ~\(built.estimatedTokens) tokens · images \(built.request.imagePNGs.count)")
        if showPrompt { print("--- prompt ---\n\(built.request.text)\n--- end prompt ---") }

        var outcome = await e2eRunTurn(session, built, settings, timeout: timeout)
        if case .reset = outcome {
            // ChatModel: the old conversation is gone; rebuild the prompt with full context and send again.
            builder.reset()
            let rebuilt = await builder.build(question: turn.question, state: state, options: options)
            print("[conversation reset: resending with pages \(rebuilt.newlySentPages.map { $0 + 1 })]")
            outcome = await e2eRunTurn(session, rebuilt, settings, timeout: timeout)
        }
        switch outcome {
        case .completed(let text):
            print("--- answer ---\n\(text)\n---")
            if let expect = turn.expect {
                let missing = expect.split(separator: "|").map(String.init).filter { !text.contains($0) }
                print(missing.isEmpty ? "CHECK PASS: contains \(expect)" : "CHECK FAIL: missing \(missing)")
                if !missing.isEmpty { status = 1 }
            }
        case .interrupted:
            print("[interrupted]")
            status = 1
        case .reset:
            print("[failed] the conversation was reset twice")
            status = 1
        case .failed(let error):
            print("[failed] \(error)")
            if error.isAuth {
                // ChatModel: the question waits for login and is retried after it.
                if service.authState.isSignedIn { service.markAuthExpired(error.message) }
                print("auth now: \(e2eDescribe(service.authState))")
            } else {
                // ChatModel: unknown whether the prompt reached the conversation; resend pages next time.
                builder.reset()
            }
            status = 1
        }
        if status != 0 { break }
    }
    print("\nconversation id: \(session.conversationId ?? "nil")")
    session.shutdown()
    try? await Task.sleep(nanoseconds: 1_000_000_000)   // let children exit after SIGTERM
    return status
}

/// ConversationTitler as ChatModel calls it after a conversation's first answer: the local fallback,
/// then the model title (one call to the provider's lightest model; Codex never spends purchased credits).
@MainActor
private func e2eTitle(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let providerName = option("provider", in: args), let provider = Provider(rawValue: providerName),
          let question = option("question", in: args), let answer = option("answer", in: args) else {
        print("usage: lectern-probe title --provider claude|codex [--home shared|isolated] --question Q --answer A")
        return 2
    }
    let homeName = option("home", in: args) ?? CodexHomeMode.isolated.rawValue
    guard let mode = CodexHomeMode(rawValue: homeName) else {
        print("unknown --home \(homeName) (use isolated or shared)")
        return 2
    }
    print("fallback: \(ConversationTitler.fallbackTitle(question: question))")

    // Both services, as AppServices builds them; only `provider` is asked.
    let claudePath = option("claude-path", in: args), codexPath = option("codex-path", in: args)
    let claude = ClaudeService(pathOverride: { claudePath })
    let codex = CodexService(pathOverride: { codexPath }, homeMode: { mode })
    codex.urlOpener = { url in print("(not opening sign-in page on \(url.host ?? "?"))") }
    defer { codex.stop() }
    switch provider {
    case .claude:
        _ = await waitForSettledAuth(claude)
        print("claude: \(claude.binaryPath ?? "-") · auth: \(e2eDescribe(claude.authState)) · model haiku")
    case .codex:
        await codex.refresh()
        let model = CodexService.oneShotModel(in: codex.models)
        print("codex: \(codex.binaryPath ?? "-") · home \(mode.rawValue) · auth: \(e2eDescribe(codex.authState))"
              + " · credits check \(codex.creditsCheck()) · model \(model?.id ?? "-")")
    }

    let start = Date()
    let title = await ConversationTitler.title(question: question, answer: answer, provider: provider,
                                               claude: claude, codex: codex)
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    guard let title else {
        print("title: nil after \(elapsed) s (the fallback stays)")
        return 1
    }
    print("title: \(title) (\(elapsed) s)")
    return 0
}

private enum E2EOutcome {
    case completed(String)
    case interrupted
    case failed(BackendError)
    /// `.conversationReset` ended the attempt unsent.
    case reset
}

@MainActor
private func e2eRunTurn(_ session: ChatSession, _ built: BuiltPrompt, _ settings: TurnSettings,
                        timeout: TimeInterval) async -> E2EOutcome {
    let start = Date()
    var streamed = ""
    var announcedThinking = false
    let outcome: E2EOutcome = await withCheckedContinuation { continuation in
        var done = false
        func finish(_ o: E2EOutcome) {
            guard !done else { return }
            done = true
            continuation.resume(returning: o)
        }
        session.onEvent = { event in
            switch event {
            case .sessionReady(let model): print("[model \(model)]")
            case .thinking:
                if !announcedThinking { announcedThinking = true; print("[thinking]") }
            case .textDelta(let delta):
                streamed += delta
                print(delta, terminator: "")
                fflush(stdout)
            case .quota(let q):
                print("[quota " + q.windows.map { "\($0.label) \(String(format: "%.0f", $0.usedPercent))%" }.joined(separator: ", ")
                      + " exhausted=\(q.includedUsageExhausted)]")
            case .warning(let w): print("[warning] \(w)")
            case .conversationReset: finish(.reset)
            case .completed(let text, let usage):
                if !streamed.isEmpty { print("") }
                let tokens = usage.map { "in \($0.inputTokens ?? 0) (cached \($0.cachedInputTokens ?? 0)) / out \($0.outputTokens ?? 0)" } ?? "-"
                print("[completed in \(String(format: "%.1f", Date().timeIntervalSince(start))) s · \(tokens)]")
                finish(.completed(text.isEmpty ? streamed : text))
            case .interrupted: finish(.interrupted)
            case .failed(let error): finish(.failed(error))
            }
        }
        session.send(built.request, settings: settings)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !done else { return }
            print("\n[timeout after \(Int(timeout)) s: interrupting]")
            session.interrupt()
        }
    }
    session.onEvent = nil
    return outcome
}

/// ChatModel's settings resolution: a Codex model missing from the catalog falls back to the
/// catalog default; an effort the model doesn't list becomes "" (the model's default).
@MainActor
private func e2eSettings(_ args: [String], provider: Provider, models: [ModelOption]) -> TurnSettings {
    var s = TurnSettings(model: option("model", in: args) ?? "", effort: option("effort", in: args) ?? "",
                         fastTier: flag("fast", in: args))
    guard !models.isEmpty else { return s }
    if provider == .codex, !s.model.isEmpty, !models.contains(where: { $0.id == s.model }) {
        print("note: model \(s.model) is not in the catalog; using the catalog default")
        s.model = ""
    }
    let selected = models.first { $0.id == s.model } ?? models.first { $0.isDefault } ?? models.first
    if !s.effort.isEmpty, let m = selected, !m.efforts.contains(s.effort) {
        print("note: \(m.displayName) has no effort \(s.effort); using its default")
        s.effort = ""
    }
    if s.fastTier, selected?.fastTierId == nil { s.fastTier = false }
    return s
}

@MainActor
private func waitForSettledAuth(_ service: ProviderService, timeout: TimeInterval = 30) async -> AuthState {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        switch service.authState {
        case .unknown, .checking: try? await Task.sleep(nanoseconds: 100_000_000)
        default: return service.authState
        }
    }
    return service.authState
}

private func e2eDescribe(_ state: AuthState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .checking: return "checking"
    case .signedIn(let account): return "signed in (\(account))"
    case .signedOut(let reason): return "signed out: \(reason)"
    case .loggingIn(let p): return "signing in: \(p.message)"
    case .failed(let message): return "failed: \(message)"
    }
}
