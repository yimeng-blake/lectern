import AppKit
import LecternCore
import SwiftUI

/// The chat pane: the window's conversations in a grid (`ConversationStack.gridRows`) of nested AppKit
/// split views, with draggable dividers, and "New Conversation" below. The rows are stacked top to
/// bottom; each row is split into its one or two panels. Panels move between rows, and into a holder
/// (hidden) while one conversation is shown alone, without being rebuilt or leaving the window, so their
/// transcripts keep their pages. Row heights and each two-column row's split are kept as proportions,
/// which divider drags update; a row that gains a second column lines it up with the other row. Only a
/// panel alone in its row folds to its title bar.
@MainActor
final class ConversationColumnController: NSViewController, NSSplitViewDelegate {
    static let titleBarHeight: CGFloat = 32
    /// Dividers stop here, unless the pane is too small for every panel to get it.
    static let panelMinimumHeight: CGFloat = 200
    static let panelMinimumWidth: CGFloat = 300
    static let newConversationBarHeight: CGFloat = 30

    private let stack: ConversationStack
    /// The rows, top to bottom.
    private let rowsView = NSSplitView()
    /// Row split views by index, reused as the grid changes.
    private var rowViews: [NSSplitView] = []
    /// Holds the panels that aren't shown, hidden themselves (a hidden holder would leave a transcript
    /// blank after it moved out: WebKit only notices visibility changes from the panel's own hiding).
    private let holder = NSView()
    private var panels: [UUID: PanelContainer] = [:]
    /// The grid as last synced: conversation ids by row.
    private var rows: [[UUID]] = []
    private var foldedRows: [Bool] = []
    /// One conversation is shown alone; the grid's proportions wait for its return.
    private var showsOneAlone = false
    /// The grid's row height shares (their last heights, in points) and the first column's share of
    /// each two-column row's width.
    private var rowWeights: [CGFloat] = []
    private var columnShares: [CGFloat?] = []
    private var mouseMonitor: Any?

    init(stack: ConversationStack) {
        self.stack = stack
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        holder.clipsToBounds = true
        rowsView.isVertical = false
        rowsView.dividerStyle = .thin
        rowsView.delegate = self
        rowsView.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSHostingView(rootView: NewConversationBar(stack: stack))
        bar.sizingOptions = []
        bar.sceneBridgingOptions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(holder)
        root.addSubview(rowsView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            rowsView.topAnchor.constraint(equalTo: root.topAnchor),
            rowsView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rowsView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rowsView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.newConversationBarHeight),
        ])
        view = root
        syncPanels()
        observeStack()
    }

    /// Clicks anywhere in a panel (transcript, header, menus) give it the focus.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPanel(under: event) }
            return event
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func focusPanel(under event: NSEvent) {
        guard let window = view.window, event.window === window else { return }
        for (id, panel) in panels where panel.superview?.superview === rowsView {
            if panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) {
                stack.focus(id)
                return
            }
        }
    }

    // MARK: Panels

    /// Follows the stack: conversations added, closed or moved, one shown alone, the focus, and panels
    /// folded or opened.
    private func observeStack() {
        withObservationTracking {
            _ = stack.maximizedID
            _ = stack.focusedID
            for model in stack.conversations { _ = model.isCollapsed }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncPanels()
                self.observeStack()
            }
        }
    }

    private func syncPanels() {
        let models = stack.conversations
        let ids = models.map(\.id)
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.removeFromSuperview()
        }
        for model in models where panels[model.id] == nil {
            panels[model.id] = PanelContainer(model: model, stack: stack)
        }
        let alone = stack.maximizedID.flatMap { id in ids.contains(id) ? id : nil }
        let grid = alone.map { [[$0]] } ?? ConversationStack.gridRows(count: ids.count).map { $0.map { ids[$0] } }
        showsOneAlone = alone != nil
        if !showsOneAlone { keepProportions(for: grid) }
        place(grid)
        rows = grid
        foldedRows = grid.map { row in
            row.count == 1 && !showsOneAlone && models.first { $0.id == row[0] }?.isCollapsed == true
        }
        for model in models {
            panels[model.id]?.showsFocus = ids.count > 1 && !showsOneAlone && stack.focusedID == model.id
        }
        layoutRows()
    }

    /// Rows that stay keep their height share and a new row gets the average; a row that gains a second
    /// column lines it up with the other row (else splits in half).
    private func keepProportions(for grid: [[UUID]]) {
        let typical = rowWeights.isEmpty ? Self.panelMinimumHeight : rowWeights.reduce(0, +) / CGFloat(rowWeights.count)
        rowWeights = grid.indices.map { $0 < rowWeights.count ? rowWeights[$0] : typical }
        let old = columnShares
        columnShares = grid.indices.map { i in
            guard grid[i].count == 2 else { return nil }
            if i < old.count, let share = old[i] { return share }
            return old.compactMap { $0 }.first ?? 0.5
        }
    }

    /// Puts each panel at its row and column. A panel that moves waits in the holder first, so none
    /// leaves the window (a web view would lose its rendering, a field its keyboard focus); the ones not
    /// shown stay there, hidden.
    private func place(_ grid: [[UUID]]) {
        let window = view.window
        let responder = window?.firstResponder
        while rowViews.count < grid.count {
            let row = NSSplitView()
            row.isVertical = true
            row.dividerStyle = .thin
            row.delegate = self
            rowViews.append(row)
        }
        let shownRows = Array(rowViews.prefix(grid.count))
        for (id, panel) in panels {
            let target = grid.firstIndex { $0.contains(id) }.map { r in (row: shownRows[r], column: grid[r].firstIndex(of: id)!) }
            let inPlace = target.map { panel.superview === $0.row && $0.row.superview === rowsView
                && $0.row.subviews.firstIndex(of: panel) == $0.column } ?? false
            if !inPlace, panel.superview !== holder { holder.addSubview(panel) }
        }
        if rowsView.subviews != shownRows { rowsView.subviews = shownRows }
        for (row, ids) in zip(shownRows, grid) {
            let views = ids.compactMap { panels[$0] }
            if row.subviews != views { row.subviews = views }
        }
        for (id, panel) in panels {
            let shown = grid.contains { $0.contains(id) }
            if panel.isHidden == shown { panel.isHidden = !shown }
        }
        // A field or transcript that had the keyboard focus keeps it after its panel moved.
        if let window, let responder = responder as? NSView, window.firstResponder !== responder,
           responder.window === window, !responder.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(responder)
        }
    }

    private func rowHeights() -> [CGFloat] {
        let count = rowsView.subviews.count
        return Self.panelHeights(collapsed: foldedRows, weights: showsOneAlone ? [1] : rowWeights,
                                 available: rowsView.bounds.height - rowsView.dividerThickness * CGFloat(max(count - 1, 0)),
                                 titleBar: Self.titleBarHeight)
    }

    private func columnWidths(_ index: Int) -> [CGFloat] {
        let row = rowViews[index]
        let count = row.subviews.count
        let share = showsOneAlone ? nil : columnShares[safe: index].flatMap { $0 }
        return Self.columnWidths(count: count, share: share ?? 0.5,
                                 available: row.bounds.width - row.dividerThickness * CGFloat(max(count - 1, 0)))
    }

    private func layoutRows() {
        let views = rowsView.subviews
        guard !views.isEmpty, views.count == rows.count else { return }
        let width = rowsView.bounds.width
        let divider = rowsView.dividerThickness
        var y: CGFloat = 0  // NSSplitView is flipped: the first row is at the top
        for (view, height) in zip(views, rowHeights()) {
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + divider
        }
        rowsView.needsDisplay = true
        for index in views.indices { layoutColumns(index) }
    }

    private func layoutColumns(_ index: Int) {
        guard index < rows.count, index < rowViews.count else { return }
        let row = rowViews[index]
        let views = row.subviews
        guard !views.isEmpty else { return }
        let height = row.bounds.height
        var x: CGFloat = 0
        for (view, width) in zip(views, columnWidths(index)) {
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + row.dividerThickness
        }
        row.needsDisplay = true
    }

    /// Heights for the rows top to bottom: folded ones get the title bar, the others share the rest in
    /// proportion to `weights` (whole points, the remainder to the last). When every row is folded,
    /// the last one takes the leftover space (blank under its title bar).
    static func panelHeights(collapsed: [Bool], weights: [CGFloat], available: CGFloat, titleBar: CGFloat) -> [CGFloat] {
        guard !collapsed.isEmpty else { return [] }
        var heights = collapsed.map { $0 ? titleBar : 0 }
        let expanded = collapsed.indices.filter { !collapsed[$0] }
        let rest = max(0, available - titleBar * CGFloat(collapsed.count - expanded.count))
        guard let last = expanded.last else {
            heights[heights.count - 1] += rest
            return heights
        }
        let weight = { (i: Int) in max(weights[safe: i] ?? 1, 1) }
        let total = expanded.reduce(CGFloat(0)) { $0 + weight($1) }
        var used: CGFloat = 0
        for i in expanded where i != last {
            heights[i] = (rest * weight(i) / total).rounded()
            used += heights[i]
        }
        heights[last] = max(0, rest - used)
        return heights
    }

    /// Widths for a row's one or two panels: the first gets `share` of the room (whole points).
    static func columnWidths(count: Int, share: CGFloat, available: CGFloat) -> [CGFloat] {
        let room = max(0, available)
        guard count == 2 else { return count == 1 ? [room] : [] }
        let first = (room * min(max(share, 0), 1)).rounded()
        return [first, room - first]
    }

    /// Where divider `index` may be dragged, along the split's axis (`spans` are the panes' extents):
    /// never past a pane's minimum, and not at all next to a folded one. Nil for an index the split
    /// view doesn't have.
    static func dividerRange(index: Int, spans: [ClosedRange<CGFloat>], fixed: [Bool], minimum: CGFloat) -> ClosedRange<CGFloat>? {
        guard index >= 0, index + 1 < spans.count else { return nil }
        let before = spans[index], after = spans[index + 1]
        let stay = before.upperBound...before.upperBound
        if fixed[safe: index] == true || fixed[safe: index + 1] == true { return stay }
        let low = before.lowerBound + minimum
        let high = after.upperBound - minimum
        return low <= high ? low...high : stay
    }

    /// The panels' minimum along a split: `preferred`, or an equal share when the pane is smaller.
    private static func minimum(_ preferred: CGFloat, room: CGFloat, panes: Int) -> CGFloat {
        guard panes > 0 else { return preferred }
        return min(preferred, max(titleBarHeight, (room / CGFloat(panes)).rounded(.down)))
    }

    private func dividerRange(_ splitView: NSSplitView, _ index: Int) -> ClosedRange<CGFloat>? {
        let frames = splitView.subviews.map(\.frame)
        let count = frames.count
        if splitView === rowsView {
            let open = foldedRows.filter { !$0 }.count
            let room = splitView.bounds.height - splitView.dividerThickness * CGFloat(max(count - 1, 0))
                - Self.titleBarHeight * CGFloat(count - open)
            return Self.dividerRange(index: index, spans: frames.map { $0.minY...$0.maxY }, fixed: foldedRows,
                                     minimum: Self.minimum(Self.panelMinimumHeight, room: room, panes: open))
        }
        let room = splitView.bounds.width - splitView.dividerThickness * CGFloat(max(count - 1, 0))
        return Self.dividerRange(index: index, spans: frames.map { $0.minX...$0.maxX }, fixed: [],
                                 minimum: Self.minimum(Self.panelMinimumWidth, room: room, panes: count))
    }

    // MARK: NSSplitViewDelegate (the rows and each row)

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if splitView === rowsView {
            layoutRows()
        } else if let index = rowViews.firstIndex(where: { $0 === splitView }) {
            layoutColumns(index)
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerRange(splitView, dividerIndex)?.lowerBound ?? proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerRange(splitView, dividerIndex)?.upperBound ?? proposedMaximumPosition
    }

    /// No resize cursor on a divider that can't move.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        guard let range = dividerRange(splitView, dividerIndex), range.lowerBound < range.upperBound else { return .zero }
        return proposedEffectiveRect
    }

    /// A divider drag: the new sizes are the grid's proportions from now on. Sizes the layout itself
    /// gave (window resizing, the grid changing) are left alone, so rounding never drifts them.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !showsOneAlone, let splitView = notification.object as? NSSplitView else { return }
        let moved = { (actual: [CGFloat], laidOut: [CGFloat]) in
            actual.count == laidOut.count && zip(actual, laidOut).contains { abs($0 - $1) >= 1 }
        }
        if splitView === rowsView {
            let heights = splitView.subviews.map(\.frame.height)
            guard moved(heights, rowHeights()) else { return }
            for (i, height) in heights.enumerated() where i < rowWeights.count && foldedRows[safe: i] == false && height > 0 {
                rowWeights[i] = height
            }
        } else if let i = rowViews.firstIndex(where: { $0 === splitView }), columnShares.indices.contains(i),
                  columnShares[i] != nil, splitView.subviews.count == 2 {
            let widths = splitView.subviews.map(\.frame.width)
            let room = widths.reduce(0, +)
            guard moved(widths, columnWidths(i)), room > 0 else { return }
            columnShares[i] = widths[0] / room
        }
    }
}

/// One panel in the grid: the conversation's SwiftUI view, and over it the focused conversation's
/// ring in its color (AppKit, so it draws above the transcript's web view).
@MainActor
private final class PanelContainer: NSView {
    private let ring = PanelFocusRing()

    var showsFocus = false {
        didSet { ring.isHidden = !showsFocus }
    }

    init(model: ChatModel, stack: ConversationStack) {
        super.init(frame: .zero)
        let host = NSHostingView(rootView: ConversationPanel(model: model, stack: stack))
        // The split view sizes the panels; SwiftUI bridges nothing into the window.
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.autoresizingMask = [.width, .height]
        ring.autoresizingMask = [.width, .height]
        ring.color = model.colorTag.nsColor
        ring.isHidden = true
        addSubview(host)
        addSubview(ring)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private final class PanelFocusRing: NSView {
    var color = NSColor.controlAccentColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

extension ConversationTag {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var color: Color { Color(nsColor: nsColor) }
}

// MARK: - Panel

/// One conversation: its title bar, then the chat (header, banner, transcript, input), which a
/// folded panel keeps alive but hidden.
@MainActor
struct ConversationPanel: View {
    let model: ChatModel
    let stack: ConversationStack

    var body: some View {
        VStack(spacing: 0) {
            ConversationTitleBar(model: model, stack: stack)
            ChatPaneView(model: model)
                .frame(maxHeight: model.isCollapsed ? 0 : .infinity)
                .clipped()
                .opacity(model.isCollapsed ? 0 : 1)
                .disabled(model.isCollapsed)
                .accessibilityHidden(model.isCollapsed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Fold chevron (only for a panel alone in its row), the conversation's color dot, title (double-click
/// to rename), status, show-alone button and the conversation menu. A 3 pt line in the conversation's
/// color tops the bar; the focused conversation's bar is tinted more strongly and the others' titles
/// are secondary.
@MainActor
private struct ConversationTitleBar: View {
    let model: ChatModel
    let stack: ConversationStack

    @State private var editing = false
    @State private var draftTitle = ""
    @FocusState private var fieldFocused: Bool

    /// Nothing else is on screen: one conversation, or this one shown alone.
    private var isAlone: Bool { stack.conversations.count < 2 || stack.maximizedID != nil }
    private var showsFocus: Bool { !isAlone && stack.focusedID == model.id }
    private var canFold: Bool { stack.maximizedID == nil && stack.canCollapse(model.id) }

    var body: some View {
        VStack(spacing: 0) {
            model.colorTag.color
                .frame(height: 3)
            HStack(spacing: 6) {
                if canFold { foldButton }
                Circle()
                    .fill(model.colorTag.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                if editing {
                    titleField
                } else {
                    Text(model.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(isAlone || showsFocus ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: beginRename)
                        .help(model.titleIsCustom ? "\(model.title) — double-click to rename"
                                                  : "\(model.title) — named automatically; double-click to rename")
                        .accessibilityLabel("Conversation: \(model.title)")
                        .accessibilityAddTraits(.isHeader)
                }

                if model.isAnyBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                        .help("Answering…")
                }
                if model.isCollapsed {
                    Text(model.provider.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if stack.conversations.count > 1 { maximizeButton }
                conversationMenu
            }
            .font(.body)
            .padding(.leading, canFold ? 6 : 10)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
        }
        .frame(height: ConversationColumnController.titleBarHeight)
        .background(model.colorTag.color.opacity(showsFocus ? 0.16 : 0.06))
        .overlay(alignment: .bottom) {
            if !model.isCollapsed { Divider() }
        }
    }

    private var foldButton: some View {
        Button {
            model.isCollapsed.toggle()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(model.isCollapsed ? 0 : 90))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(model.isCollapsed ? "Expand" : "Collapse")
        .accessibilityLabel(model.isCollapsed ? "Expand conversation" : "Collapse conversation")
    }

    /// ⤢ shows this conversation alone in the chat pane; ⤡ (or Esc in its empty message field) shows all.
    private var maximizeButton: some View {
        Button {
            model.toggleMaximize()
        } label: {
            Image(systemName: model.isMaximized ? "arrow.down.right.and.arrow.up.left"
                                                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(model.isMaximized ? "Show all conversations (or Esc in the empty message field)"
                                : "Show this conversation alone")
        .accessibilityLabel(model.isMaximized ? "Show all conversations" : "Show this conversation alone")
    }

    private var titleField: some View {
        TextField("Title", text: $draftTitle, prompt: Text("Automatic title"))
            .textFieldStyle(.plain)
            .fontWeight(.semibold)
            .focused($fieldFocused)
            .onSubmit(commitRename)
            .onExitCommand { editing = false }
            .onChange(of: fieldFocused) { _, focused in
                if !focused, editing { commitRename() }
            }
            .onAppear {
                DispatchQueue.main.async { fieldFocused = true }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Conversation title")
    }

    private var conversationMenu: some View {
        Menu {
            Button("Rename\u{2026}", action: beginRename)
            Button("New Chat") { ConversationActions.clear(model) }
                .disabled(model.messages.isEmpty || model.isAnyBusy)
            Divider()
            Button("Move Earlier") { stack.moveConversation(model.id, by: -1) }
                .disabled(!stack.canMoveConversation(model.id, by: -1))
            Button("Move Later") { stack.moveConversation(model.id, by: 1) }
                .disabled(!stack.canMoveConversation(model.id, by: 1))
            Divider()
            Button("Close Conversation") { ConversationActions.close(model, in: stack) }
                .disabled(!stack.canCloseConversation)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Conversation")
        .accessibilityLabel("Conversation menu")
    }

    private func beginRename() {
        model.takeFocus()
        draftTitle = model.titleIsCustom ? model.title : ""
        editing = true
    }

    /// Return or clicking away; an empty title goes back to the automatic one.
    private func commitRename() {
        guard editing else { return }
        editing = false
        model.rename(draftTitle)
    }
}

/// "+ New Conversation" under the conversations.
@MainActor
private struct NewConversationBar: View {
    let stack: ConversationStack

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button {
                    stack.addConversation()
                } label: {
                    Label("New Conversation", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!stack.canAddConversation)
                .help(stack.canAddConversation
                      ? "Another conversation about this document, after the others (\u{2325}\u{2318}N)"
                      : "A document can have up to \(ConversationStack.maxConversations) conversations")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .background(Color.primary.opacity(0.035))
    }
}

// MARK: - Confirmations

/// Closing a conversation and New Chat remove its messages, so they ask first when it has any.
@MainActor
enum ConversationActions {
    static func close(_ model: ChatModel, in stack: ConversationStack) {
        guard stack.canCloseConversation else { return }
        let id = model.id
        guard model.hasUserMessages else {
            stack.closeConversation(id)
            return
        }
        confirm(title: "Close \u{201C}\(model.title)\u{201D}?",
                message: "Its messages will be removed. The other conversations stay.",
                action: "Close Conversation") { [weak stack] in
            stack?.closeConversation(id)
        }
    }

    static func clear(_ model: ChatModel) {
        guard !model.isAnyBusy else { return }
        guard model.hasUserMessages else {
            model.clearConversation()
            return
        }
        confirm(title: "Start a new chat in \u{201C}\(model.title)\u{201D}?",
                message: "Its messages will be removed, and Claude and ChatGPT start over without them.",
                action: "New Chat") { [weak model] in
            model?.clearConversation()
        }
    }

    private static func confirm(title: String, message: String, action: String, perform: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated { perform() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            perform()
        }
    }
}
