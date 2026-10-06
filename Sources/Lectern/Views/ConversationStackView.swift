import AppKit
import LecternCore
import SwiftUI

/// The chat pane: the window's conversations stacked top to bottom in an AppKit split view with
/// draggable dividers, and "New Conversation" below them. A collapsed conversation keeps only its title
/// bar; its views stay alive, so the transcript's web view isn't reloaded. Expanded panels share the
/// height in proportion to their last sizes, which divider drags and window resizing update.
@MainActor
final class ConversationColumnController: NSViewController, NSSplitViewDelegate {
    static let titleBarHeight: CGFloat = 30
    /// Dividers stop here, unless the pane is too short for every expanded panel to get it.
    static let panelMinimumHeight: CGFloat = 200
    static let newConversationBarHeight: CGFloat = 30

    private let stack: ConversationStack
    private let splitView = NSSplitView()
    private var panels: [UUID: NSView] = [:]
    /// The split view's panels, top to bottom, as last synced from the stack.
    private var order: [UUID] = []
    private var collapsed: Set<UUID> = []
    /// Height shares of the expanded panels (their last heights, in points).
    private var weights: [UUID: CGFloat] = [:]
    private var mouseMonitor: Any?

    init(stack: ConversationStack) {
        self.stack = stack
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSHostingView(rootView: NewConversationBar(stack: stack))
        bar.sizingOptions = []
        bar.sceneBridgingOptions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bar.topAnchor),
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
        let point = splitView.convert(event.locationInWindow, from: nil)
        guard splitView.bounds.contains(point) else { return }
        for (id, panel) in zip(order, splitView.subviews) where panel.frame.contains(point) {
            stack.focus(id)
            return
        }
    }

    // MARK: Panels

    /// Follows the stack: conversations added, closed or moved, and panels collapsed or expanded.
    private func observeStack() {
        withObservationTracking {
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
            weights[id] = nil
        }
        let share = typicalWeight()
        for model in models where panels[model.id] == nil {
            let host = NSHostingView(rootView: ConversationPanel(model: model, stack: stack))
            // The split view sizes the panels; SwiftUI bridges nothing into the window.
            host.sizingOptions = []
            host.sceneBridgingOptions = []
            host.clipsToBounds = true
            panels[model.id] = host
            weights[model.id] = share
        }
        order = ids
        collapsed = Set(models.filter(\.isCollapsed).map(\.id))
        let views = ids.compactMap { panels[$0] }
        // Reorders without removing views that stay, so their web views keep their pages.
        if splitView.subviews != views { splitView.subviews = views }
        layoutPanels()
    }

    /// A new panel's share: the expanded panels' average, so it gets about an equal part.
    private func typicalWeight() -> CGFloat {
        let expanded = order.filter { !collapsed.contains($0) }.compactMap { weights[$0] }
        guard !expanded.isEmpty else { return Self.panelMinimumHeight }
        return expanded.reduce(0, +) / CGFloat(expanded.count)
    }

    private func layoutPanels() {
        let views = splitView.subviews
        guard !views.isEmpty, views.count == order.count else { return }
        let size = splitView.bounds.size
        let divider = splitView.dividerThickness
        let heights = Self.panelHeights(collapsed: order.map { collapsed.contains($0) },
                                        weights: order.map { weights[$0] ?? 1 },
                                        available: size.height - divider * CGFloat(views.count - 1),
                                        titleBar: Self.titleBarHeight)
        var y: CGFloat = 0  // NSSplitView is flipped: the first panel is at the top
        for (view, height) in zip(views, heights) {
            view.frame = NSRect(x: 0, y: y, width: size.width, height: height)
            y += height + divider
        }
        splitView.needsDisplay = true
    }

    /// Heights for the panels top to bottom: collapsed ones get the title bar, expanded ones share the
    /// rest in proportion to `weights` (whole points, the remainder to the last). When every panel is
    /// collapsed, the last one takes the leftover space (blank under its title bar).
    static func panelHeights(collapsed: [Bool], weights: [CGFloat], available: CGFloat, titleBar: CGFloat) -> [CGFloat] {
        guard !collapsed.isEmpty else { return [] }
        var heights = collapsed.map { $0 ? titleBar : 0 }
        let expanded = collapsed.indices.filter { !collapsed[$0] }
        let rest = max(0, available - titleBar * CGFloat(collapsed.count - expanded.count))
        guard let last = expanded.last else {
            heights[heights.count - 1] += rest
            return heights
        }
        let total = expanded.reduce(CGFloat(0)) { $0 + max(weights[$1], 1) }
        var used: CGFloat = 0
        for i in expanded where i != last {
            heights[i] = (rest * max(weights[i], 1) / total).rounded(.down)
            used += heights[i]
        }
        heights[last] = max(0, rest - used)
        return heights
    }

    /// Where divider `index` may be dragged: never past a panel's minimum, and not at all next to a
    /// collapsed panel. Nil for an index the split view doesn't have.
    static func dividerRange(index: Int, frames: [NSRect], collapsed: [Bool], minimum: CGFloat) -> ClosedRange<CGFloat>? {
        guard index >= 0, index + 1 < frames.count, index + 1 < collapsed.count else { return nil }
        let above = frames[index], below = frames[index + 1]
        let fixed = above.maxY...above.maxY
        if collapsed[index] || collapsed[index + 1] { return fixed }
        let low = above.minY + minimum
        let high = below.maxY - minimum
        return low <= high ? low...high : fixed
    }

    /// The expanded panels' minimum: `panelMinimumHeight`, or an equal share when the pane is shorter.
    private var minimumExpandedHeight: CGFloat {
        let count = splitView.subviews.count
        let expanded = order.filter { !collapsed.contains($0) }.count
        guard expanded > 0 else { return Self.panelMinimumHeight }
        let room = splitView.bounds.height - splitView.dividerThickness * CGFloat(max(count - 1, 0))
            - Self.titleBarHeight * CGFloat(count - expanded)
        return min(Self.panelMinimumHeight, max(Self.titleBarHeight, (room / CGFloat(expanded)).rounded(.down)))
    }

    private func dividerRange(_ index: Int) -> ClosedRange<CGFloat>? {
        Self.dividerRange(index: index, frames: splitView.subviews.map(\.frame),
                          collapsed: order.map { collapsed.contains($0) }, minimum: minimumExpandedHeight)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanels()
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerRange(dividerIndex)?.lowerBound ?? proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerRange(dividerIndex)?.upperBound ?? proposedMaximumPosition
    }

    /// No resize cursor on a divider that can't move.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        guard let range = dividerRange(dividerIndex), range.lowerBound < range.upperBound else { return .zero }
        return proposedEffectiveRect
    }

    /// A divider drag or a window resize: the expanded panels' new heights are their shares from now on.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        for (id, view) in zip(order, splitView.subviews) where !collapsed.contains(id) && view.frame.height > 0 {
            weights[id] = view.frame.height
        }
    }
}

// MARK: - Panel

/// One conversation: its title bar, then the chat (header, banner, transcript, input), which a
/// collapsed panel keeps alive but hidden.
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

/// Collapse chevron, title (double-click to rename), status, and the conversation menu. The focused
/// conversation's bar is tinted when there are several.
private struct ConversationTitleBar: View {
    let model: ChatModel
    let stack: ConversationStack

    @State private var editing = false
    @State private var draftTitle = ""
    @FocusState private var fieldFocused: Bool

    private var showsFocus: Bool { stack.conversations.count > 1 && stack.focusedID == model.id }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.isCollapsed.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(model.isCollapsed ? 0 : 90))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(model.isCollapsed ? "Expand" : "Collapse")
            .accessibilityLabel(model.isCollapsed ? "Expand conversation" : "Collapse conversation")

            if editing {
                titleField
            } else {
                Text(model.title)
                    .fontWeight(.semibold)
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
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                    .help("Answering…")
            }
            if model.isCollapsed {
                Text(model.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            conversationMenu
        }
        .font(.callout)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: ConversationColumnController.titleBarHeight)
        .background(showsFocus ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
        .overlay(alignment: .bottom) {
            if !model.isCollapsed { Divider() }
        }
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
            Button("Move Up") { stack.moveConversation(model.id, by: -1) }
                .disabled(!stack.canMoveConversation(model.id, by: -1))
            Button("Move Down") { stack.moveConversation(model.id, by: 1) }
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

/// "+ New Conversation" under the stack.
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
                      ? "Another conversation about this document, below the others (\u{2325}\u{2318}N)"
                      : "A document can have up to \(ConversationStack.maxConversations) conversations")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
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
