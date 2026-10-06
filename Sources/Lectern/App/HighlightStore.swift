import AppKit
import LecternCore
import Observation

/// Highlight colors offered in the selection menu and the Highlights sidebar.
enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Fixed pastel colors (not the dynamic system ones): PDFKit draws highlights with a multiply
    /// blend, so these read the same in light and dark mode.
    var color: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.87, blue: 0.30, alpha: 1)
        case .green: return NSColor(srgbRed: 0.62, green: 0.90, blue: 0.48, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.76, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.80, green: 0.66, blue: 1.00, alpha: 1)
        }
    }

    /// A small round swatch for menu items.
    var swatch: NSImage {
        let color = self.color
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).stroke()
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

/// One highlighted passage. The range indexes the page's `PDFPage.string` (UTF-16), which is the same
/// for every PDFDocument made from the same bytes.
struct Highlight: Codable, Identifiable, Equatable {
    let id: UUID
    /// 0-based page index.
    var page: Int
    var location: Int
    var length: Int
    var text: String
    var color: HighlightColor
    var note: String?
    var createdAt: Date

    init(id: UUID = UUID(), page: Int, range: NSRange, text: String, color: HighlightColor,
         note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.page = page
        location = range.location
        length = range.length
        self.text = text
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }

    var range: NSRange { NSRange(location: location, length: length) }
}

/// A document's highlights and notes, saved in Lectern's own storage
/// (`AppPaths.appSupport/highlights/<contentHash>.json`), never in the PDF. Windows showing the same
/// bytes share one store, so they stay in sync and never overwrite each other's file.
@MainActor @Observable
final class HighlightStore {
    let contentHash: String
    /// Page order (then position on the page).
    private(set) var highlights: [Highlight] = []

    @ObservationIgnored private let fileURL: URL
    /// False when the file exists but can't be read (damaged, or from a newer Lectern): it is kept as is.
    @ObservationIgnored private var canSave = true

    nonisolated static var defaultDirectory: URL { AppPaths.appSupport.appendingPathComponent("highlights", isDirectory: true) }

    init(contentHash: String, directory: URL = HighlightStore.defaultDirectory) {
        self.contentHash = contentHash
        fileURL = directory.appendingPathComponent("\(contentHash).json")
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([Highlight].self, from: data) {
                highlights = Self.sorted(decoded)
            } else {
                canSave = false
                NSLog("Lectern: could not read highlights \(fileURL.lastPathComponent); leaving the file alone")
            }
        }
    }

    // MARK: Shared per document

    private final class WeakStore {
        weak var store: HighlightStore?
        init(_ store: HighlightStore) { self.store = store }
    }

    private static var open: [String: WeakStore] = [:]

    /// The store for these bytes, shared by every window showing them.
    static func forDocument(contentHash: String) -> HighlightStore {
        if let store = open[contentHash]?.store { return store }
        open = open.filter { $0.value.store != nil }
        let store = HighlightStore(contentHash: contentHash)
        open[contentHash] = WeakStore(store)
        return store
    }

    // MARK: Changes

    func highlight(_ id: UUID) -> Highlight? {
        highlights.first { $0.id == id }
    }

    func add(_ new: [Highlight]) {
        guard !new.isEmpty else { return }
        highlights = Self.sorted(highlights + new)
        save()
    }

    /// An empty note removes it.
    func setNote(_ note: String?, for id: UUID) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.note = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    func setColor(_ color: HighlightColor, for id: UUID) {
        update(id) { $0.color = color }
    }

    func remove(_ id: UUID) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        highlights.remove(at: index)
        save()
    }

    private func update(_ id: UUID, _ change: (inout Highlight) -> Void) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        var h = highlights[index]
        change(&h)
        guard h != highlights[index] else { return }
        highlights[index] = h
        save()
    }

    private static func sorted(_ list: [Highlight]) -> [Highlight] {
        list.sorted { ($0.page, $0.location, $0.createdAt) < ($1.page, $1.location, $1.createdAt) }
    }

    private func save() {
        guard canSave else { return }
        do {
            AppPaths.ensure(fileURL.deletingLastPathComponent())
            if highlights.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                try JSONEncoder().encode(highlights).write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("Lectern: could not save highlights \(contentHash): \(error)")
        }
    }

    // MARK: Export

    /// Markdown: the title, then each highlight as a quote with its page and, below it, its note.
    static func markdown(_ highlights: [Highlight], title: String) -> String {
        var out = "# \(title)\n"
        for h in highlights {
            let quote = h.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out += "\n> \(quote)\n>\n> \u{2014} p. \(h.page + 1)\n"
            if let note = h.note, !note.isEmpty { out += "\n\(note)\n" }
        }
        return out
    }
}

/// A menu item that runs a closure (context menus built in code).
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// The small "Note" sheet used by Add Note… and Edit Note…. Return saves; Option-Return adds a line.
@MainActor
enum NoteEditor {
    static func edit(_ note: String?, quote: String, in window: NSWindow?, save: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = note == nil ? "Add Note" : "Edit Note"
        let snippet = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        alert.informativeText = "\u{201C}\(snippet.count > 160 ? String(snippet.prefix(160)) + "\u{2026}" : snippet)\u{201D}"
        let field = NSTextField(string: note ?? "")
        field.placeholderString = "Note"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 72)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { save(field.stringValue) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
