import Foundation

/// Finds the passage on a page that best supports a claim, so the viewer can highlight it.
public enum PassageLocator {
    /// `page` is 0-based. The range is in the page's raw `PDFPage.string` (the UI document's page gives
    /// the same string), ready for `page.selection(for:)`. Nil when the page has no PDF text (e.g. OCR'd
    /// scans) or nothing on it shares the claim's numbers or enough of its words.
    public static func locate(claim: String, page: Int, in document: ReaderDocument) async -> NSRange? {
        locate(claim: claim, in: await document.rawPageString(page))
    }

    static func locate(claim rawClaim: String, in raw: String) -> NSRange? {
        let claim = ClaimText.clean(rawClaim)
        let numbers = ClaimText.numbers(in: claim)
        let words = Set(PageSearchIndex.tokenize(claim).filter { !PageSearchIndex.stopwords.contains($0) && !isNumeric($0) })
        guard !raw.isEmpty, !numbers.isEmpty || !words.isEmpty else { return nil }

        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [NSRange] = []
        // Sentences, continued across a PDF line break when the next line starts in lowercase (or the
        // line ends mid-clause); other breaks (headings, list items) end the sentence. Each replacement
        // is one UTF-16 unit, so offsets stay valid in `raw`.
        let joined = NSMutableString(string: ns)
        for i in 0..<ns.length where ns.character(at: i) == 10 || ns.character(at: i) == 13 {
            var prev = i - 1
            while prev >= 0, ns.character(at: prev) == 32 { prev -= 1 }
            let next = i + 1 < ns.length ? Unicode.Scalar(ns.character(at: i + 1)) : nil
            let continues = next.map { CharacterSet.lowercaseLetters.contains($0) } == true
                || (prev >= 0 && ",;:-–(".utf16.contains(ns.character(at: prev)))
            joined.replaceCharacters(in: NSRange(location: i, length: 1), with: continues ? " " : "\u{2029}")
        }
        joined.enumerateSubstrings(in: full, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            candidates.append(range)
        }
        // …lines, and for table-like lines the label-plus-figures pieces of each row.
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            candidates.append(range)
            candidates.append(contentsOf: rowPieces(of: range, in: ns))
        }

        var best: (range: NSRange, score: Double)?
        for range in candidates {
            let text = ns.substring(with: range)
            let tokens = PageSearchIndex.tokenize(text)
            guard !tokens.isEmpty else { continue }
            let items = PageItems(text: text)
            let numberHits = numbers.filter { items.contains($0) }.count
            let wordHits = words.intersection(tokens).count
            guard numberHits > 0 || wordHits >= min(2, words.count) else { continue }
            let score = Double(3 * numberHits + wordHits) / (1 + 0.02 * Double(tokens.count))
            if score > (best?.score ?? 0) { best = (range, score) }
        }
        return best.map { trimmed($0.range, in: ns) }
    }

    /// "Europe 97.6 84.9 15.0% Asia Pacific 74.1 58.2 27.3%" → "Europe 97.6 84.9 15.0%", "Asia Pacific 74.1 58.2 27.3%".
    private static func rowPieces(of line: NSRange, in ns: NSString) -> [NSRange] {
        guard TableDetector.isRowLike(ns.substring(with: line)) else { return [] }
        var pieces: [NSRange] = []
        var start: Int?
        var end = line.location
        var previousNumeric = false
        for match in tokenRegex.matches(in: ns as String, range: line) {
            let numeric = TableDetector.isNumericToken(Substring(ns.substring(with: match.range)))
            if !numeric, previousNumeric, let s = start {
                pieces.append(NSRange(location: s, length: end - s))
                start = nil
            }
            if start == nil { start = match.range.location }
            end = match.range.upperBound
            previousNumeric = numeric
        }
        if let s = start, !pieces.isEmpty { pieces.append(NSRange(location: s, length: end - s)) }
        return pieces
    }

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\S+"#)

    private static func isNumeric(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || $0 == "." || $0 == "," }
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        var lower = range.location, upper = range.upperBound
        let space = CharacterSet.whitespacesAndNewlines
        while lower < upper, let s = Unicode.Scalar(ns.character(at: lower)), space.contains(s) { lower += 1 }
        while upper > lower, let s = Unicode.Scalar(ns.character(at: upper - 1)), space.contains(s) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }
}
