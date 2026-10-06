import AppKit
import PDFKit
import SwiftUI

/// The reader's left sidebar: page thumbnails, the table of contents, highlights, or search results.
@MainActor
struct ReaderSidebar: View {
    let controller: ReaderController

    var body: some View {
        VStack(spacing: 0) {
            SidebarModePicker(controller: controller)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarMaterial())
    }

    /// The thumbnail strip stays in place (hidden) under the other modes, so it keeps following the
    /// current page and comes back scrolled to it.
    private var content: some View {
        ZStack {
            ThumbnailSidebar(controller: controller, isActive: controller.sidebarMode == .thumbnails)
            switch controller.sidebarMode {
            case .thumbnails:
                EmptyView()
            case .contents:
                OutlineSidebar(controller: controller)
            case .searchResults:
                SearchResultsSidebar(controller: controller)
            case .highlights:
                HighlightsSidebar(controller: controller)
            }
        }
    }
}

/// Thumbnails / Contents (when the PDF has an outline) / Highlights / Search results (while searching).
@MainActor
private struct SidebarModePicker: View {
    let controller: ReaderController

    var body: some View {
        Picker("Sidebar", selection: Binding(
            get: { controller.sidebarMode },
            set: { controller.showSidebar($0) }
        )) {
            Image(systemName: "rectangle.grid.1x2")
                .help("Thumbnails (\u{2325}\u{2318}2)")
                .accessibilityLabel("Thumbnails")
                .tag(ReaderController.SidebarMode.thumbnails)
            if controller.hasOutline {
                Image(systemName: "list.bullet.indent")
                    .help("Table of Contents (\u{2325}\u{2318}3)")
                    .accessibilityLabel("Table of Contents")
                    .tag(ReaderController.SidebarMode.contents)
            }
            Image(systemName: "highlighter")
                .help("Highlights (\u{2325}\u{2318}4)")
                .accessibilityLabel("Highlights")
                .tag(ReaderController.SidebarMode.highlights)
            if controller.isSearching {
                Image(systemName: "magnifyingglass")
                    .help("Search Results")
                    .accessibilityLabel("Search Results")
                    .tag(ReaderController.SidebarMode.searchResults)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Thumbnails

/// PDFKit's thumbnail strip, bound to the reader's PDFView: it highlights the current page, follows
/// it, navigates on click and renders thumbnails lazily.
@MainActor
private struct ThumbnailSidebar: NSViewRepresentable {
    let controller: ReaderController
    let isActive: Bool

    func makeNSView(context: Context) -> ThumbnailContainer {
        let container = ThumbnailContainer()
        container.host(controller.thumbnailView)
        container.isHidden = !isActive
        return container
    }

    func updateNSView(_ container: ThumbnailContainer, context: Context) {
        if controller.thumbnailView.superview !== container { container.host(controller.thumbnailView) }
        if container.isHidden == isActive { container.isHidden = !isActive }
    }
}

/// Sizes the thumbnails to one column of the sidebar's width.
final class ThumbnailContainer: NSView {
    private weak var thumbnails: PDFThumbnailView?

    func host(_ view: PDFThumbnailView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        thumbnails = view
        updateThumbnailSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateThumbnailSize()
    }

    private func updateThumbnailSize() {
        guard let thumbnails, bounds.width > 0 else { return }
        // Leave room for the scroller and the selection ring; one column at any sidebar width.
        let width = max(60, min(260, (bounds.width - 44).rounded()))
        let size = CGSize(width: width, height: (width * 1.3).rounded())
        if thumbnails.thumbnailSize != size { thumbnails.thumbnailSize = size }
    }
}

// MARK: Table of contents

@MainActor
private struct OutlineSidebar: View {
    let controller: ReaderController

    var body: some View {
        let roots = controller.outlineRoots
        if roots.isEmpty {
            ContentUnavailableView("No Table of Contents", systemImage: "list.bullet.indent")
        } else {
            List {
                OutlineGroup(roots, children: \.children) { node in
                    OutlineRow(node: node,
                               pageLabel: node.pageIndex.map(controller.pageLabel(for:)),
                               isCurrent: node.id == controller.currentOutlineID,
                               isOnPath: controller.currentOutlinePath.contains(node.id)) {
                        controller.go(to: node)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Table of Contents")
        }
    }
}

@MainActor
private struct OutlineRow: View {
    let node: OutlineNode
    let pageLabel: String?
    /// The entry the reader is in; `isOnPath` also marks the entries containing it.
    let isCurrent: Bool
    let isOnPath: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(node.title)
                    .lineLimit(2)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let pageLabel {
                    Text(pageLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .fontWeight(isOnPath ? .semibold : .regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(node.pageIndex == nil)
        .help(node.title)
    }
}

// MARK: Highlights

/// The document's highlights in page order; click → go to it. Row menu: note, color, delete.
@MainActor
private struct HighlightsSidebar: View {
    let controller: ReaderController

    var body: some View {
        let highlights = controller.highlights
        if highlights.isEmpty {
            ContentUnavailableView("No Highlights", systemImage: "highlighter",
                                   description: Text("Select text in the PDF and choose Highlight from its context menu."))
        } else {
            List(highlights) { h in
                HighlightRow(highlight: h, pageLabel: controller.pageLabel(for: h.page)) {
                    controller.showHighlight(h.id)
                }
                .contextMenu {
                    Button(h.note == nil ? "Add Note\u{2026}" : "Edit Note\u{2026}") { controller.editNote(h.id) }
                    Menu("Change Color") {
                        ForEach(HighlightColor.allCases) { color in
                            Toggle(isOn: Binding(get: { h.color == color },
                                                 set: { _ in controller.setHighlightColor(color, for: h.id) })) {
                                Label { Text(color.title) } icon: { Image(nsImage: color.swatch) }
                            }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { controller.deleteHighlight(h.id) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Highlights")
        }
    }
}

@MainActor
private struct HighlightRow: View {
    let highlight: Highlight
    let pageLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(Color(nsColor: highlight.color.color))
                    .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("p. \(pageLabel)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(highlight.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        .lineLimit(3)
                    if let note = highlight.note {
                        Text(note)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(pageLabel): \(highlight.text)\(highlight.note.map { ". Note: \($0)" } ?? "")")
    }
}

// MARK: Search results

@MainActor
private struct SearchResultsSidebar: View {
    let controller: ReaderController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.matches.isEmpty {
                VStack {
                    Spacer()
                    if controller.searchStatus == .searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("searchNoResults")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                SearchResultsTable(controller: controller,
                                   searchID: controller.searchID,
                                   count: controller.matches.count,
                                   current: controller.currentMatchIndex)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("searchSummary")
            Spacer(minLength: 0)
            if controller.searchStatus == .searching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var summary: String {
        let n = controller.matches.count
        switch controller.searchStatus {
        case .searching where n == 0: return "Searching\u{2026}"
        case .finished where n == 0: return "No results"
        default:
            let count = controller.matchesTruncated ? "\(n)+" : "\(n)"
            return n == 1 && !controller.matchesTruncated ? "1 result" : "\(count) results"
        }
    }
}

/// The results list, in AppKit: SwiftUI's List re-diffed every row each time results arrived (every
/// 100 ms), which is quadratic and froze the window on searches with thousands of hits. The table
/// appends rows, builds cells (and their snippets) only for visible rows, and keeps the current match
/// selected and in view. Clicking a row (or arrowing through the list) goes to that match.
@MainActor
private struct SearchResultsTable: NSViewRepresentable {
    let controller: ReaderController
    let searchID: Int
    let count: Int
    let current: Int?

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = SearchResultCell.height
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("Search results")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.sync(searchID: searchID, count: count, current: current)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(searchID: searchID, count: count, current: current)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let controller: ReaderController
        weak var table: NSTableView?
        private var shownSearchID = -1
        private var shownCount = 0
        private var shownCurrent: Int?
        private var syncing = false

        init(controller: ReaderController) {
            self.controller = controller
        }

        func sync(searchID: Int, count: Int, current: Int?) {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if searchID != shownSearchID || count < shownCount {
                shownSearchID = searchID
                shownCount = count
                shownCurrent = nil
                table.reloadData()
            } else if count > shownCount {
                let added = IndexSet(integersIn: shownCount..<count)
                shownCount = count
                table.insertRows(at: added, withAnimation: [])
            }
            guard current != shownCurrent else { return }
            shownCurrent = current
            if let current, current < shownCount {
                table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
                table.scrollRowToVisible(current)
            } else {
                table.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shownCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: SearchResultCell.identifier, owner: nil) as? SearchResultCell
                ?? SearchResultCell()
            let matches = controller.matches
            guard matches.indices.contains(row) else { return cell }
            let match = matches[row]
            cell.show(page: "p. \(controller.pageLabel(for: match.pageIndex))", snippet: controller.snippet(for: match))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table, table.selectedRow >= 0 else { return }
            let row = table.selectedRow
            shownCurrent = row
            if row != controller.currentMatchIndex { controller.selectMatch(row) }
        }
    }
}

/// "p. 12" over the match in context, the match in bold.
private final class SearchResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("searchResult")
    static let height: CGFloat = 66
    private static let snippetFont = NSFont.systemFont(ofSize: 12)
    private static let hitFont = NSFont.boldSystemFont(ofSize: 12)

    private let pageLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: Self.height))
        identifier = Self.identifier
        pageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.font = Self.snippetFont
        snippetLabel.textColor = .labelColor
        snippetLabel.maximumNumberOfLines = 3
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.cell?.truncatesLastVisibleLine = true
        snippetLabel.isSelectable = false
        addSubview(pageLabel)
        addSubview(snippetLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        let width = max(0, bounds.width - 2 * inset)
        let pageHeight: CGFloat = 15
        // Flipped or not, the page line goes on top.
        let top = isFlipped ? 3 : bounds.height - 3 - pageHeight
        pageLabel.frame = NSRect(x: inset, y: top, width: width, height: pageHeight)
        let snippetHeight = bounds.height - pageHeight - 6
        snippetLabel.frame = NSRect(x: inset, y: isFlipped ? 3 + pageHeight : 3, width: width, height: snippetHeight)
    }

    func show(page: String, snippet: ReaderController.SearchSnippet) {
        pageLabel.stringValue = page
        let text = NSMutableAttributedString(string: snippet.head, attributes: [.font: Self.snippetFont])
        text.append(NSAttributedString(string: snippet.hit, attributes: [.font: Self.hitFont]))
        text.append(NSAttributedString(string: snippet.tail, attributes: [.font: Self.snippetFont]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        snippetLabel.attributedStringValue = text
        setAccessibilityLabel("\(page): \(snippet.head)\(snippet.hit)\(snippet.tail)")
    }
}

// MARK: Material

/// The translucent sidebar background used by Finder, Preview and Mail.
@MainActor
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
