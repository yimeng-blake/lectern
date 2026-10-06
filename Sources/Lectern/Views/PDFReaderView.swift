import AppKit
import LecternCore
import Observation
import PDFKit
import SwiftUI

/// The PDF pane. Shows the window's ReaderController's PDFView, reports what the reader is looking at
/// through `readingState` and navigates when `goToPageRequest` (0-based) is set, clearing it afterwards.
/// Those jumps (citation links in the chat) are recorded in the controller's Back history.
struct PDFReaderView: NSViewRepresentable {
    let document: ReaderDocument
    let controller: ReaderController
    @Binding var readingState: ReadingState
    @Binding var goToPageRequest: Int?      // 0-based

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A container, because the PDFView belongs to the controller and outlives this representable.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = controller.pdfView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if view.document !== document.pdf { view.document = document.pdf }
        context.coordinator.attach(to: view)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let view = controller.pdfView
        if view.document !== document.pdf {
            view.document = document.pdf
            coordinator.scheduleStateUpdate()
        }
        coordinator.handleGoToRequest()
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFReaderView
        private weak var pdfView: PDFView?
        private weak var clipView: NSClipView?
        private var selectionTask: Task<Void, Never>?
        private var stateUpdatePending = false
        private var layoutRetries = 0
        /// Request already navigated to, waiting for the binding to be cleared.
        private var handledRequest: Int?

        init(_ parent: PDFReaderView) {
            self.parent = parent
        }

        func attach(to view: PDFView) {
            pdfView = view
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: view)
            center.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewDocumentChanged, object: view)
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            // PDFView builds its scroll view lazily; hook scrolling once it exists.
            DispatchQueue.main.async { [weak self] in
                self?.observeScrolling()
                self?.scheduleStateUpdate()
            }
            observeGoToRequests()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            selectionTask?.cancel()
            selectionTask = nil
            pdfView = nil
            clipView = nil
        }

        private func observeScrolling() {
            guard let view = pdfView, clipView == nil,
                  let scrollView = Self.findScrollView(in: view) else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clipView = clip
            NotificationCenter.default.addObserver(self, selector: #selector(visiblePagesChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }

        private static func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }

        // MARK: Reading state

        @objc private func pageChanged(_ note: Notification) { scheduleStateUpdate() }

        @objc private func visiblePagesChanged(_ note: Notification) {
            if clipView == nil { observeScrolling() }
            scheduleStateUpdate()
        }

        @objc private func selectionChanged(_ note: Notification) {
            selectionTask?.cancel()
            selectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                self?.writeState()
            }
        }

        /// Coalesces bursts (every scroll tick posts a notification) into one write per run-loop turn.
        func scheduleStateUpdate() {
            guard !stateUpdatePending else { return }
            stateUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateUpdatePending = false
                self.writeState()
            }
        }

        private func writeState() {
            guard let view = pdfView, let doc = view.document else { return }
            var state = parent.readingState
            let visible = view.visiblePages
            // PDFView keeps currentPage current for wheel/keyboard scrolling but not for every
            // programmatic clip-view scroll; the controller falls back to the most visible page.
            if let page = parent.controller.effectiveCurrentPage() {
                let index = doc.index(for: page)
                if index >= 0 {
                    state.currentPage = index
                    parent.controller.noteCurrentPage(index)
                }
            }
            state.visiblePages = visible.map { doc.index(for: $0) }.filter { $0 >= 0 }.sorted()
            if visible.isEmpty, doc.pageCount > 0 {
                // Not laid out yet (large documents); nothing else will fire until the user scrolls.
                if layoutRetries < 50 {
                    layoutRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.scheduleStateUpdate() }
                }
            } else {
                layoutRetries = 0
            }
            if let selection = view.currentSelection,
               let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                state.selectionText = text
                state.selectionPages = Array(Set(selection.pages.map { doc.index(for: $0) }.filter { $0 >= 0 })).sorted()
            } else {
                state.selectionText = nil
                state.selectionPages = []
            }
            if state != parent.readingState { parent.readingState = state }
        }

        // MARK: Navigation

        func handleGoToRequest() {
            guard let request = parent.goToPageRequest else {
                handledRequest = nil
                return
            }
            guard request != handledRequest else { return }
            handledRequest = request
            if let view = pdfView, let doc = view.document, doc.pageCount > 0 {
                // Through the controller, so Back returns to where the reader was.
                parent.controller.goToPage(min(max(request, 0), doc.pageCount - 1))
            }
            // Never write a binding during a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.goToPageRequest == request { self.parent.goToPageRequest = nil }
                self.handledRequest = nil
            }
        }

        /// updateNSView normally sees request changes, but this also catches them when the hosting
        /// view's body doesn't depend on the request.
        private func observeGoToRequests() {
            withObservationTracking {
                _ = parent.goToPageRequest
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.pdfView != nil else { return }
                    self.handleGoToRequest()
                    self.observeGoToRequests()
                }
            }
        }
    }
}
