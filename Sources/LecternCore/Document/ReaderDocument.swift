import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Where a page's text came from.
public enum TextSource: String, Sendable {
    case pdfText
    /// Recognized from the rendered page (a scan): the page had (almost) no extractable text.
    case ocr
    case none
}

/// An open PDF. `pdf` belongs to the UI; text extraction, outline reading and rendering run on a
/// private serial queue against a second PDFDocument built from the same bytes, because PDFKit
/// objects are not thread-safe.
public final class ReaderDocument: @unchecked Sendable {
    /// For the UI (main thread only).
    public let pdf: PDFDocument
    public let title: String
    public let fileURL: URL?
    /// SHA-256 hex of the file bytes.
    public let contentHash: String
    public private(set) var pageCount: Int

    // Everything below is touched only on `queue`.
    private let worker: PDFDocument
    private let queue = DispatchQueue(label: "Lectern.ReaderDocument", qos: .userInitiated)
    private var textCache: [Int: String] = [:]
    private var sourceCache: [Int: TextSource] = [:]
    private var cachedOutline: [(title: String, page: Int)]?
    private var searchIndex: PageSearchIndex?

    static let outlineLimit = 200
    /// Pages with fewer non-space characters of PDF text than this are OCR'd when they show something.
    static let ocrTextThreshold = 25
    static let ocrLongEdge = 2000
    /// Pages rendered (and held in memory) at once while OCR runs in parallel.
    static let ocrBatch = 4

    public init?(data: Data, fileURL: URL?, title: String) {
        guard let ui = PDFDocument(data: data), let worker = PDFDocument(data: data) else { return nil }
        self.pdf = ui
        self.worker = worker
        self.title = title
        self.fileURL = fileURL
        self.pageCount = worker.pageCount
        self.contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Encryption

    /// True while the PDF is encrypted and not unlocked yet (main thread: reads the UI copy). Unlock it
    /// with `unlock(password:)` before showing it: PDFView's own prompt can't unlock the worker copy.
    public var isLocked: Bool { pdf.isLocked }

    /// Unlocks both copies and drops anything read while the worker copy was locked.
    @MainActor
    public func unlock(password: String) async -> Bool {
        guard pdf.unlock(withPassword: password) else { return false }
        return await onQueue {
            let ok = self.worker.unlock(withPassword: password)
            self.textCache = [:]
            self.sourceCache = [:]
            self.cachedOutline = nil
            self.searchIndex = nil
            return ok
        }
    }

    /// Text, outline and renders are unavailable while the worker copy is locked.
    func isTextLocked() async -> Bool {
        await onQueue { self.worker.isLocked }
    }

    // MARK: Text

    /// 0-based. "" for pages without extractable text or out-of-range indexes. A scanned page (no PDF
    /// text but visible content) returns OCR text, cached in memory and under `AppPaths.cache`.
    public func pageText(_ index: Int) async -> String {
        await onQueue { self.textOnQueue(index) }
    }

    /// Where `pageText(index)` comes from (extracting it first if needed).
    public func pageTextSource(_ index: Int) async -> TextSource {
        await onQueue {
            _ = self.textOnQueue(index)
            return self.sourceCache[index] ?? .none
        }
    }

    /// Whether the page looks like a table (many rows of figures), from its text.
    public func isTableHeavy(_ index: Int) async -> Bool {
        TableDetector.isTableHeavy(await pageText(index))
    }

    /// Texts of every page, extracting whatever is not cached yet.
    func allPageTexts() async -> [String] {
        await onQueue {
            self.extractOnQueue(Array(0..<self.pageCount))
            return (0..<self.pageCount).map { self.textOnQueue($0) }
        }
    }

    /// The page's text exactly as PDFKit returns it (`PDFPage.string`, no normalization, no OCR), so
    /// ranges in it are valid for the UI document's `page.selection(for:)`.
    func rawPageString(_ index: Int) async -> String {
        await onQueue {
            guard index >= 0, index < self.pageCount, let page = self.worker.page(at: index) else { return "" }
            return page.string ?? ""
        }
    }

    private func textOnQueue(_ index: Int) -> String {
        guard index >= 0, index < pageCount else { return "" }
        if textCache[index] == nil { extractOnQueue([index]) }
        return textCache[index] ?? ""
    }

    /// Fills the caches for `indexes`; pages that need OCR are rendered a few at a time here (PDFKit
    /// isn't thread-safe) and recognized in parallel.
    private func extractOnQueue(_ indexes: [Int]) {
        var scanned: [(index: Int, pdfText: String)] = []
        for index in indexes where textCache[index] == nil && index >= 0 && index < pageCount {
            let text = worker.page(at: index).map { Self.normalize($0.string ?? "") } ?? ""
            if Self.nonSpaceCount(text) < Self.ocrTextThreshold, !worker.isLocked {
                if let cached = readOCRCache(index) { store(index, pdfText: text, ocrText: cached) } else { scanned.append((index, text)) }
            } else {
                store(index, pdfText: text, ocrText: nil)
            }
        }
        var start = 0
        while start < scanned.count {
            let batch = Array(scanned[start..<min(start + Self.ocrBatch, scanned.count)])
            start += batch.count
            let images = batch.map { item in worker.page(at: item.index).flatMap { Self.render($0, longEdge: Self.ocrLongEdge) } }
            var results = [String](repeating: "", count: batch.count)
            results.withUnsafeMutableBufferPointer { buffer in
                let out = buffer
                DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                    guard let image = images[i], PageOCR.hasVisibleContent(image) else { return }
                    out[i] = Self.normalize(PageOCR.recognize(image))
                }
            }
            for (i, item) in batch.enumerated() {
                if images[i] != nil { writeOCRCache(item.index, results[i]) }
                store(item.index, pdfText: item.pdfText, ocrText: results[i])
            }
        }
    }

    private func store(_ index: Int, pdfText: String, ocrText: String?) {
        if let ocrText, Self.nonSpaceCount(ocrText) > Self.nonSpaceCount(pdfText) {
            textCache[index] = ocrText
            sourceCache[index] = .ocr
        } else {
            textCache[index] = pdfText
            sourceCache[index] = pdfText.isEmpty ? TextSource.none : .pdfText
        }
    }

    private func ocrCacheURL(_ index: Int) -> URL {
        AppPaths.cache.appendingPathComponent(contentHash, isDirectory: true)
            .appendingPathComponent("ocr", isDirectory: true)
            .appendingPathComponent("v1-page-\(index + 1).txt")
    }

    private func readOCRCache(_ index: Int) -> String? {
        try? String(contentsOf: ocrCacheURL(index), encoding: .utf8)
    }

    private func writeOCRCache(_ index: Int, _ text: String) {
        let url = ocrCacheURL(index)
        AppPaths.ensure(url.deletingLastPathComponent())
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func nonSpaceCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
        // PDF text often carries runs of blank lines from layout gaps; one blank line is enough.
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Outline

    /// Flattened table of contents, depth-first, 0-based pages, at most ~200 entries.
    public func outline() async -> [(title: String, page: Int)] {
        await onQueue {
            if let cached = self.cachedOutline { return cached }
            var out: [(title: String, page: Int)] = []
            if let root = self.worker.outlineRoot { self.flatten(root, into: &out) }
            self.cachedOutline = out
            return out
        }
    }

    private func flatten(_ node: PDFOutline, into out: inout [(title: String, page: Int)]) {
        for i in 0..<node.numberOfChildren {
            guard out.count < Self.outlineLimit, let child = node.child(at: i) else { return }
            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let target = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
            if !label.isEmpty, let target {
                let index = worker.index(for: target)
                if index >= 0, index < pageCount { out.append((title: label, page: index)) }
            }
            flatten(child, into: &out)
        }
    }

    // MARK: Rendering

    /// Renders a page (white background, long edge = `maxLongEdge` px) to
    /// `AppPaths.cache/<contentHash>/page-<1-based>-<edge>.png`, reusing an earlier render.
    public func renderPagePNG(_ index: Int, maxLongEdge: CGFloat = 1600) async -> URL? {
        let edge = max(16, Int(maxLongEdge.rounded()))
        return await onQueue {
            // A locked page renders blank, and the file would be reused after unlocking.
            guard index >= 0, index < self.pageCount, !self.worker.isLocked,
                  let page = self.worker.page(at: index) else { return nil }
            let dir = AppPaths.ensure(AppPaths.cache.appendingPathComponent(self.contentHash, isDirectory: true))
            let url = dir.appendingPathComponent("page-\(index + 1)-\(edge).png")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            guard let image = Self.render(page, longEdge: edge) else { return nil }
            let tmp = dir.appendingPathComponent(".\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            do {
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch {
                // Another window on the same file may have written it first.
                try? FileManager.default.removeItem(at: tmp)
                if !FileManager.default.fileExists(atPath: url.path) { return nil }
            }
            return url
        }
    }

    static func render(_ page: PDFPage, longEdge: Int) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let quarterTurn = (page.rotation / 90) % 2 != 0
        let width = quarterTurn ? box.height : box.width
        let height = quarterTurn ? box.width : box.height
        guard width > 0, height > 0 else { return nil }
        let scale = CGFloat(longEdge) / max(width, height)
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(pixelWidth) / width, y: CGFloat(pixelHeight) / height)
        // Applies the page's rotation and box origin.
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: Search

    /// Pages ranked by keyword relevance (BM25 plus an adjacent-term bonus), best first. Only pages
    /// that match at least one query term are returned.
    public func searchPages(_ query: String, topK: Int) async -> [Int] {
        guard topK > 0 else { return [] }
        return await onQueue {
            if self.searchIndex == nil {
                self.extractOnQueue(Array(0..<self.pageCount))
                let texts = (0..<self.pageCount).map { self.textOnQueue($0) }
                self.searchIndex = PageSearchIndex(pageTexts: texts)
            }
            return self.searchIndex!.search(query, topK: topK)
        }
    }

    // MARK: Queue

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Keyword index over page texts. Built once per document, on the document's queue.
struct PageSearchIndex {
    /// Terms are interned to ints; pages hold term ids.
    private let termIds: [String: Int]
    private let pageTerms: [[Int]]
    private let termCounts: [[Int: Int]]
    private let documentFrequency: [Int]
    private let averageLength: Double

    init(pageTexts: [String]) {
        var ids: [String: Int] = [:]
        var pages: [[Int]] = []
        pages.reserveCapacity(pageTexts.count)
        for text in pageTexts {
            pages.append(Self.tokenize(text).map { term in
                if let id = ids[term] { return id }
                ids[term] = ids.count
                return ids.count - 1
            })
        }
        termIds = ids
        pageTerms = pages
        termCounts = pages.map { terms in terms.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        var df = [Int](repeating: 0, count: ids.count)
        for counts in termCounts { for term in counts.keys { df[term] += 1 } }
        documentFrequency = df
        let total = pages.reduce(0) { $0 + $1.count }
        averageLength = pages.isEmpty ? 1 : max(1, Double(total) / Double(pages.count))
    }

    func search(_ query: String, topK: Int) -> [Int] {
        // Unknown terms match nothing; keep their slots (as nil) so they still break phrase adjacency.
        let queryTerms = Self.tokenize(query).filter { !Self.stopwords.contains($0) }.map { termIds[$0] }
        let terms = Set(queryTerms.compactMap { $0 })
        guard !terms.isEmpty, !pageTerms.isEmpty else { return [] }
        // Adjacent query terms ("asia pacific") as packed (first, second) id pairs.
        var pairs = Set<Int>()
        for (first, second) in zip(queryTerms, queryTerms.dropFirst()) {
            if let first, let second { pairs.insert(first << 32 | second) }
        }
        let n = Double(pageTerms.count)
        let k1 = 1.2, b = 0.75

        var scored: [(page: Int, score: Double)] = []
        for (page, counts) in termCounts.enumerated() {
            let length = Double(pageTerms[page].count)
            var score = 0.0
            for term in terms {
                guard let tf = counts[term].map(Double.init) else { continue }
                let df = Double(documentFrequency[term])
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * length / averageLength))
            }
            guard score > 0 else { continue }
            if !pairs.isEmpty {
                let ids = pageTerms[page]
                var phraseHits = 0
                for i in ids.indices.dropLast() where pairs.contains(ids[i] << 32 | ids[i + 1]) {
                    phraseHits += 1
                }
                score += 0.5 * Double(min(phraseHits, 4))
            }
            scored.append((page, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.page < $1.page }
        return scored.prefix(topK).map(\.page)
    }

    /// Lowercased, diacritic- and ligature-folded words; numbers keep inner "." and "," (61.3, 1,400);
    /// each CJK ideograph is its own token. Single Latin letters are dropped.
    static func tokenize(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = Array(folded.unicodeScalars)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var currentIsSingleLetter = false

        func flush() {
            guard !current.isEmpty else { return }
            if !currentIsSingleLetter { tokens.append(String(current)) }
            current = String.UnicodeScalarView()
        }

        for (i, scalar) in scalars.enumerated() {
            if isWordScalar(scalar) {
                current.append(scalar)
                currentIsSingleLetter = current.count == 1 && !isDigit(scalar)
            } else if scalar.properties.isIdeographic {
                flush()
                tokens.append(String(scalar))
            } else if (scalar == "." || scalar == ","), let last = current.last, isDigit(last),
                      i + 1 < scalars.count, isDigit(scalars[i + 1]) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.isASCII ? ("0"..."9").contains(s) : CharacterSet.decimalDigits.contains(s)
    }

    /// Letters and digits, excluding ideographs (those are tokens of their own).
    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII { return ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) }
        return !s.properties.isIdeographic && CharacterSet.alphanumerics.contains(s)
    }

    static let stopwords: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "as", "at", "be", "been", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "how", "if", "in",
        "into", "is", "it", "its", "me", "more", "most", "my", "no", "not", "of", "on", "or", "other",
        "our", "page", "pages", "say", "says", "should", "so", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "to", "under", "up", "was", "we", "were",
        "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your",
        "tell", "explain", "describe", "document", "paper", "according",
    ]
}
