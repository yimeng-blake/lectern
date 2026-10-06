import Foundation
import LecternCore

@MainActor
func contextProbeCommands() -> [ProbeCommand] {
    [
        ProbeCommand(
            name: "context-build",
            help: "--pdf P --page N (1-based) [--select \"text\" [--select-pages A-B]] [--image] [--whole] [--turns \"q1|q2\"] [--radius R] [--budget T] [--reset-before K] [--password P]",
            run: contextBuildCommand),
        ProbeCommand(
            name: "pdf-info",
            help: "--pdf P [--query \"words\"] [--render N (1-based)]: pages, hash, outline, extraction timing",
            run: pdfInfoCommand),
    ]
}

/// `--password P` unlocks an encrypted PDF the way the app's password prompt does.
@MainActor
private func openDocument(_ args: [String]) async -> ReaderDocument? {
    guard let path = option("pdf", in: args) else {
        print("error: --pdf <path> is required")
        return nil
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url),
          let doc = ReaderDocument(data: data, fileURL: url, title: url.deletingPathExtension().lastPathComponent) else {
        print("error: cannot open \(url.path) as a PDF")
        return nil
    }
    if doc.isLocked, let password = option("password", in: args) {
        print(await doc.unlock(password: password) ? "unlocked" : "error: wrong password")
    }
    return doc
}

private func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

/// Builds one prompt per turn with a single ContextBuilder, as a conversation would, and prints each envelope.
@MainActor
private func contextBuildCommand(_ args: [String]) async -> Int32 {
    guard let doc = await openDocument(args) else { return 2 }
    let page = (option("page", in: args).flatMap(Int.init) ?? 1) - 1
    let selection = option("select", in: args)
    let turns = (option("turns", in: args) ?? "What is on this page?")
        .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let resetBefore = option("reset-before", in: args).flatMap(Int.init)

    var options = ContextOptions(tokenBudget: option("budget", in: args).flatMap(Int.init)
                                 ?? ContextOptions.defaultTokenBudget(for: .claude))
    options.neighborRadius = option("radius", in: args).flatMap(Int.init) ?? 1
    options.attachPageImage = flag("image", in: args)
    options.wholeDocument = flag("whole", in: args)

    // 1-based inclusive range the selection spans (default: the current page).
    var selectionPages = selection == nil ? [] : [page]
    if selection != nil, let range = option("select-pages", in: args) {
        let bounds = range.split(separator: "-").compactMap { Int($0) }
        if bounds.count == 2, bounds[0] >= 1, bounds[0] <= bounds[1] { selectionPages = Array((bounds[0] - 1)...(bounds[1] - 1)) }
    }
    let state = ReadingState(currentPage: page, visiblePages: [page],
                             selectionText: selection, selectionPages: selectionPages)
    let builder = ContextBuilder(document: doc)
    for (i, question) in turns.enumerated() {
        if let resetBefore, resetBefore == i + 1 {
            builder.reset()
            print("--- reset() before turn \(i + 1)")
        }
        let start = DispatchTime.now()
        let built = await builder.build(question: question, state: state, options: options)
        print("--- turn \(i + 1) (build \(milliseconds(since: start)) ms)")
        print(built.request.text)
        print("pagesIncluded (1-based): \(built.pagesIncluded.map { $0 + 1 })")
        print("newlySentPages (1-based): \(built.newlySentPages.map { $0 + 1 })")
        print("estimatedTokens: \(built.estimatedTokens)")
        for url in built.request.imagePNGs { print("image: \(url.path)") }
    }
    return 0
}

@MainActor
private func pdfInfoCommand(_ args: [String]) async -> Int32 {
    let openStart = DispatchTime.now()
    guard let doc = await openDocument(args) else { return 2 }
    let openMs = milliseconds(since: openStart)
    print("title: \(doc.title)")
    print("pages: \(doc.pageCount)")
    print("sha256: \(doc.contentHash)")
    print("open_ms: \(openMs)")
    guard doc.pageCount > 0 else { return 0 }

    var start = DispatchTime.now()
    let first = await doc.pageText(0)
    print("page1_text_ms: \(milliseconds(since: start)) (\(first.count) chars)")

    start = DispatchTime.now()
    var chars = 0
    var emptyPages = 0
    for i in 0..<doc.pageCount {
        let text = await doc.pageText(i)
        chars += text.count
        if text.count < ContextBuilder.sparseTextThreshold { emptyPages += 1 }
    }
    print("full_extract_ms: \(milliseconds(since: start)) (\(chars) chars, ~\(chars / 4) tokens, \(emptyPages) pages under \(ContextBuilder.sparseTextThreshold) chars)")

    start = DispatchTime.now()
    let outline = await doc.outline()
    print("outline: \(outline.count) entries (\(milliseconds(since: start)) ms)")
    for entry in outline.prefix(10) { print("  \(entry.title) — p. \(entry.page + 1)") }

    if let query = option("query", in: args) {
        start = DispatchTime.now()
        let hits = await doc.searchPages(query, topK: 12)
        print("search \"\(query)\": \(hits.map { $0 + 1 }) (\(milliseconds(since: start)) ms, first search builds the index)")
        start = DispatchTime.now()
        _ = await doc.searchPages(query, topK: 12)
        print("search again: \(milliseconds(since: start)) ms")
    }
    if let n = option("render", in: args).flatMap(Int.init) {
        start = DispatchTime.now()
        let url = await doc.renderPagePNG(n - 1)
        print("render p. \(n): \(url?.path ?? "failed") (\(milliseconds(since: start)) ms)")
    }
    return 0
}
