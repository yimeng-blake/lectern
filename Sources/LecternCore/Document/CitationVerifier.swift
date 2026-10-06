import Foundation

/// Checks an answer's page citations against the cited pages' text: every number and quoted phrase in
/// the claim a citation supports should appear on one of its pages.
public enum CitationVerifier {
    /// One `CitationCheck` per citation, in the order they appear in `answer` (markdown).
    public static func verify(answer: String, in document: ReaderDocument) async -> [CitationCheck] {
        let citations = parse(answer)
        guard !citations.isEmpty else { return [] }
        let pageCount = document.pageCount
        let locked = await document.isTextLocked()
        var pageItems: [Int: PageItems] = [:]
        var checks: [CitationCheck] = []
        for citation in citations {
            if citation.pages.isEmpty || citation.pages.contains(where: { $0 < 1 || $0 > pageCount }) {
                checks.append(CitationCheck(ordinal: citation.ordinal, pages: citation.pages, claim: citation.claim,
                                            status: .pageMissing, missing: []))
                continue
            }
            let numbers = ClaimText.numbers(in: citation.claim)
            let phrases = ClaimText.quotedPhrases(in: citation.claim)
            guard !locked, !numbers.isEmpty || !phrases.isEmpty else {
                checks.append(CitationCheck(ordinal: citation.ordinal, pages: citation.pages, claim: citation.claim,
                                            status: .unchecked, missing: []))
                continue
            }
            // Adjacent citations ("[p. 1][p. 3]") share one claim and are checked against all their pages.
            let pages = Set(citations.filter { $0.group == citation.group }.flatMap(\.pages))
                .filter { $0 >= 1 && $0 <= pageCount }.sorted()
            var items: [PageItems] = []
            for page in pages {
                if pageItems[page] == nil { pageItems[page] = PageItems(text: await document.pageText(page - 1)) }
                items.append(pageItems[page]!)
            }
            var missing: [String] = []
            for number in numbers where !items.contains(where: { $0.contains(number) }) { missing.append(number.display) }
            for phrase in phrases where !items.contains(where: { $0.contains(phrase: phrase) }) { missing.append("\"\(phrase)\"") }
            let total = numbers.count + phrases.count
            let status: CitationCheck.Status = missing.isEmpty ? .verified : missing.count == total ? .notFound : .partial
            checks.append(CitationCheck(ordinal: citation.ordinal, pages: citation.pages, claim: citation.claim,
                                        status: status, missing: missing))
        }
        return checks
    }

    struct Citation {
        var ordinal: Int
        /// 1-based, as written.
        var pages: [Int]
        var range: NSRange
        var claim: String
        /// Citations next to each other with nothing but punctuation between them share a group.
        var group: Int
    }

    /// Same syntax as the transcript's links (chat.js CITE_RE): [p. 3], [pp. 3–5], (p. 2, 4), [pages 2; 7].
    static let citationRegex = try! NSRegularExpression(
        pattern: #"([\[(])((?:pp?\.|pages?)\s*\d+(?:\s*[–—-]\s*\d+)?(?:\s*[,;]\s*(?:(?:pp?\.|pages?)\s*)?\d+(?:\s*[–—-]\s*\d+)?)*)([\])])"#,
        options: [.caseInsensitive])
    private static let pageItemRegex = try! NSRegularExpression(pattern: #"(\d+)(?:\s*[–—-]\s*(\d+))?"#)
    /// Code, and markdown links (their text is a link already, so chat.js doesn't make it a citation).
    private static let skippedRegex = try! NSRegularExpression(pattern: "```[\\s\\S]*?(?:```|$)|`[^`\\n]*`|!?\\[[^\\]\\n]*\\]\\([^)\\s]*\\)")
    static let maxRangePages = 50

    static func parse(_ answer: String) -> [Citation] {
        let ns = answer as NSString
        // Citations inside code or link text aren't citation links in the transcript, so they don't count.
        let masked = NSMutableString(string: ns)
        for match in skippedRegex.matches(in: answer, range: NSRange(location: 0, length: ns.length)).reversed() {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        var found: [(range: NSRange, pages: [Int])] = []
        for match in citationRegex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
            let open = ns.substring(with: match.range(at: 1)), close = ns.substring(with: match.range(at: 3))
            guard (open == "[") == (close == "]") else { continue }
            let inner = ns.substring(with: match.range(at: 2))
            var pages: [Int] = []
            for item in pageItemRegex.matches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) {
                let s = inner as NSString
                guard let first = Int(s.substring(with: item.range(at: 1))) else { continue }
                var last = item.range(at: 2).location == NSNotFound ? first : Int(s.substring(with: item.range(at: 2))) ?? first
                if last < first { last = first }
                for page in first...min(last, first + maxRangePages - 1) where !pages.contains(page) { pages.append(page) }
            }
            found.append((match.range, pages))
        }

        var citations: [Citation] = []
        for (i, item) in found.enumerated() {
            let previous = i > 0 ? found[i - 1].range : nil
            let next = i + 1 < found.count ? found[i + 1].range : nil
            var group = citations.last.map { $0.group + 1 } ?? 0
            var claim: String
            if let previous, let last = citations.last,
               !ClaimText.hasContent(ns.substring(with: NSRange(location: previous.upperBound,
                                                               length: item.range.location - previous.upperBound))) {
                claim = last.claim
                group = last.group
            } else if let row = tableRow(containing: item.range, in: ns) {
                claim = row
            } else {
                claim = sentenceClaim(for: item.range, previous: previous, next: next, in: ns)
            }
            citations.append(Citation(ordinal: i, pages: item.pages, range: item.range, claim: claim, group: group))
        }
        return citations
    }

    /// The text before the citation back to the sentence start (or the previous citation); when this
    /// is the sentence's last citation, also the rest of the sentence. A citation placed after the
    /// sentence ("… 61.3%. [p. 2]") takes the sentence before it.
    private static func sentenceClaim(for range: NSRange, previous: NSRange?, next: NSRange?, in ns: NSString) -> String {
        let floor = previous?.upperBound ?? 0
        let start = segmentStart(before: range.location, floor: floor, in: ns)
        let lead = ns.substring(with: NSRange(location: start, length: range.location - start))
        if ClaimText.hasContent(lead) {
            let end = segmentEnd(after: range.upperBound, in: ns)
            let trail = next.map { $0.location < end } == true ? ""
                : ns.substring(with: NSRange(location: range.upperBound, length: end - range.upperBound))
            return ClaimText.clean(lead + trail)
        }
        var j = start - 1
        while j >= floor, let scalar = Unicode.Scalar(ns.character(at: j)), scalar.properties.isWhitespace,
              ns.character(at: j) != 10 { j -= 1 }
        guard j >= floor else { return "" }
        let previousStart = segmentStart(before: j, floor: floor, in: ns)
        return ClaimText.clean(ns.substring(with: NSRange(location: previousStart, length: j + 1 - previousStart)))
    }

    /// A markdown table row's cells (without citations), when the citation sits in one.
    private static func tableRow(containing range: NSRange, in ns: NSString) -> String? {
        let line = ns.substring(with: ns.lineRange(for: range)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("|") else { return nil }
        let cells = line.split(separator: "|").map { ClaimText.clean(String($0)) }.filter(ClaimText.hasContent)
        return cells.joined(separator: " · ")
    }

    private static func segmentStart(before location: Int, floor: Int, in ns: NSString) -> Int {
        var i = location - 1
        while i >= floor {
            if isBoundary(i, in: ns) { return i + 1 }
            i -= 1
        }
        return max(floor, 0)
    }

    private static func segmentEnd(after location: Int, in ns: NSString) -> Int {
        var i = location
        while i < ns.length {
            if isBoundary(i, in: ns) { return ns.character(at: i) == 10 ? i : i + 1 }
            i += 1
        }
        return ns.length
    }

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "inc", "corp", "ltd", "co", "mr", "ms", "mrs", "dr", "no", "fig", "approx", "est",
        "u.s", "u.k", "p", "pp", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// Line breaks, table cell bars, CJK sentence ends, and . ! ? followed by a space (not "e.g.", "Inc.").
    private static func isBoundary(_ i: Int, in ns: NSString) -> Bool {
        let c = ns.character(at: i)
        switch c {
        case 10, 124, 0x3002, 0xFF01, 0xFF1F: return true
        case 46, 33, 63:
            if i + 1 < ns.length, let next = Unicode.Scalar(ns.character(at: i + 1)),
               !next.properties.isWhitespace, !"\"”’)*_".unicodeScalars.contains(next) { return false }
            guard c == 46 else { return true }
            var j = i - 1
            while j >= 0, let s = Unicode.Scalar(ns.character(at: j)), s.properties.isAlphabetic || s == "." { j -= 1 }
            let word = ns.substring(with: NSRange(location: j + 1, length: i - j - 1)).lowercased()
            return !(abbreviations.contains(word) || word.count == 1)
        default: return false
        }
    }
}

/// Numbers and quoted phrases of a cited page, prepared for matching.
struct PageItems {
    let numberForms: Set<String>
    /// The page's digits with thousands separators removed, for numbers PDF text glued to words.
    let bareDigits: String
    let phraseText: String
    let compactText: String

    init(text: String) {
        numberForms = Set(ClaimText.numbers(in: text).flatMap(\.forms))
        bareDigits = text.replacingOccurrences(of: ",", with: "")
        phraseText = ClaimText.phraseNormalized(text)
        compactText = phraseText.replacingOccurrences(of: " ", with: "")
    }

    func contains(_ number: ClaimText.Number) -> Bool {
        if !numberForms.isDisjoint(with: number.forms) { return true }
        // "Revenue412.7" (no space in the PDF text): the digits alone, for long or decimal numerals.
        guard number.numeral.count >= 3 || number.numeral.contains("."),
              let regex = try? NSRegularExpression(pattern: #"(?<![\d.])"# + NSRegularExpression.escapedPattern(for: number.numeral) + #"(?!\.?\d)"#)
        else { return false }
        return regex.firstMatch(in: bareDigits, range: NSRange(location: 0, length: (bareDigits as NSString).length)) != nil
    }

    func contains(phrase: String) -> Bool {
        let normalized = ClaimText.phraseNormalized(phrase)
        guard !normalized.isEmpty else { return true }
        return phraseText.contains(normalized) || compactText.contains(normalized.replacingOccurrences(of: " ", with: ""))
    }
}

/// Claim text helpers shared by CitationVerifier and PassageLocator.
enum ClaimText {
    struct Number: Hashable {
        /// As written in the claim ("$412.7 million").
        var display: String
        /// Digits without thousands separators, as written ("412.7", "1234").
        var numeral: String
        /// Canonical spellings it may appear as on a page: the numeral, and for scaled amounts the value
        /// in units, thousands, millions and billions ("$1.2 billion" ~ "1,200" in a USD-millions table).
        var forms: Set<String>
    }

    /// Currency, sign and % are ignored; "(1.2)" and "−1.2" are 1.2. Digits glued to Latin letters
    /// ("Q3", "FY26") aren't numbers; next to CJK text ("毛利率为61.3%") they are.
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"(?:[$€£¥]\s?)?(?<![\p{Latin}\p{N}.,])(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(?:\s?(%|percent|per cent|million|billion|thousand|trillion|mn|bn|tn|m|b|k)(?![\p{Latin}\p{N}]))?(?![\p{Latin}\p{N}])"#,
        options: [.caseInsensitive])

    static func numbers(in text: String) -> [Number] {
        let ns = text as NSString
        var out: [Number] = []
        var seen = Set<String>()
        for match in numberRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let integer = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let fraction = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let unit = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3)).lowercased()
            let numeral = integer + fraction
            guard let value = Decimal(string: numeral, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            var forms: Set<String> = [canonical(value)]
            let scale: Decimal
            switch unit {
            case "thousand", "k": scale = 1_000
            case "million", "mn", "m": scale = 1_000_000
            case "billion", "bn", "b": scale = 1_000_000_000
            case "trillion", "tn": scale = 1_000_000_000_000
            default: scale = 1
            }
            if scale != 1 {
                for divisor: Decimal in [1, 1_000, 1_000_000, 1_000_000_000] { forms.insert(canonical(value * scale / divisor)) }
            }
            let display = ns.substring(with: match.range).trimmingCharacters(in: .whitespaces)
            guard seen.insert(canonical(value) + "|" + unit).inserted else { continue }
            out.append(Number(display: display, numeral: numeral, forms: forms))
        }
        return out
    }

    /// "412.70" → "412.7", "62.0" → "62", "007" → "7".
    static func canonical(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 6, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private static let quoteRegex = try! NSRegularExpression(pattern: #""([^"\n]{3,300})"|“([^”\n]{3,300})”|「([^」\n]{2,300})」"#)

    static func quotedPhrases(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for match in quoteRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let phrase = ns.substring(with: match.range(at: group))
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;:!?")))
                if !phrase.isEmpty, !out.contains(phrase) { out.append(phrase) }
            }
        }
        return out
    }

    /// Case/diacritic/width-folded, quotes and dashes unified, hyphenated line breaks joined, one space between words.
    static func phraseNormalized(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for (from, to) in [("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"), ("–", "-"), ("—", "-"), ("\u{00AD}", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: "-\n", with: "")
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let markdownRules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#), "$1"),                    // links, images
        (try! NSRegularExpression(pattern: #"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)+"#), ""), // headings, quotes, lists
        (try! NSRegularExpression(pattern: #"\*\*|__|(?<![\p{L}\p{N}])[*_]|[*_](?![\p{L}\p{N}])|`"#), ""),
    ]

    /// Plain text of a claim: citations and markdown removed, whitespace collapsed, dangling punctuation trimmed.
    static func clean(_ text: String) -> String {
        var s = CitationVerifier.citationRegex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        for (regex, template) in markdownRules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
        }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:–—-(|·")))
    }

    static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
