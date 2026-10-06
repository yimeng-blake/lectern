import Foundation

/// Guesses from extracted text whether a page is mostly a table. PDFKit flattens tables into runs of
/// numbers, so such pages get their image attached for the model to read the layout.
enum TableDetector {
    static func isTableHeavy(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        var rowLines = 0, tokens = 0, numeric = 0, marked = 0
        for line in lines {
            let n = line.filter(isNumericToken).count
            tokens += line.count
            numeric += n
            marked += line.filter { $0.contains("%") || $0.first.map { "$€£¥".contains($0) } == true }.count
            if isRow(numeric: n, tokens: line.count) { rowLines += 1 }
        }
        let density = Double(numeric) / Double(tokens)
        if rowLines >= 3, rowLines * 4 >= lines.count { return true }
        // One cell per line (another common PDFKit layout for tables).
        if numeric >= 15, density >= 0.3 { return true }
        return rowLines >= 6 && (density >= 0.15 || marked >= 6)
    }

    /// Two or more figures making up a good share of the line (prose with numbers doesn't).
    static func isRowLike(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        return isRow(numeric: tokens.filter(isNumericToken).count, tokens: tokens.count)
    }

    private static func isRow(numeric: Int, tokens: Int) -> Bool {
        numeric >= 2 && Double(numeric) / Double(tokens) >= 0.3
    }

    /// 1,234 · 412.7 · (1.2) · −3 · $74.1M · 27.3% · 12x — not years-in-words like "Q3" or "FY26".
    static func isNumericToken(_ token: Substring) -> Bool {
        var s = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[],;:*+-−–—$€£¥%"))
        if let last = s.last, "MBKmbkx".contains(last), s.count > 1 { s.removeLast() }
        guard let first = s.first, first.isASCII, first.isNumber else { return false }
        return s.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
    }
}
