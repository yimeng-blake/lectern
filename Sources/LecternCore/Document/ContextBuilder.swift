import Foundation

/// What the reader is looking at. Written by PDFReaderView; all pages are 0-based.
public struct ReadingState: Equatable, Sendable {
    public var currentPage: Int
    public var visiblePages: [Int]
    public var selectionText: String?
    public var selectionPages: [Int]

    public init(currentPage: Int = 0, visiblePages: [Int] = [], selectionText: String? = nil, selectionPages: [Int] = []) {
        self.currentPage = currentPage
        self.visiblePages = visiblePages
        self.selectionText = selectionText
        self.selectionPages = selectionPages
    }
}

public struct ContextOptions: Sendable {
    public var neighborRadius: Int = 1
    public var attachPageImage: Bool = false
    public var wholeDocument: Bool = false
    /// Upper bound for whole-document mode, in estimated tokens (see `ContextBuilder.estimateTokens`).
    public var tokenBudget: Int

    public init(neighborRadius: Int = 1, attachPageImage: Bool = false, wholeDocument: Bool = false,
                tokenBudget: Int = ContextOptions.defaultTokenBudget(for: .codex)) {
        self.neighborRadius = neighborRadius
        self.attachPageImage = attachPageImage
        self.wholeDocument = wholeDocument
        self.tokenBudget = tokenBudget
    }

    /// `model` as sent or resolved. Claude Haiku has a 200K context window (the other Claude models 1M),
    /// so it keeps room for instructions, history and the answer.
    public static func defaultTokenBudget(for provider: Provider, model: String = "") -> Int {
        switch provider {
        case .claude: return model.lowercased().contains("haiku") ? 140_000 : 300_000
        case .codex: return 150_000
        }
    }
}

public struct BuiltPrompt: Sendable {
    public var request: TurnRequest
    /// Every page in this prompt's <pages> block (sent now or provided earlier), 0-based, ascending.
    public var pagesIncluded: [Int]
    /// Envelope + question text, plus a flat allowance per attached image.
    public var estimatedTokens: Int
    /// Pages whose text went over the wire for the first time with this prompt, 0-based.
    public var newlySentPages: [Int] = []

    var newlySentImagePages: [Int] = []
    var sentOutline = false
    var generation = 0

    public init(request: TurnRequest, pagesIncluded: [Int], estimatedTokens: Int) {
        self.request = request
        self.pagesIncluded = pagesIncluded
        self.estimatedTokens = estimatedTokens
    }
}

/// One per (document, provider conversation). Tracks which pages were already sent so each page's
/// text goes over the wire once per conversation.
public final class ContextBuilder: @unchecked Sendable {
    public let document: ReaderDocument

    private let lock = NSLock()
    private var sentPages = Set<Int>()
    private var sentImagePages = Set<Int>()
    private var outlineSent = false
    private var generation = 0

    /// Selections longer than this are cut (with a note) before quoting.
    public static let selectionCharLimit = 4_000
    /// A selection spanning more pages than this (Select All, a long drag) only adds its first and last pages.
    static let selectionPageLimit = 5
    /// A current page with less extractable text than this gets its image attached automatically.
    public static let sparseTextThreshold = 400
    /// Rough per-image cost (a ~1600 px page is about 1.2–1.6k tokens for both backends).
    static let imageTokenAllowance = 1_600
    static let searchTopK = 12
    /// Runs of at least this many already-sent pages collapse into one line (whole-document mode).
    static let collapseRunLength = 5

    public init(document: ReaderDocument) {
        self.document = document
    }

    /// New conversation: forget sentPages and outlineSent.
    public func reset() {
        lock.withLock {
            sentPages = []
            sentImagePages = []
            outlineSent = false
            generation += 1
        }
    }

    /// Undo the bookkeeping of a prompt that never reached the backend (e.g. the send failed before
    /// the process accepted it), so its pages are sent again next time.
    public func discard(_ prompt: BuiltPrompt) {
        lock.withLock {
            guard prompt.generation == generation else { return }
            sentPages.subtract(prompt.newlySentPages)
            sentImagePages.subtract(prompt.newlySentImagePages)
            if prompt.sentOutline { outlineSent = false }
        }
    }

    public func build(question: String, state: ReadingState, options: ContextOptions) async -> BuiltPrompt {
        let (alreadySent, imagesAlreadySent, outlineAlreadySent, startGeneration) =
            lock.withLock { (sentPages, sentImagePages, outlineSent, generation) }

        let pageCount = document.pageCount
        let current = min(max(state.currentPage, 0), max(pageCount - 1, 0))
        let radius = max(0, options.neighborRadius)
        let neighborhood = pageCount == 0 ? [] : Array(max(0, current - radius)...min(pageCount - 1, current + radius))
        let selectionPages = Array(Set(state.selectionPages.filter { $0 >= 0 && $0 < pageCount })).sorted()
        let selection = Self.cleanSelection(state.selectionText)

        // Pages the selection adds beyond the neighborhood, kept within the token budget.
        var selectionExtra: [Int] = []
        var selectionNote = ""
        if selection != nil, let first = selectionPages.first, let last = selectionPages.last {
            var candidates = selectionPages
            if selectionPages.count > Self.selectionPageLimit {
                candidates = [first, last]
                selectionNote = "; the selection spans \(Self.pageRef(selectionPages)), so only its first and last pages are included"
            }
            selectionExtra = candidates.filter { !neighborhood.contains($0) }
            var costs: [Int: Int] = [:]
            for page in neighborhood + selectionExtra where !alreadySent.contains(page) {
                costs[page] = Self.estimateTokens(await document.pageText(page)) + 8
            }
            var unsentCost = costs.values.reduce(0, +)
            var dropped = false
            while unsentCost > options.tokenBudget,
                  let far = selectionExtra.max(by: { abs($0 - current) < abs($1 - current) }) {
                selectionExtra.removeAll { $0 == far }
                unsentCost -= costs[far] ?? 0
                dropped = true
            }
            if dropped { selectionNote += "; selected pages furthest from the current page were left out to stay within the context budget" }
        }

        var pages = Set(neighborhood).union(selectionExtra)
        let basePages = pages

        var contextLine: String
        let extraNote = selectionExtra.isEmpty ? "" : " and the selection"
        let neighborhoodLabel = radius == 0 ? "current page" : "current page ±\(radius)"
        contextLine = "context: text of \(Self.pageList(Array(pages).sorted())) (\(neighborhoodLabel)\(extraNote))\(selectionNote)"

        if options.wholeDocument, pageCount > 0 {
            let texts = await document.allPageTexts()
            let pageCosts = texts.map { Self.estimateTokens($0) + 8 }
            let documentTokens = pageCosts.reduce(0, +)
            if documentTokens <= options.tokenBudget {
                pages = Set(0..<pageCount)
                contextLine = "context: whole document (all \(Self.plural(pageCount, "page")))"
            } else {
                let hits = await document.searchPages(question, topK: Self.searchTopK)
                var spent = basePages.filter { !alreadySent.contains($0) }.reduce(0) { $0 + pageCosts[$1] }
                var added: [Int] = []
                for page in hits where !pages.contains(page) {
                    let cost = alreadySent.contains(page) ? 12 : pageCosts[page]
                    if spent + cost > options.tokenBudget { continue }
                    spent += cost
                    pages.insert(page)
                    added.append(page)
                }
                let tooLong = "whole document requested, but it is too long (~\(Self.formatted(documentTokens)) tokens)"
                if added.isEmpty {
                    contextLine = "context: \(tooLong); no other pages matched the question, so this is \(neighborhoodLabel)\(extraNote): \(Self.pageList(Array(pages).sorted()))\(selectionNote)"
                } else {
                    contextLine = "context: \(tooLong); sent the pages that best match the question (\(Self.pageList(added.sorted()))) plus \(neighborhoodLabel)\(extraNote)\(selectionNote)"
                }
            }
        }

        let included = Array(pages).sorted()

        // Page image: on request, or automatically when the current page has little text (scans,
        // slides, charts). The automatic one is sent once per conversation.
        var images: [URL] = []
        var newImagePages: [Int] = []
        var imageLine: String?
        if pageCount > 0 {
            let currentText = await document.pageText(current)
            let sparse = currentText.count < Self.sparseTextThreshold
            let label = "page \(current + 1)"
            if options.attachPageImage || (sparse && !imagesAlreadySent.contains(current)) {
                if let url = await document.renderPagePNG(current) {
                    images.append(url)
                    newImagePages.append(current)
                    imageLine = sparse && !options.attachPageImage
                        ? "page image: \(label) is attached as an image (it has little extractable text)"
                        : "page image: \(label) is attached as an image"
                }
            } else if sparse {
                imageLine = "page image: the image of \(label) was provided earlier"
            }
        }

        var outlineLine: String?
        if !outlineAlreadySent {
            let entries = await document.outline()
            if !entries.isEmpty {
                outlineLine = "outline: " + entries.enumerated()
                    .map { "\($0.offset + 1). \(Self.sanitize(Self.singleLine($0.element.title))) — p. \($0.element.page + 1)" }
                    .joined(separator: " · ")
            }
        }

        var header = "document: \"\(Self.singleLine(document.title))\" · \(Self.plural(pageCount, "page"))"
        if pageCount > 0 {
            let visible = state.visiblePages.filter { $0 >= 0 && $0 < pageCount }
            header += " · current page \(current + 1) · visible \(Self.pageRanges(visible.isEmpty ? [current] : visible))"
        }

        var contextLines = [header]
        if await document.isTextLocked() {
            contextLines.append("note: the PDF is password-protected and still locked, so no page text or images are available")
        }
        if let selection {
            let onPages = selectionPages.isEmpty ? "" : " (\(Self.pageRef(selectionPages)))"
            contextLines.append("selection\(onPages): \"\(selection)\"")
        }
        contextLines.append(contextLine)
        if let imageLine { contextLines.append(imageLine) }
        if let outlineLine { contextLines.append(outlineLine) }

        var newPages: [Int] = []
        var pageBlocks: [String] = []
        var index = 0
        while index < included.count {
            let page = included[index]
            if alreadySent.contains(page) {
                var end = index
                while end + 1 < included.count, included[end + 1] == included[end] + 1,
                      alreadySent.contains(included[end + 1]) { end += 1 }
                if end - index + 1 >= Self.collapseRunLength {
                    let range = "\(page + 1)–\(included[end] + 1)"
                    pageBlocks.append("=== Pages \(range) ===\n(pages \(range) were provided earlier)")
                    index = end + 1
                    continue
                }
                pageBlocks.append("=== Page \(page + 1) ===\n(page \(page + 1) was provided earlier)")
            } else {
                let text = await document.pageText(page)
                let body = text.isEmpty
                    ? (newImagePages.contains(page) ? "(no extractable text on this page; see the attached image)"
                                                    : "(no extractable text on this page)")
                    : Self.sanitize(text)
                pageBlocks.append("=== Page \(page + 1) ===\n\(body)")
                newPages.append(page)
            }
            index += 1
        }

        let questionText = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        <reading_context>
        \(contextLines.joined(separator: "\n"))
        </reading_context>
        <pages>
        \(pageBlocks.joined(separator: "\n"))
        </pages>
        Question: \(questionText)
        """

        var built = BuiltPrompt(request: TurnRequest(text: text, imagePNGs: images),
                                pagesIncluded: included,
                                estimatedTokens: Self.estimateTokens(text) + images.count * Self.imageTokenAllowance)
        built.newlySentPages = newPages
        built.newlySentImagePages = newImagePages
        built.sentOutline = !outlineAlreadySent
        built.generation = startGeneration

        lock.withLock {
            // A reset() while we were building means this prompt belongs to the old conversation.
            guard generation == startGeneration else { return }
            sentPages.formUnion(newPages)
            sentImagePages.formUnion(newImagePages)
            outlineSent = true
        }
        return built
    }

    // MARK: Helpers

    /// chars/4 for Latin text; CJK and other non-ASCII scripts cost more per character, so they are
    /// weighted up to keep whole-document mode from overshooting the budget on such documents.
    public static func estimateTokens(_ text: String) -> Int {
        var quarterTokens = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                quarterTokens += 1
            } else if scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
                        || (0xAC00...0xD7AF).contains(scalar.value) {
                quarterTokens += 4
            } else {
                quarterTokens += 2
            }
        }
        return (quarterTokens + 3) / 4
    }

    static func cleanSelection(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > selectionCharLimit else { return sanitize(collapsed) }
        return sanitize(String(collapsed.prefix(selectionCharLimit))) + "… (selection truncated)"
    }

    /// Keeps document text from closing or opening our envelope tags.
    static func sanitize(_ text: String) -> String {
        var s = text
        for tag in ["reading_context", "pages"] {
            s = s.replacingOccurrences(of: "</\(tag)>", with: "‹/\(tag)›", options: .caseInsensitive)
                .replacingOccurrences(of: "<\(tag)>", with: "‹\(tag)›", options: .caseInsensitive)
        }
        return s
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    static func plural(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    static func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 0-based pages → "12", "12–13", "3, 7–9" (1-based).
    static func pageRanges(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i] + 1)" : "\(sorted[i] + 1)–\(sorted[j] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    /// "page 3" / "pages 3–5".
    static func pageList(_ pages: [Int]) -> String {
        Set(pages).count == 1 ? "page \(pageRanges(pages))" : "pages \(pageRanges(pages))"
    }

    /// "p. 3" / "pp. 3–5".
    static func pageRef(_ pages: [Int]) -> String {
        Set(pages).count == 1 ? "p. \(pageRanges(pages))" : "pp. \(pageRanges(pages))"
    }
}
