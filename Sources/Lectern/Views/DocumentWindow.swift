import AppKit
import LecternCore
import Observation
import SwiftUI

/// Root of a reader window (hosted by ReaderWindowController, which owns the window and its title).
/// The document and its ChatModel are created once, on first appearance, because SwiftUI may re-run a
/// view's init many times. The window shuts the model down when it closes.
struct DocumentWindow: View {
    /// The file's bytes, read once (read-only) by ReaderWindowManager.
    let data: Data
    let fileURL: URL
    /// The window's viewer controller (owned by ReaderWindowController, which attaches the document).
    let reader: ReaderController
    /// Receives the ChatModel as soon as it exists, so the window can shut it down on close.
    let onModelReady: @MainActor (ChatModel) -> Void

    @State private var model: ChatModel?
    @State private var loadFailed = false
    /// An encrypted PDF waiting for its password.
    @State private var locked: ReaderDocument?
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        if let model {
            DocumentSplitView(model: model, reader: reader)
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
        guard model == nil, !loadFailed else { return }
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
        makeModel(document)
    }

    private func makeModel(_ document: ReaderDocument) {
        let created = ChatModel(document: document, services: AppServices.shared)
        model = created
        onModelReady(created)
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
            makeModel(document)
        }
    }

    /// The document's name for the model (the window title keeps the extension).
    static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Sidebar | PDF | chat. The toolbar is the window's own (ReaderToolbar).
private struct DocumentSplitView: View {
    let model: ChatModel
    let reader: ReaderController

    var body: some View {
        ReaderSplitView(model: model, reader: reader)
            // The window's minimum: every pane at its minimum width (ReaderSplitViewController).
            .frame(minWidth: ReaderSplitViewController.minimumWidth, maxWidth: .infinity,
                   minHeight: 360, maxHeight: .infinity)
    }
}

private struct ReaderSplitView: NSViewControllerRepresentable {
    let model: ChatModel
    let reader: ReaderController

    func makeNSViewController(context: Context) -> ReaderSplitViewController {
        ReaderSplitViewController(model: model, reader: reader)
    }

    func updateNSViewController(_ controller: ReaderSplitViewController, context: Context) {}
}

/// The PDF pane's SwiftUI side: PDFReaderView with the ChatModel's bindings.
private struct PDFPane: View {
    @Bindable var model: ChatModel
    let reader: ReaderController

    var body: some View {
        PDFReaderView(document: model.document,
                      controller: reader,
                      readingState: $model.readingState,
                      goToPageRequest: $model.goToPageRequest)
    }
}

/// An AppKit split view rather than SwiftUI's HSplitView, which can't set where its dividers start
/// (the sidebar opened at 140 or 261 pt instead of 180) and rebuilt a hidden pane (the chat's web view
/// reloaded every time it was shown). Here hiding collapses a pane and keeps its views; the PDF pane
/// takes up window resizing; dragging a divider closed hides the sidebar or chat like the menu does.
@MainActor
final class ReaderSplitViewController: NSSplitViewController {
    static let sidebarRange: ClosedRange<CGFloat> = 140...320
    static let pdfMinimumWidth: CGFloat = 260
    static let chatMinimumWidth: CGFloat = 340
    static let chatDefaultWidth: CGFloat = 440
    static var minimumWidth: CGFloat { sidebarRange.lowerBound + pdfMinimumWidth + chatMinimumWidth + 2 }

    private let reader: ReaderController
    private let sidebarItem: NSSplitViewItem
    private let pdfItem: NSSplitViewItem
    private let chatItem: NSSplitViewItem
    private var placedDividers = false
    private var syncing = false

    init(model: ChatModel, reader: ReaderController) {
        self.reader = reader
        let sidebar = NSHostingController(rootView: ReaderSidebar(controller: reader))
        let pdf = NSHostingController(rootView: PDFPane(model: model, reader: reader))
        let chat = NSHostingController(rootView: ChatPaneView(model: model))
        Self.configure(sidebar)
        Self.configure(pdf)
        Self.configure(chat)

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
        observeReader()
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
                item.animator().isCollapsed = !visible
            } else {
                item.isCollapsed = !visible
            }
        }
    }

    /// A divider dragged until its pane collapsed (or back open) updates the reader's state.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard placedDividers, !syncing else { return }
        if sidebarItem.isCollapsed == reader.sidebarVisible { reader.setSidebarVisible(!sidebarItem.isCollapsed) }
        if chatItem.isCollapsed == reader.chatVisible { reader.setChatVisible(!chatItem.isCollapsed) }
    }
}

