import AppKit
import LecternCore
import Observation
import SwiftUI

/// Root of a reader window (hosted by ReaderWindowController, which owns the window and its title).
/// The document and its ConversationStack are created once, on first appearance, because SwiftUI may
/// re-run a view's init many times. The window shuts the conversations down when it closes.
@MainActor
struct DocumentWindow: View {
    /// The file's bytes, read once (read-only) by ReaderWindowManager.
    let data: Data
    let fileURL: URL
    /// The window's viewer controller (owned by ReaderWindowController, which attaches the document).
    let reader: ReaderController
    /// Receives the conversations as soon as they exist, so the window can shut them down on close.
    let onConversationsReady: @MainActor (ConversationStack) -> Void

    @State private var stack: ConversationStack?
    @State private var loadFailed = false
    /// An encrypted PDF waiting for its password.
    @State private var locked: ReaderDocument?
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        if let stack {
            DocumentSplitView(stack: stack, reader: reader)
        } else if let locked {
            unlockView(locked)
        } else if loadFailed {
            ContentUnavailableView {
                Label("Can't open \u{201C}\(fileURL.lastPathComponent)\u{201D}", systemImage: "doc.questionmark")
            } description: {
                Text("The file isn't a readable PDF. It may be damaged or password-protected.")
            }
            // Unbounded max size: a bounded one makes the hosting view shrink the window to fit.
            .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear(perform: load)
        }
    }

    private func load() {
        guard stack == nil, !loadFailed else { return }
        guard let document = ReaderDocument(data: data, fileURL: fileURL, title: Self.title(for: fileURL)) else {
            loadFailed = true
            return
        }
        // Lectern asks for the password itself: PDFView's own prompt would unlock only the UI copy, and
        // the model would get empty pages.
        if document.isLocked {
            locked = document
            return
        }
        makeConversations(document)
    }

    private func makeConversations(_ document: ReaderDocument) {
        let created = ConversationStack(document: document, services: AppServices.shared)
        // The PDF's context menu and Edit > Ask Lectern send the selection to the focused conversation.
        reader.onAsk = { [weak created] action, text, pages in
            created?.ask(action, selection: text, pages: pages)
        }
        stack = created
        onConversationsReady(created)
    }

    private func unlockView(_ document: ReaderDocument) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\u{201C}\(document.title)\u{201D} is password-protected.")
                .font(.headline)
            SecureField("Password", text: $password)
                .frame(width: 240)
                .onSubmit(unlock)
            if wrongPassword {
                Text("That password didn't open it.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .padding()
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }

    private func unlock() {
        guard let document = locked, !password.isEmpty else { return }
        let attempt = password
        Task {
            guard await document.unlock(password: attempt) else {
                wrongPassword = true
                return
            }
            password = ""
            locked = nil
            makeConversations(document)
        }
    }

    /// The document's name for the model (the window title keeps the extension).
    static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Sidebar | PDF | conversations. The toolbar is the window's own (ReaderToolbar).
@MainActor
private struct DocumentSplitView: View {
    let stack: ConversationStack
    let reader: ReaderController

    var body: some View {
        ReaderSplitView(stack: stack, reader: reader)
            // The window's minimum: every pane at its minimum width (ReaderSplitViewController).
            .frame(minWidth: ReaderSplitViewController.minimumWidth, maxWidth: .infinity,
                   minHeight: 360, maxHeight: .infinity)
    }
}

@MainActor
private struct ReaderSplitView: NSViewControllerRepresentable {
    let stack: ConversationStack
    let reader: ReaderController

    func makeNSViewController(context: Context) -> ReaderSplitViewController {
        ReaderSplitViewController(stack: stack, reader: reader)
    }

    func updateNSViewController(_ controller: ReaderSplitViewController, context: Context) {}
}

/// The PDF pane's SwiftUI side: PDFReaderView with the conversations' shared bindings.
@MainActor
private struct PDFPane: View {
    @Bindable var stack: ConversationStack
    let reader: ReaderController

    var body: some View {
        PDFReaderView(document: stack.document,
                      controller: reader,
                      readingState: $stack.readingState,
                      passageRequest: $stack.passageRequest)
    }
}

/// An AppKit split view rather than SwiftUI's HSplitView, which can't set where its dividers start
/// (the sidebar opened at 140 or 261 pt instead of 180) and rebuilt a hidden pane (the chat's web view
/// reloaded every time it was shown). Here hiding collapses a pane and keeps its views; the PDF pane
/// takes up window resizing; dragging a divider closed hides the sidebar or chat like the menu does.
/// The chat pane is the window's conversations in a grid (ConversationColumnController). When the grid
/// needs two columns (3–4 conversations), the chat pane widens to fit them, taking the room from the
/// PDF (never below its minimum; the window keeps its size); with one column again, the previous width
/// comes back unless the divider was moved meanwhile.
@MainActor
final class ReaderSplitViewController: NSSplitViewController {
    static let sidebarRange: ClosedRange<CGFloat> = 140...320
    static let pdfMinimumWidth: CGFloat = 260
    static let chatMinimumWidth: CGFloat = 340
    static let chatDefaultWidth: CGFloat = 440
    /// Two conversations side by side, 340 pt each, and the divider between them.
    static let chatTwoColumnWidth: CGFloat = 2 * 340 + 1
    static var minimumWidth: CGFloat { sidebarRange.lowerBound + pdfMinimumWidth + chatMinimumWidth + 2 }

    private let reader: ReaderController
    private let stack: ConversationStack
    private let sidebarItem: NSSplitViewItem
    private let pdfItem: NSSplitViewItem
    private let chatItem: NSSplitViewItem
    private var placedDividers = false
    private var syncing = false
    /// The column count the chat width last followed (`fitChatToColumns`).
    private var fittedTwoColumns = false
    /// The chat width before it widened for two columns, and the width it widened to.
    private var widenedFrom: CGFloat?
    private var widenedTo: CGFloat = 0
    private var chatAnimating = false
    private var resizingChat = false

    init(stack: ConversationStack, reader: ReaderController) {
        self.reader = reader
        self.stack = stack
        let sidebar = NSHostingController(rootView: ReaderSidebar(controller: reader))
        let pdf = NSHostingController(rootView: PDFPane(stack: stack, reader: reader))
        let chat = ConversationColumnController(stack: stack)
        Self.configure(sidebar)
        Self.configure(pdf)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarRange.lowerBound
        sidebarItem.maximumThickness = Self.sidebarRange.upperBound
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        pdfItem = NSSplitViewItem(viewController: pdf)
        pdfItem.minimumThickness = Self.pdfMinimumWidth
        pdfItem.holdingPriority = NSLayoutConstraint.Priority(250)

        chatItem = NSSplitViewItem(viewController: chat)
        chatItem.minimumThickness = Self.chatMinimumWidth
        chatItem.canCollapse = true
        chatItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        chatItem.holdingPriority = NSLayoutConstraint.Priority(255)

        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(pdfItem)
        addSplitViewItem(chatItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The split items hold the size limits, so the panes' hosting controllers size nothing; they
    /// bridge nothing into the window either (it owns its title and toolbar).
    private static func configure<Content: View>(_ hosting: NSHostingController<Content>) {
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placedDividers, splitView.bounds.width >= Self.minimumWidth else { return }
        placedDividers = true
        // Default widths, then the reader's saved visibility (no animation), then follow it.
        let divider = splitView.dividerThickness
        let width = splitView.bounds.width
        let sidebarWidth = ReaderController.sidebarDefaultWidth
        let chatWidth = min(Self.chatDefaultWidth,
                            max(Self.chatMinimumWidth, width - sidebarWidth - Self.pdfMinimumWidth - 2 * divider))
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        splitView.setPosition(width - chatWidth - divider, ofDividerAt: 1)
        apply(animated: false)
        fitChatToColumns()
        observeReader()
        observeColumns()
    }

    /// Mirrors the reader's sidebar and chat visibility (menus, toolbar, restored state).
    private func observeReader() {
        withObservationTracking {
            _ = reader.sidebarVisible
            _ = reader.chatVisible
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(animated: self.view.window != nil)
                self.observeReader()
            }
        }
    }

    private func apply(animated: Bool) {
        syncing = true
        defer { syncing = false }
        for (item, visible) in [(sidebarItem, reader.sidebarVisible), (chatItem, reader.chatVisible)]
        where item.isCollapsed == visible {
            if animated {
                let isChat = item === chatItem
                if isChat { chatAnimating = true }
                NSAnimationContext.runAnimationGroup { _ in
                    item.animator().isCollapsed = !visible
                } completionHandler: { [weak self] in
                    guard isChat else { return }
                    MainActor.assumeIsolated {
                        self?.chatAnimating = false
                        self?.fitChatToColumns()
                    }
                }
            } else {
                item.isCollapsed = !visible
            }
        }
    }

    /// Conversations added or closed across the one/two-column line.
    private func observeColumns() {
        withObservationTracking {
            _ = stack.usesTwoColumns
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.fitChatToColumns()
                self?.observeColumns()
            }
        }
    }

    /// Widens the chat pane for two columns (from the PDF's spare width), or gives back the earlier width
    /// once one column is left, if the chat still has the width it was given. A hidden chat waits until
    /// it is shown.
    private func fitChatToColumns() {
        guard placedDividers, !chatItem.isCollapsed, !chatAnimating else { return }
        let twoColumns = stack.usesTwoColumns
        guard twoColumns != fittedTwoColumns else { return }
        fittedTwoColumns = twoColumns
        let width = chatItem.viewController.view.frame.width
        if twoColumns {
            let spare = max(0, pdfItem.viewController.view.frame.width - Self.pdfMinimumWidth)
            let target = min(Self.chatTwoColumnWidth, width + spare)
            guard target >= width + 1 else { return }
            setChatWidth(target)
            widenedFrom = width
            widenedTo = chatItem.viewController.view.frame.width
        } else if let from = widenedFrom {
            widenedFrom = nil
            if abs(width - widenedTo) < 1 { setChatWidth(from) }
        }
    }

    private func setChatWidth(_ width: CGFloat) {
        resizingChat = true
        defer { resizingChat = false }
        splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: 1)
    }

    /// A divider dragged until its pane collapsed (or back open) updates the reader's state. A chat
    /// width changed by hand after widening is kept when the second column goes.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard placedDividers, !syncing else { return }
        if sidebarItem.isCollapsed == reader.sidebarVisible { reader.setSidebarVisible(!sidebarItem.isCollapsed) }
        if chatItem.isCollapsed == reader.chatVisible { reader.setChatVisible(!chatItem.isCollapsed) }
        if widenedFrom != nil, !resizingChat, !chatAnimating, !chatItem.isCollapsed,
           abs(chatItem.viewController.view.frame.width - widenedTo) >= 1 {
            widenedFrom = nil
        }
    }
}

