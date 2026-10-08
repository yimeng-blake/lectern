import Foundation
import LecternCore

// "On This Mac": Apple's on-device model and local Ollama models. Never opens apps or web pages.

@MainActor
func localProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(name: "local-status",
                     help: "[--ollama-url U] [--start]  Apple Intelligence + Ollama status, models, suggestions, budgets; "
                         + "--start runs the setup click (startLogin) without opening anything",
                     run: localStatus),
        ProbeCommand(name: "local-ask",
                     help: "[--model apple.on-device|ollama:NAME] [--pdf P --page N [--radius R] [--image] [--whole]] "
                         + "[--followup Q] [--show-prompt] [--stop-after S] [--timeout S] \"question\"",
                     run: localAsk),
        ProbeCommand(name: "local-pull", help: "NAME [--cancel-after S]  download a model with Ollama (/api/pull)",
                     run: localPull),
    ]
}

@MainActor
private func makeLocalService(_ args: [String]) async -> LocalService {
    let service = option("ollama-url", in: args).flatMap(URL.init(string:)).map { LocalService(ollamaURL: $0) } ?? LocalService()
    service.urlOpener = { print("(not opening \($0.absoluteString))") }
    service.appOpener = { print("(not opening \($0.path))") }
    await service.refresh()
    return service
}

@MainActor
private func localStatus(_ args: [String]) async -> Int32 {
    let service = await makeLocalService(args)
    print("apple: \(service.appleStatus)")
    print("ollama: \(service.ollamaStatus) · Ollama.app \(service.canOpenOllama ? "installed" : "not found")")
    print("auth: \(service.authState)")
    print("default model: \(service.defaultModelId ?? "-")")
    for m in service.models {
        print("  \(m.isDefault ? "*" : " ") \(m.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(m.displayName)"
              + " · \(m.detail ?? "") · budget \(ContextOptions.defaultTokenBudget(for: .local, model: m.id))")
    }
    print("budget for default (\"\"): \(ContextOptions.defaultTokenBudget(for: .local))")
    print("suggestions:")
    for s in LocalService.suggestions { print("    \(s.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.title) · \(s.size) · \(s.note)") }
    if flag("start", in: args) {
        service.startLogin(.browser)
        print("after click: \(service.authState)")
        for _ in 0..<40 {
            if case .loggingIn = service.authState { try? await Task.sleep(nanoseconds: 1_000_000_000) } else { break }
        }
        print("settled: \(service.authState)")
    }
    return 0
}

private let localValueOptions: Set<String> = ["model", "pdf", "page", "radius", "followup", "timeout", "stop-after",
                                              "cancel-after", "ollama-url"]

@MainActor
private func localAsk(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let question = positional(args, valueOptions: localValueOptions).first else {
        print("usage: lectern-probe local-ask --model apple.on-device|ollama:NAME [--pdf P --page N] \"question\"")
        return 2
    }
    let service = await makeLocalService(args)
    let model = option("model", in: args) ?? ""
    print("auth: \(service.authState) · model \(model.isEmpty ? "(default \(service.defaultModelId ?? "-"))" : model)")
    let settings = TurnSettings(model: model)
    let session = service.makeSession(conversationId: nil)
    defer { session.shutdown() }

    var builder: ContextBuilder?
    var page = 1
    if let path = option("pdf", in: args) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let document = ReaderDocument(data: data, fileURL: url, title: url.deletingPathExtension().lastPathComponent) else {
            print("can't open \(url.path) as a PDF")
            return 2
        }
        page = min(max(1, option("page", in: args).flatMap(Int.init) ?? 1), document.pageCount)
        builder = ContextBuilder(document: document)
        print("document: \"\(document.title)\" · \(document.pageCount) pages · page \(page)")
    }
    var options = ContextOptions(tokenBudget: ContextOptions.defaultTokenBudget(for: .local, model: model))
    options.neighborRadius = option("radius", in: args).flatMap(Int.init) ?? 1
    options.attachPageImage = flag("image", in: args)
    options.wholeDocument = flag("whole", in: args)
    let timeout = option("timeout", in: args).flatMap(Double.init) ?? 300
    let stopAfter = option("stop-after", in: args).flatMap(Double.init)

    var questions = [question]
    if let followup = option("followup", in: args) { questions.append(followup) }
    for (index, q) in questions.enumerated() {
        print("\n>>> turn \(index + 1): \(q)")
        var resets = 0
        while true {
            var request = TurnRequest(text: q)
            if let builder {
                let state = ReadingState(currentPage: page - 1, visiblePages: [page - 1])
                let built = await builder.build(question: q, state: state, options: options)
                print("context: pages \(built.pagesIncluded.map { $0 + 1 }) (new \(built.newlySentPages.map { $0 + 1 }))"
                      + " · ~\(built.estimatedTokens) tokens · images \(built.request.imagePNGs.count) · budget \(options.tokenBudget)")
                request = built.request
            }
            if flag("show-prompt", in: args) { print("--- prompt ---\n\(request.text)\n--- end prompt ---") }
            let outcome = await localRunTurn(session, request, settings, timeout: timeout, stopAfter: index == 0 ? stopAfter : nil)
            switch outcome {
            case "reset" where resets == 0:
                resets += 1
                builder?.reset()
                print("[conversation reset: rebuilding the prompt for a fresh conversation]")
                continue
            case "completed", "interrupted":
                break
            default:
                return 1
            }
            break
        }
    }
    return 0
}

/// Runs one turn and prints its events; returns "completed", "interrupted", "reset" or "failed".
@MainActor
private func localRunTurn(_ session: ChatSession, _ request: TurnRequest, _ settings: TurnSettings,
                          timeout: TimeInterval, stopAfter: TimeInterval?) async -> String {
    let start = Date()
    var streamed = false
    let outcome: String = await withCheckedContinuation { continuation in
        var done = false
        func end(_ o: String) {
            guard !done else { return }
            done = true
            continuation.resume(returning: o)
        }
        session.onEvent = { event in
            switch event {
            case .sessionReady(let model): print("[model \(model)]")
            case .thinking: break
            case .textDelta(let d):
                if !streamed { print("[first text after \(String(format: "%.1f", Date().timeIntervalSince(start))) s]") }
                streamed = true
                print(d, terminator: "")
                fflush(stdout)
            case .warning(let w): print("[warning] \(w)")
            case .quota: break
            case .conversationReset: print("[conversationReset]"); end("reset")
            case .completed(let text, let usage):
                print("\n[completed in \(String(format: "%.1f", Date().timeIntervalSince(start))) s · \(text.count) chars"
                      + (usage.map { " · in \($0.inputTokens ?? 0) / out \($0.outputTokens ?? 0) tokens" } ?? "") + "]")
                end("completed")
            case .interrupted: print("\n[interrupted after \(String(format: "%.1f", Date().timeIntervalSince(start))) s]"); end("interrupted")
            case .failed(let error): print("\n[failed] \(error)"); end("failed")
            }
        }
        session.send(request, settings: settings)
        Task { @MainActor in
            let wait = min(stopAfter ?? timeout, timeout)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !done else { return }
            print("\n[\(stopAfter != nil ? "stop" : "timeout") after \(Int(wait)) s: interrupting]")
            session.interrupt()
        }
    }
    session.onEvent = nil
    return outcome
}

@MainActor
private func localPull(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let name = positional(args, valueOptions: localValueOptions).first else {
        print("usage: lectern-probe local-pull NAME [--cancel-after S]")
        return 2
    }
    let service = await makeLocalService(args)
    print("ollama: \(service.ollamaStatus)")
    let start = Date()
    var lastLine = ""
    let monitor = Task { @MainActor in
        while !Task.isCancelled {
            if let d = service.download {
                let line = "\(d.model) \(String(format: "%.0f", d.progress * 100))% · \(d.status)"
                if line != lastLine { print(line); lastLine = line }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    if let seconds = option("cancel-after", in: args).flatMap(Double.init) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            print("[cancelling]")
            service.cancelDownload()
        }
    }
    let ok = await service.downloadModel(name)
    monitor.cancel()
    print("result: \(ok ? "downloaded" : "not downloaded") in \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
          + (service.downloadError.map { " · error: \($0)" } ?? ""))
    print("ollama now: \(service.ollamaStatus) · default \(service.defaultModelId ?? "-")")
    return ok ? 0 : 1
}
