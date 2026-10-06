import AppKit
import LecternCore
import Observation
import PDFKit
import UniformTypeIdentifiers

/// The viewer side of one reader window: owns the PDFView and the sidebar's PDFThumbnailView, and
/// exposes page, zoom, display-mode, sidebar, history and find state plus the actions behind the
/// toolbar and the View / Go / Find menus (routed here by ReaderWindowManager for the key window).
///
/// Nothing here writes to the PDF file. Highlights are in-memory annotations on the UI document (never
/// saved; HighlightStore keeps them in Lectern's own storage), and the AI's page images come from
/// ReaderDocument's separate extraction copy, so they never show them. Search hits and citation
/// flashes never become `currentSelection` (which the chat reads as "selection").
@MainActor @Observable
final class ReaderController {
    enum SidebarMode: String {
        case thumbnails, contents, searchResults, highlights
    }

    enum ZoomMode: String {
        /// Page width fills the view (PDFView autoscaling in continuous modes).
        case fitWidth
        /// The whole page fits (PDFView autoscaling in non-continuous modes).
        case fitPage
        /// A fixed scale factor (Actual Size, zoom in/out, pinch).
        case custom
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case singlePage, singlePageContinuous, twoPages, twoPagesContinuous

        var id: String { rawValue }

        var pdfMode: PDFDisplayMode {
            switch self {
            case .singlePage: return .singlePage
            case .singlePageContinuous: return .singlePageContinuous
            case .twoPages: return .twoUp
            case .twoPagesContinuous: return .twoUpContinuous
            }
        }

        var title: String {
            switch self {
            case .singlePage: return "Single Page"
            case .singlePageContinuous: return "Single Page Continuous"
            case .twoPages: return "Two Pages"
            case .twoPagesContinuous: return "Two Pages Continuous"
            }
        }

        var isContinuous: Bool { self == .singlePageContinuous || self == .twoPagesContinuous }
        var pagesPerRow: CGFloat { self == .twoPages || self == .twoPagesContinuous ? 2 : 1 }
    }

    enum SearchStatus {
        case idle, searching, finished
    }

    struct SearchMatch: Identifiable {
        let id: Int
        let pageIndex: Int          // 0-based
        let selection: PDFSelection
    }

    /// A search result's context: `hit` is the match, `head`/`tail` the text around it (with "…"
    /// where it was cut).
    struct SearchSnippet {
        let head: String
        let hit: String
        let tail: String
    }

    /// A place in the document, for Back / Forward.
    struct Location: Equatable {
        let pageIndex: Int
        let point: CGPoint
    }

    static let maxSearchMatches = 5000
    static let searchDebounce: Duration = .milliseconds(250)
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 16
    static let sidebarDefaultWidth: CGFloat = 180

    // MARK: Views

    @ObservationIgnored let pdfView = ReaderPDFView()
    @ObservationIgnored private var thumbnails: PDFThumbnailView?

    /// The sidebar's thumbnail strip, bound to `pdfView` (created on first use; PDFKit renders the
    /// thumbnails lazily, off the main thread).
    var thumbnailView: PDFThumbnailView {
        if let thumbnails { return thumbnails }
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.backgroundColor = .clear
        if AppServices.shared.settings.darkPages {
            PageInversion.apply(true, to: pdfView, background: { [pdfView] in pdfView.backgroundColor = $0 },
                                thumbnails: view)
        }
        // Dragging a thumbnail would reorder (edit) the in-memory document.
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.thumbnailSize = CGSize(width: 120, height: 160)
        view.setAccessibilityLabel("Page thumbnails")
        thumbnails = view
        return view
    }

    /// Registered by the toolbar so the Find and Go to Page commands can focus them.
    @ObservationIgnored weak var searchField: NSSearchField?
    @ObservationIgnored weak var pageField: NSTextField?

    // MARK: State

    private(set) var document: ReaderDocument?
    var isReady: Bool { document != nil }
    private(set) var pageCount = 0
    private(set) var currentPageIndex = 0
    /// What the page box shows: the page label when the PDF defines its own (e.g. "iv"), else the number.
    private(set) var currentPageLabel = ""
    /// The PDF has page labels that differ from the plain page numbers.
    private(set) var hasCustomPageLabels = false
    private(set) var scaleFactor: CGFloat = 1
    private(set) var zoomMode = ZoomMode.fitWidth
    private(set) var displayMode = DisplayMode.singlePageContinuous
    private(set) var sidebarVisible = true
    private(set) var sidebarMode = SidebarMode.thumbnails
    private(set) var chatVisible = true
    private(set) var hasOutline = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The table-of-contents entry the reader is in (the last one starting at or before the current
    /// page) and that entry's ancestors.
    private(set) var currentOutlineID: Int?
    private(set) var currentOutlinePath: Set<Int> = []

    // Find
    private(set) var searchText = ""
    private(set) var searchStatus = SearchStatus.idle
    private(set) var matches: [SearchMatch] = []
    private(set) var matchesTruncated = false
    /// Changes whenever a search starts or ends (the results list reloads instead of appending).
    private(set) var searchID = 0
    private(set) var currentMatchIndex: Int?
    var isSearching: Bool { searchStatus != .idle }

    /// The PDF has a text selection (for the Ask Lectern / Highlight menu items).
    private(set) var hasTextSelection = false
    /// The document's highlights (shared with other windows on the same bytes).
    private(set) var highlightStore: HighlightStore?
    var highlights: [Highlight] { highlightStore?.highlights ?? [] }
    var hasHighlights: Bool { !(highlightStore?.highlights.isEmpty ?? true) }

    /// Sends a selection question to the chat: (action, selected text, 1-based pages). Set by DocumentWindow.
    @ObservationIgnored var onAsk: ((SelectionAction, String, [Int]) -> Void)?

    var canZoomIn: Bool { isReady && scaleFactor < Self.maxScale - 0.001 }
    var canZoomOut: Bool { isReady && scaleFactor > Self.minScale + 0.001 }
    var canGoToPreviousPage: Bool { isReady && currentPageIndex > 0 }
    var canGoToNextPage: Bool { isReady && currentPageIndex < pageCount - 1 }
    var canPrint: Bool { document?.pdf.allowsPrinting ?? false }

    /// "of 340", or "(16 of 340)" next to a page label.
    var pageCountText: String {
        guard isReady else { return "" }
        return hasCustomPageLabels ? "(\(currentPageIndex + 1) of \(pageCount))" : "of \(pageCount)"
    }

    /// "3 of 27", "Searching…", "No results".
    var searchCounterText: String {
        switch searchStatus {
        case .idle:
            return ""
        case .searching where matches.isEmpty:
            return "Searching\u{2026}"
        case .finished where matches.isEmpty:
            return "No results"
        default:
            let total = matchesTruncated ? "\(matches.count)+" : "\(matches.count)"
            if let current = currentMatchIndex { return "\(current + 1) of \(total)" }
            return "\(total) found"
        }
    }

    // MARK: Private state

    @ObservationIgnored private var store: SessionStore?
    /// False in a second window on the same bytes: like its chat, its place isn't saved.
    @ObservationIgnored private var persists = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var applyingZoom = false
    @ObservationIgnored private var zoomRefreshPending = false
    @ObservationIgnored private var pendingRestorePage: Int?
    @ObservationIgnored private var restoreAttempts = 0
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var backStack: [Location] = []
    @ObservationIgnored private var forwardStack: [Location] = []
    @ObservationIgnored private var labelIndex: [String: Int]?
    @ObservationIgnored private var outlineTree: [OutlineNode]?
    @ObservationIgnored private var flatOutline: [OutlineNode.Entry] = []
    @ObservationIgnored private var tookInitialFocus = false

    // Find internals
    @ObservationIgnored private var finderDelegate: SearchDelegate?
    /// Bumped whenever a search starts or ends, so deferred work for an older search is dropped.
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var activeQuery: String?
    @ObservationIgnored private var pendingMatches: [SearchMatch] = []
    @ObservationIgnored private var matchFlushScheduled = false
    @ObservationIgnored private var searchStartPage = 0
    @ObservationIgnored private var sidebarBeforeSearch: (visible: Bool, mode: SidebarMode)?
    /// Where the reader was when the search started; pushed on Back's stack at the first jump to a match.
    @ObservationIgnored private var searchOrigin: Location?
    @ObservationIgnored private var pageStrings: [Int: NSString] = [:]
    @ObservationIgnored private var snippets: [Int: SearchSnippet] = [:]

    // Highlights and citation flashes
    /// Annotations currently drawn for each highlight, with the highlight they were drawn from.
    @ObservationIgnored private var drawnHighlights: [UUID: (highlight: Highlight, annotations: [PDFAnnotation])] = [:]
    @ObservationIgnored private var passageTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var flashAnnotations: [PDFAnnotation] = []

    init() {
        // Before autoScales: setting the scale limits turns autoscaling off (verified).
        pdfView.minScaleFactor = Self.minScale
        pdfView.maxScaleFactor = Self.maxScale
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.setAccessibilityIdentifier("pdfView")
        pdfView.onEscape = { [weak self] in self?.handleEscape() ?? false }
        pdfView.onResize = { [weak self] in self?.viewResized() }
        pdfView.onLayout = { [weak self] in
            self?.takeInitialFocus()
            self?.applyPendingRestore()
        }
        pdfView.contextMenuItems = { [weak self] event in self?.contextMenuItems(for: event) ?? [] }
        applyDarkPages()
        darkPagesObserver = NotificationCenter.default.addObserver(
            forName: .lecternDarkPagesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDarkPages() }
        }
    }

    @ObservationIgnored private var darkPagesObserver: NSObjectProtocol?

    private func applyDarkPages() {
        PageInversion.apply(AppServices.shared.settings.darkPages, to: pdfView,
                            background: { [pdfView] in pdfView.backgroundColor = $0 },
                            thumbnails: thumbnails)
    }

    // MARK: Lifecycle

    /// Shows the (unlocked) document and restores the last viewer state saved for its bytes.
    /// `persists`: save this window's place (false for a second window on the same bytes).
    func attach(_ document: ReaderDocument, store: SessionStore, persists: Bool = true) {
        guard self.document == nil, !isClosed else { return }
        self.store = store
        self.persists = persists
        let pdf = document.pdf
        pageCount = pdf.pageCount
        hasCustomPageLabels = Self.hasCustomLabels(pdf)
        hasOutline = (pdf.outlineRoot?.numberOfChildren ?? 0) > 0
        pdfView.document = pdf
        self.document = document
        observePDFView()
        highlightStore = HighlightStore.forDocument(contentHash: document.contentHash)
        syncHighlights()
        observeHighlights()

        if let saved = store.load(contentHash: document.contentHash)?.viewer {
            restore(saved)
        } else {
            applyZoomMode()
        }
        if sidebarMode == .contents && !hasOutline { sidebarMode = .thumbnails }
        scaleFactor = pdfView.scaleFactor
        updateCurrentPage(currentPageIndex)
    }

    /// Window closing: save the viewer state and stop any search.
    func close() {
        guard !isClosed else { return }
        if isReady { saveNow() }
        isClosed = true
        saveTask?.cancel()
        searchDebounceTask?.cancel()
        passageTask?.cancel()
        flashTask?.cancel()
        onAsk = nil
        cancelFind()
        if let finderDelegate, document?.pdf.delegate === finderDelegate { document?.pdf.delegate = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let darkPagesObserver { NotificationCenter.default.removeObserver(darkPagesObserver) }
        darkPagesObserver = nil
        pdfView.onEscape = nil
        pdfView.onResize = nil
        pdfView.onLayout = nil
        pdfView.contextMenuItems = nil
    }

    private func observePDFView() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewDisplayModeChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayModeChangedByView() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
    }

    /// Cheap (no text extraction): runs on every change while dragging.
    private func selectionChanged() {
        let has = !(pdfView.currentSelection?.pages.isEmpty ?? true)
        if hasTextSelection != has { hasTextSelection = has }
    }

    // MARK: Current page

    /// Called by PDFReaderView whenever it recomputes the reading state (page changes and scrolling).
    func noteCurrentPage(_ index: Int) {
        guard isReady, index >= 0, index < pageCount else { return }
        let changed = index != currentPageIndex
        updateCurrentPage(index)
        if changed { scheduleSave() }
    }

    private func updateCurrentPage(_ index: Int) {
        if currentPageIndex != index { currentPageIndex = index }
        let label = labelForPage(index)
        if currentPageLabel != label { currentPageLabel = label }
        updateCurrentOutline()
    }

    /// The page's label (when the PDF defines its own) or its 1-based number.
    func pageLabel(for index: Int) -> String { labelForPage(index) }

    private func labelForPage(_ index: Int) -> String {
        guard pdfView.document != nil else { return "" }
        if hasCustomPageLabels, let label = pdfView.document?.page(at: index)?.label, !label.isEmpty {
            return label
        }
        return "\(index + 1)"
    }

    /// The page PDFView considers current, or the most visible page when PDFView's current page is
    /// off screen (it isn't kept current for every programmatic scroll).
    func effectiveCurrentPage() -> PDFPage? {
        let visible = pdfView.visiblePages
        var current = pdfView.currentPage
        if let page = current, !visible.isEmpty, !visible.contains(page) {
            current = visible.max { visibleArea($0) < visibleArea($1) } ?? page
        }
        return current
    }

    private func visibleArea(_ page: PDFPage) -> CGFloat {
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).intersection(pdfView.bounds)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private static func hasCustomLabels(_ pdf: PDFDocument) -> Bool {
        for i in 0..<pdf.pageCount {
            guard let label = pdf.page(at: i)?.label else { continue }
            if label != "\(i + 1)" { return true }
        }
        return false
    }

    // MARK: Navigation

    /// 0-based. `record` pushes the current place on Back's stack (jumps; not next/previous page).
    func goToPage(_ index: Int, record: Bool = true) {
        guard let pdf = pdfView.document, index >= 0, index < pdf.pageCount, let page = pdf.page(at: index) else { return }
        if record, index != currentPageIndex { recordJump() }
        pdfView.go(to: page)
        updateCurrentPage(index)
        scheduleSave()
    }

    /// The page box: a page label (when the PDF has its own, e.g. "iv" or "12") or a 1-based number.
    /// Returns false (and doesn't move) for anything else.
    @discardableResult
    func goToPage(text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !t.isEmpty else { return false }
        if hasCustomPageLabels, let index = pageIndex(forLabel: t) {
            goToPage(index)
            return true
        }
        if let n = Int(t), n >= 1, n <= pageCount {
            goToPage(n - 1)
            return true
        }
        if let index = pageIndex(forLabel: t) {
            goToPage(index)
            return true
        }
        return false
    }

    private func pageIndex(forLabel label: String) -> Int? {
        if labelIndex == nil, let pdf = pdfView.document {
            var map: [String: Int] = [:]
            for i in 0..<pdf.pageCount {
                guard let l = pdf.page(at: i)?.label?.lowercased(), !l.isEmpty, map[l] == nil else { continue }
                map[l] = i
            }
            labelIndex = map
        }
        return labelIndex?[label.lowercased()]
    }

    func goToNextPage() {
        guard isReady else { return }
        pdfView.goToNextPage(nil)
    }

    func goToPreviousPage() {
        guard isReady else { return }
        pdfView.goToPreviousPage(nil)
    }

    func goToFirstPage() { goToPage(0) }
    func goToLastPage() { goToPage(pageCount - 1) }

    /// Jumps to an outline (table of contents) entry.
    func go(to node: OutlineNode) {
        guard let pageIndex = node.pageIndex else { return }
        if pageIndex != currentPageIndex { recordJump() }
        if let destination = node.destination, destination.page != nil {
            pdfView.go(to: destination)
        } else if let page = pdfView.document?.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        updateCurrentPage(pageIndex)
        scheduleSave()
    }

    // MARK: History

    private func currentLocation() -> Location? {
        guard let pdf = pdfView.document, let destination = pdfView.currentDestination,
              let page = destination.page else { return nil }
        let index = pdf.index(for: page)
        guard index >= 0 else { return nil }
        return Location(pageIndex: index, point: destination.point)
    }

    private func recordJump(from location: Location? = nil) {
        guard let here = location ?? currentLocation() else { return }
        if backStack.last != here { backStack.append(here) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
        updateHistoryFlags()
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let here = currentLocation() { forwardStack.append(here) }
        show(target)
        updateHistoryFlags()
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let here = currentLocation() { backStack.append(here) }
        show(target)
        updateHistoryFlags()
    }

    private func show(_ location: Location) {
        guard let page = pdfView.document?.page(at: location.pageIndex) else { return }
        pdfView.go(to: PDFDestination(page: page, at: location.point))
        updateCurrentPage(location.pageIndex)
        scheduleSave()
    }

    private func updateHistoryFlags() {
        if canGoBack != !backStack.isEmpty { canGoBack = !backStack.isEmpty }
        if canGoForward != !forwardStack.isEmpty { canGoForward = !forwardStack.isEmpty }
    }

    // MARK: Zoom

    func zoomIn() {
        guard canZoomIn else { return }
        setScale(scaleFactor * 1.25)
    }

    func zoomOut() {
        guard canZoomOut else { return }
        setScale(scaleFactor / 1.25)
    }

    func actualSize() {
        guard isReady else { return }
        setScale(1)
    }

    func zoomToFit() { setZoomMode(.fitPage) }
    func zoomToWidth() { setZoomMode(.fitWidth) }

    private func setScale(_ scale: CGFloat) {
        let anchor = effectiveCurrentPage()
        zoomMode = .custom
        applyingZoom = true
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, Self.minScale), Self.maxScale)
        applyingZoom = false
        scaleFactor = pdfView.scaleFactor
        keepPageVisible(anchor)
        scheduleSave()
    }

    private func setZoomMode(_ mode: ZoomMode) {
        guard isReady else { return }
        let anchor = effectiveCurrentPage()
        zoomMode = mode
        applyZoomMode()
        keepPageVisible(anchor)
        scheduleSave()
    }

    /// PDFView autoscaling fits the width in continuous modes and the whole page otherwise; the other
    /// combinations are computed here (and again when the view is resized).
    private func applyZoomMode() {
        applyingZoom = true
        defer {
            applyingZoom = false
            scaleFactor = pdfView.scaleFactor
        }
        switch zoomMode {
        case .fitWidth:
            if displayMode.isContinuous {
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                if let scale = fitScale(page: false) { pdfView.scaleFactor = scale }
            }
        case .fitPage:
            if !displayMode.isContinuous {
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                if let scale = fitScale(page: true) { pdfView.scaleFactor = scale }
            }
        case .custom:
            break
        }
    }

    /// Scale at which the current page row fits the view's width (and, with `page`, its height too).
    private func fitScale(page fitPage: Bool) -> CGFloat? {
        guard let page = effectiveCurrentPage() ?? pdfView.document?.page(at: 0) else { return nil }
        let bounds = pdfView.bounds
        guard bounds.width > 20, bounds.height > 20 else { return nil }
        var size = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return nil }
        let margins = pdfView.pageBreakMargins
        let rowWidth = displayMode.pagesPerRow * (size.width + margins.left + margins.right)
        var scale = bounds.width / rowWidth
        if fitPage {
            // PDFView's own page fit leaves about this much room around a page (measured: 19 pt at 792 pt).
            let rowHeight = size.height + margins.top + margins.bottom + 10
            scale = min(scale, bounds.height / rowHeight)
        }
        return min(max(scale, Self.minScale), Self.maxScale)
    }

    private func viewResized() {
        let computed = (zoomMode == .fitWidth && !displayMode.isContinuous) || (zoomMode == .fitPage && displayMode.isContinuous)
        guard computed, isReady, !zoomRefreshPending else { return }
        zoomRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.zoomRefreshPending = false
            self.applyZoomMode()
        }
    }

    private func scaleChanged() {
        scaleFactor = pdfView.scaleFactor
        // A pinch or PDFView's own zoom commands: a fit mode no longer applies.
        if !applyingZoom, !pdfView.autoScales, zoomMode != .custom, !zoomRefreshPending {
            zoomMode = .custom
            scheduleSave()
        }
    }

    /// Keeps the page the reader was on in view after a scale or layout change.
    private func keepPageVisible(_ page: PDFPage?) {
        guard let page, effectiveCurrentPage() != page else { return }
        pdfView.go(to: page)
    }

    // MARK: Display mode

    func setDisplayMode(_ mode: DisplayMode) {
        guard isReady, mode != displayMode || pdfView.displayMode != mode.pdfMode else { return }
        let anchor = effectiveCurrentPage()
        displayMode = mode
        pdfView.displayMode = mode.pdfMode
        applyZoomMode()
        if let anchor { pdfView.go(to: anchor) }
        scheduleSave()
    }

    private func displayModeChangedByView() {
        // PDFView's context menu can change the mode too.
        if let mode = DisplayMode.allCases.first(where: { $0.pdfMode == pdfView.displayMode }), mode != displayMode {
            displayMode = mode
            scheduleSave()
        }
    }

    // MARK: Sidebar and chat

    func toggleSidebar() {
        guard isReady else { return }
        sidebarVisible.toggle()
        scheduleSave()
    }

    /// Shows the sidebar in `mode` (View > Thumbnails / Table of Contents, the sidebar's picker).
    func showSidebar(_ mode: SidebarMode) {
        guard isReady else { return }
        switch mode {
        case .contents where !hasOutline:
            NSSound.beep()
            return
        case .searchResults where !isSearching:
            return
        default:
            break
        }
        sidebarMode = mode
        sidebarVisible = true
        scheduleSave()
    }

    func toggleChat() {
        guard isReady else { return }
        chatVisible.toggle()
        scheduleSave()
    }

    /// The split view's divider was dragged until the sidebar collapsed (or back open).
    func setSidebarVisible(_ visible: Bool) {
        guard isReady, sidebarVisible != visible else { return }
        sidebarVisible = visible
        scheduleSave()
    }

    /// Same, for the chat pane.
    func setChatVisible(_ visible: Bool) {
        guard isReady, chatVisible != visible else { return }
        chatVisible = visible
        scheduleSave()
    }

    // MARK: Table of contents

    /// Top-level outline entries (built on first use; children are built when expanded).
    var outlineRoots: [OutlineNode] {
        if let outlineTree { return outlineTree }
        guard let pdf = pdfView.document, let root = pdf.outlineRoot else { return [] }
        var counter = 0
        var flat: [OutlineNode.Entry] = []
        let tree = OutlineNode.children(of: root, in: pdf, counter: &counter, flat: &flat, ancestors: [])
        outlineTree = tree
        flatOutline = flat
        // Read from a view's body: observed state changes after this update pass, not during it.
        DispatchQueue.main.async { [weak self] in self?.updateCurrentOutline() }
        return tree
    }

    /// The last entry (in reading order) that starts at or before the current page.
    private func updateCurrentOutline() {
        guard !flatOutline.isEmpty else { return }
        var best: OutlineNode.Entry?
        for entry in flatOutline where entry.page <= currentPageIndex && entry.page >= (best?.page ?? -1) {
            best = entry
        }
        if currentOutlineID != best?.id { currentOutlineID = best?.id }
        let path = best.map { Set($0.ancestors + [$0.id]) } ?? []
        if currentOutlinePath != path { currentOutlinePath = path }
    }

    // MARK: Print

    func printDocument() {
        guard let pdf = pdfView.document, pdf.allowsPrinting, let window = pdfView.window else {
            NSSound.beep()
            return
        }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            NSSound.beep()
            return
        }
        operation.jobTitle = window.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Focus

    /// ⌘F: focus the toolbar's search field, from anywhere in the window.
    func focusSearch() {
        guard isReady, let field = searchField else { return }
        reveal(field)
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Go > Go to Page…: focus the page box with its text selected.
    func focusPageField() {
        guard isReady, let field = pageField else { return }
        reveal(field)
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// The toolbar may have been hidden (View > Hide Toolbar).
    private func reveal(_ field: NSView) {
        if let toolbar = pdfView.window?.toolbar, !toolbar.isVisible { toolbar.isVisible = true }
    }

    func focusPDF() {
        pdfView.window?.makeFirstResponder(pdfView)
    }

    /// AppKit gives a new window's focus to its first key view, the toolbar's page box; the document
    /// should have it, as in Preview.
    private func takeInitialFocus() {
        guard !tookInitialFocus, isReady, pdfView.window != nil else { return }
        tookInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.pdfView.window else { return }
            let responder = window.firstResponder
            let pageEditor = self.pageField?.currentEditor()
            if responder == nil || responder === window || responder === self.pageField
                || (pageEditor != nil && responder === pageEditor) {
                window.makeFirstResponder(self.pdfView)
            }
        }
    }

    /// Esc in the PDF view ends a search.
    private func handleEscape() -> Bool {
        guard isSearching else { return false }
        endSearch()
        return true
    }

    // MARK: Find

    /// The search field's text changed. Searches ~250 ms after typing stops; an empty field ends the search.
    func searchTextChanged(_ text: String) {
        guard isReady, text != searchText || (searchStatus == .idle && !text.isEmpty) else { return }
        searchText = text
        searchDebounceTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            if isSearching { endSearch(keepFieldText: true) }
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            self?.startFind(query)
        }
    }

    /// Return in the field: search now if the text changed, else go to the next match.
    func searchSubmitted(_ text: String, backwards: Bool) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !query.isEmpty else { return }
        if text != searchText { searchText = text }
        if query != activeQuery || searchStatus == .idle {
            searchDebounceTask?.cancel()
            startFind(query)
            return
        }
        backwards ? findPrevious() : findNext()
    }

    /// Uses the PDF's text selection as the search (Find > Use Selection for Find).
    func useSelectionForFind() {
        guard isReady, let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            NSSound.beep()
            return
        }
        let query = String(text.prefix(200))
        searchField?.stringValue = query
        searchText = query
        searchDebounceTask?.cancel()
        startFind(query)
    }

    func findNext() { stepMatch(by: 1) }
    func findPrevious() { stepMatch(by: -1) }

    private func stepMatch(by step: Int) {
        guard isReady else { return }
        guard isSearching else {
            // ⌘G with nothing searched yet: search for what is in the field, else focus it.
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { focusSearch() } else { startFind(query) }
            return
        }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let count = matches.count
        let next = currentMatchIndex.map { (($0 + step) % count + count) % count } ?? (step > 0 ? 0 : count - 1)
        selectMatch(next)
    }

    /// Makes a match current: stronger highlight, scrolled into view. Never sets currentSelection.
    func selectMatch(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        if let origin = searchOrigin {
            searchOrigin = nil
            if matches[index].pageIndex != origin.pageIndex { recordJump(from: origin) }
        }
        let previous = currentMatchIndex
        currentMatchIndex = index
        if let previous, matches.indices.contains(previous) { matches[previous].selection.color = Self.matchColor }
        matches[index].selection.color = Self.currentMatchColor
        applyHighlights()
        scroll(to: matches[index])
    }

    /// Esc, an emptied field, or the field's clear button: removes highlights and results and puts the
    /// sidebar back the way it was.
    func endSearch(keepFieldText: Bool = false) {
        searchDebounceTask?.cancel()
        let wasSearching = isSearching
        searchStatus = .idle
        searchGeneration += 1
        if wasSearching { searchID += 1 }
        cancelFind()
        activeQuery = nil
        matches = []
        pendingMatches = []
        matchesTruncated = false
        currentMatchIndex = nil
        searchOrigin = nil
        snippets = [:]
        pageStrings = [:]
        pdfView.highlightedSelections = nil
        if !keepFieldText {
            searchText = ""
            searchField?.stringValue = ""
        }
        if wasSearching, let before = sidebarBeforeSearch {
            sidebarVisible = before.visible
            sidebarMode = before.mode == .searchResults ? .thumbnails : before.mode
        }
        sidebarBeforeSearch = nil
    }

    private func startFind(_ query: String) {
        guard let pdf = pdfView.document, !isClosed else { return }
        if searchStatus == .idle {
            sidebarBeforeSearch = (sidebarVisible, sidebarMode)
            searchOrigin = currentLocation()
        } else {
            searchStatus = .idle    // ignore callbacks from the search being replaced
            cancelFind()
        }
        activeQuery = query
        matches = []
        pendingMatches = []
        matchesTruncated = false
        currentMatchIndex = nil
        snippets = [:]
        pdfView.highlightedSelections = nil
        searchStartPage = currentPageIndex
        sidebarMode = .searchResults
        sidebarVisible = true
        searchStatus = .searching
        searchGeneration += 1
        searchID += 1
        let delegate = finderDelegate ?? SearchDelegate(owner: self)
        finderDelegate = delegate
        pdf.delegate = delegate
        pdf.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func cancelFind() {
        guard let pdf = pdfView.document, pdf.isFinding else { return }
        // PDFKit reports the end of the cancelled search synchronously; searchStatus is no longer
        // .searching here, so that report is ignored.
        pdf.cancelFindString()
    }

    fileprivate func found(_ selection: PDFSelection) {
        guard searchStatus == .searching, let pdf = pdfView.document, let page = selection.pages.first else { return }
        let index = pdf.index(for: page)
        guard index >= 0 else { return }
        selection.color = Self.matchColor
        pendingMatches.append(SearchMatch(id: matches.count + pendingMatches.count, pageIndex: index, selection: selection))
        if matches.count + pendingMatches.count >= Self.maxSearchMatches {
            matchesTruncated = true
            finishFind(cancel: true)
            return
        }
        scheduleMatchFlush()
    }

    fileprivate func findEnded() {
        guard searchStatus == .searching else { return }
        finishFind(cancel: false)
    }

    private func finishFind(cancel: Bool) {
        searchStatus = .finished
        if cancel {
            // Not from inside PDFKit's match callback; later matches are ignored (status is .finished).
            let generation = searchGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                self.cancelFind()
            }
        }
        flushMatches()
        if currentMatchIndex == nil, !matches.isEmpty { selectMatch(0) }
    }

    /// Results arrive one by one; the list and highlights are updated at most every 100 ms.
    private func scheduleMatchFlush() {
        guard !matchFlushScheduled else { return }
        matchFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.matchFlushScheduled = false
            if self.searchStatus == .searching { self.flushMatches() }
        }
    }

    private func flushMatches() {
        guard !pendingMatches.isEmpty else { return }
        matches.append(contentsOf: pendingMatches)
        pendingMatches = []
        if currentMatchIndex == nil,
           let first = matches.firstIndex(where: { $0.pageIndex >= searchStartPage }) {
            selectMatch(first)
        } else {
            applyHighlights()
        }
    }

    private func applyHighlights() {
        pdfView.highlightedSelections = matches.map(\.selection)
    }

    private func scroll(to match: SearchMatch) {
        guard let page = match.selection.pages.first else { return }
        scroll(to: match.selection.bounds(for: page), on: page, index: match.pageIndex)
    }

    /// Scrolls a rect on a page (page space) into view.
    private func scroll(to bounds: CGRect, on page: PDFPage, index: Int) {
        // Some room above and below so the target isn't glued to the view's edge.
        let target = bounds.insetBy(dx: -20, dy: -min(120, pdfView.bounds.height / 4 / max(scaleFactor, 0.1)))
        pdfView.go(to: target, on: page)
        updateCurrentPage(index)
    }

    /// "…context **match** context…" around a match (about 60 characters), whitespace collapsed.
    func snippet(for match: SearchMatch) -> SearchSnippet {
        if let cached = snippets[match.id] { return cached }
        let result = makeSnippet(match)
        snippets[match.id] = result
        return result
    }

    private func makeSnippet(_ match: SearchMatch) -> SearchSnippet {
        let fallback = SearchSnippet(head: "", hit: Self.collapse(match.selection.string ?? ""), tail: "")
        guard let page = match.selection.pages.first else { return fallback }
        let text: NSString
        if let cached = pageStrings[match.pageIndex] {
            text = cached
        } else {
            text = (page.string ?? "") as NSString
            pageStrings[match.pageIndex] = text
        }
        let range = match.selection.range(at: 0, on: page)
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else {
            return fallback
        }
        let before = 28, after = 36
        var start = max(0, range.location - before)
        var end = min(text.length, NSMaxRange(range) + after)
        // Don't cut words in half.
        if start > 0 {
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                              range: NSRange(location: start, length: range.location - start))
            if space.location != NSNotFound { start = NSMaxRange(space) }
        }
        if end < text.length {
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                              range: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
            if space.location != NSNotFound { end = space.location }
        }
        let head = Self.collapse(text.substring(with: NSRange(location: start, length: range.location - start)))
        let hit = Self.collapse(text.substring(with: range))
        let tail = Self.collapse(text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
        var lead = head
        if start == 0 { lead = String(lead.drop { $0 == " " }) }
        return SearchSnippet(head: (start > 0 ? "\u{2026}" : "") + lead,
                             hit: hit,
                             tail: tail + (end < text.length ? "\u{2026}" : ""))
    }

    /// Runs of whitespace and line breaks become one space (kept at the ends, where they separate the
    /// match from its context).
    private static func collapse(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    static var matchColor: NSColor { NSColor.systemYellow.withAlphaComponent(0.45) }
    static var currentMatchColor: NSColor { NSColor.systemOrange.withAlphaComponent(0.75) }

    // MARK: Ask Lectern

    /// The selected text and its 1-based pages; nil when nothing (or only whitespace) is selected.
    private func selectedText() -> (text: String, pages: [Int])? {
        guard let pdf = pdfView.document, let selection = pdfView.currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let pages = Set(selection.pages.map { pdf.index(for: $0) }.filter { $0 >= 0 }).map { $0 + 1 }.sorted()
        return (text, pages)
    }

    /// Asks the chat about the selection (context menu, Edit > Ask Lectern); shows the chat if hidden.
    func ask(_ action: SelectionAction) {
        guard isReady, let onAsk, let selected = selectedText() else {
            NSSound.beep()
            return
        }
        setChatVisible(true)
        onAsk(action, selected.text, selected.pages)
    }

    // MARK: Highlights

    /// Highlights the selection (one highlight per text range) and clears it, as Preview does.
    func highlightSelection(_ color: HighlightColor = .yellow) {
        let new = highlightsFromSelection(color: color)
        guard !new.isEmpty, let store = highlightStore else {
            NSSound.beep()
            return
        }
        store.add(new)
        pdfView.clearSelection()
    }

    /// Asks for a note, then highlights the selection (yellow) with it.
    func addNoteToSelection() {
        let new = highlightsFromSelection(color: .yellow)
        guard !new.isEmpty, let store = highlightStore else {
            NSSound.beep()
            return
        }
        NoteEditor.edit(nil, quote: new.map(\.text).joined(separator: " "), in: pdfView.window) { [weak self] note in
            var annotated = new
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            annotated[0].note = trimmed.isEmpty ? nil : trimmed
            store.add(annotated)
            self?.pdfView.clearSelection()
        }
    }

    func editNote(_ id: UUID) {
        guard let store = highlightStore, let h = store.highlight(id) else { return }
        NoteEditor.edit(h.note, quote: h.text, in: pdfView.window) { note in store.setNote(note, for: id) }
    }

    func setHighlightColor(_ color: HighlightColor, for id: UUID) {
        highlightStore?.setColor(color, for: id)
    }

    func deleteHighlight(_ id: UUID) {
        highlightStore?.remove(id)
    }

    /// Scrolls to a highlight (Highlights sidebar), recorded for Back like the other jumps.
    func showHighlight(_ id: UUID) {
        guard isReady, let h = highlightStore?.highlight(id), let page = pdfView.document?.page(at: h.page) else { return }
        if h.page != currentPageIndex { recordJump() }
        if let range = validRange(h, on: page), let selection = page.selection(for: range) {
            scroll(to: selection.bounds(for: page), on: page, index: h.page)
        } else {
            pdfView.go(to: page)
            updateCurrentPage(h.page)
        }
        scheduleSave()
    }

    /// File > Export Highlights…: Markdown to a file the user picks (never the PDF).
    func exportHighlights() {
        guard let document, hasHighlights, let window = pdfView.window else {
            NSSound.beep()
            return
        }
        let markdown = HighlightStore.markdown(highlights, title: document.title)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(document.title) Highlights.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if let pdfURL = document.fileURL,
               ReaderWindowManager.canonical(url).path == ReaderWindowManager.canonical(pdfURL).path {
                NSSound.beep()
                return
            }
            do {
                try Data(markdown.utf8).write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func highlightsFromSelection(color: HighlightColor) -> [Highlight] {
        guard isReady, let pdf = pdfView.document, let selection = pdfView.currentSelection else { return [] }
        var out: [Highlight] = []
        for page in selection.pages {
            let index = pdf.index(for: page)
            guard index >= 0 else { continue }
            let text = (page.string ?? "") as NSString
            for i in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: i, on: page)
                guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { continue }
                let quote = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !quote.isEmpty { out.append(Highlight(page: index, range: range, text: quote, color: color)) }
            }
        }
        return out
    }

    /// The highlight's saved range, or where its text is on the page if the range no longer holds it.
    private func validRange(_ h: Highlight, on page: PDFPage) -> NSRange? {
        let text = (page.string ?? "") as NSString
        if h.length > 0, NSMaxRange(h.range) <= text.length,
           text.substring(with: h.range).trimmingCharacters(in: .whitespacesAndNewlines) == h.text {
            return h.range
        }
        let found = text.range(of: h.text)
        return found.location == NSNotFound ? nil : found
    }

    /// Redraws after every store change (from this window or another one on the same bytes).
    private func observeHighlights() {
        guard let store = highlightStore else { return }
        withObservationTracking {
            _ = store.highlights
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.syncHighlights()
                self.observeHighlights()
            }
        }
    }

    /// Draws each highlight as in-memory `.highlight` annotations (one per line) on the UI document.
    func syncHighlights() {
        guard let pdf = pdfView.document else { return }
        let current = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, drawn) in drawnHighlights where current[id] != drawn.highlight {
            for annotation in drawn.annotations { annotation.page?.removeAnnotation(annotation) }
            drawnHighlights[id] = nil
        }
        for h in highlights where drawnHighlights[h.id] == nil {
            guard let page = pdf.page(at: h.page), let range = validRange(h, on: page),
                  let selection = page.selection(for: range) else { continue }
            let annotations = Self.lineAnnotations(selection, on: page, color: h.color.color, contents: h.note)
            for annotation in annotations { page.addAnnotation(annotation) }
            drawnHighlights[h.id] = (h, annotations)
        }
    }

    /// One annotation per line of `selection` on `page`.
    static func lineAnnotations(_ selection: PDFSelection, on page: PDFPage, color: NSColor,
                                contents: String?) -> [PDFAnnotation] {
        selection.selectionsByLine().compactMap { line in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.contents = contents
            return annotation
        }
    }

    private func highlightID(at event: NSEvent) -> UUID? {
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false) else { return nil }
        let onPage = pdfView.convert(point, to: page)
        return drawnHighlights.first { entry in
            entry.value.annotations.contains { $0.page === page && $0.bounds.contains(onPage) }
        }?.key
    }

    /// Put above PDFView's own context menu: Ask Lectern / Highlight / Add Note… for selected text, or
    /// note, color and removal for a highlight under the pointer.
    private func contextMenuItems(for event: NSEvent) -> [NSMenuItem] {
        guard isReady else { return [] }
        if hasTextSelection, selectedText() != nil {
            let ask = NSMenuItem(title: "Ask Lectern", action: nil, keyEquivalent: "")
            ask.image = LecternMark.menuImage
            ask.submenu = NSMenu(title: "Ask Lectern")
            for action in SelectionAction.allCases {
                ask.submenu?.addItem(ActionMenuItem(action.title) { [weak self] in self?.ask(action) })
            }
            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            highlight.submenu = colorMenu("Highlight", current: nil) { [weak self] in self?.highlightSelection($0) }
            return [ask, highlight, ActionMenuItem("Add Note\u{2026}") { [weak self] in self?.addNoteToSelection() }]
        }
        if let id = highlightID(at: event), let h = highlightStore?.highlight(id) {
            let color = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
            color.submenu = colorMenu("Change Color", current: h.color) { [weak self] in self?.setHighlightColor($0, for: id) }
            return [ActionMenuItem(h.note == nil ? "Add Note\u{2026}" : "Edit Note\u{2026}") { [weak self] in self?.editNote(id) },
                    color,
                    ActionMenuItem("Remove Highlight") { [weak self] in self?.deleteHighlight(id) }]
        }
        return []
    }

    private func colorMenu(_ title: String, current: HighlightColor?, choose: @escaping (HighlightColor) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        for color in HighlightColor.allCases {
            let item = ActionMenuItem(color.title, image: color.swatch) { choose(color) }
            if color == current { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Citation passages

    /// A citation link: go to the page (recorded for Back), then find the claim's supporting passage and
    /// flash it. The flash is a temporary annotation, never the selection, and is removed after 2.5 s.
    func showPassage(_ request: PassageRequest) {
        guard let document, request.page >= 0, request.page < pageCount else { return }
        passageTask?.cancel()
        clearFlash()
        goToPage(request.page)
        guard let claim = request.claim?.trimmingCharacters(in: .whitespacesAndNewlines), !claim.isEmpty else { return }
        let index = request.page
        passageTask = Task { @MainActor [weak self] in
            let range = await PassageLocator.locate(claim: claim, page: index, in: document)
            guard let self, let range, !Task.isCancelled, !self.isClosed else { return }
            self.flashPassage(range, page: index)
        }
    }

    private func flashPassage(_ range: NSRange, page index: Int) {
        guard let page = pdfView.document?.page(at: index), range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= ((page.string ?? "") as NSString).length,
              let selection = page.selection(for: range) else { return }
        let bounds = selection.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else { return }
        clearFlash()
        scroll(to: bounds, on: page, index: index)
        flashAnnotations = Self.lineAnnotations(selection, on: page, color: Self.passageColor, contents: nil)
        for annotation in flashAnnotations { page.addAnnotation(annotation) }
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.clearFlash()
        }
    }

    private func clearFlash() {
        flashTask?.cancel()
        flashTask = nil
        for annotation in flashAnnotations { annotation.page?.removeAnnotation(annotation) }
        flashAnnotations = []
    }

    /// Orange: distinct from every highlight color.
    static var passageColor: NSColor { NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 1) }

    // MARK: Persistence

    private func restore(_ state: ViewerState) {
        restoring = true
        if let raw = state.displayMode, let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
            pdfView.displayMode = mode.pdfMode
        }
        if let visible = state.sidebarVisible { sidebarVisible = visible }
        if let raw = state.sidebarMode, let mode = SidebarMode(rawValue: raw), mode != .searchResults {
            sidebarMode = mode
        }
        if let chat = state.chatVisible { chatVisible = chat }
        switch state.zoom.flatMap(ZoomMode.init(rawValue:)) {
        case .custom:
            zoomMode = .custom
            pdfView.autoScales = false
            if let scale = state.scale, scale > 0 {
                pdfView.scaleFactor = min(max(CGFloat(scale), Self.minScale), Self.maxScale)
            }
        case .some(let mode):
            zoomMode = mode
            applyZoomMode()
        case nil:
            break
        }
        if let page = state.page, page > 0, page < pageCount {
            pendingRestorePage = page
            currentPageIndex = page
        } else {
            restoring = false
        }
    }

    /// The saved page is applied once PDFView has a window and a size (a large document isn't laid out
    /// before that, and an early go(to:) is lost).
    private func applyPendingRestore() {
        guard let page = pendingRestorePage, pdfView.window != nil,
              pdfView.bounds.width > 20, pdfView.bounds.height > 20 else { return }
        pendingRestorePage = nil
        DispatchQueue.main.async { [weak self] in self?.finishRestore(page) }
    }

    private func finishRestore(_ index: Int) {
        guard let pdf = pdfView.document, let page = pdf.page(at: index) else {
            restoring = false
            return
        }
        applyZoomMode()
        pdfView.go(to: page)
        // Verify; PDFView sometimes drops the first scroll while it lays out a long document.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let current = self.effectiveCurrentPage().map { pdf.index(for: $0) } ?? -1
            if current != index, self.restoreAttempts < 10 {
                self.restoreAttempts += 1
                self.finishRestore(index)
                return
            }
            self.restoring = false
            self.updateCurrentPage(current >= 0 ? current : index)
        }
    }

    /// What is saved: a search's results sidebar is temporary, so the sidebar from before it is saved.
    var viewerState: ViewerState {
        var visible = sidebarVisible
        var mode = sidebarMode
        if isSearching, let before = sidebarBeforeSearch {
            visible = before.visible
            mode = before.mode
        }
        if mode == .searchResults { mode = .thumbnails }
        return ViewerState(page: currentPageIndex,
                           zoom: zoomMode.rawValue,
                           scale: zoomMode == .custom ? Double(scaleFactor) : nil,
                           displayMode: displayMode.rawValue,
                           sidebarVisible: visible,
                           sidebarMode: mode.rawValue,
                           chatVisible: chatVisible)
    }

    private func scheduleSave() {
        guard isReady, !restoring, !isClosed else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let document, let store, persists, !isClosed, !restoring else { return }
        saveTask?.cancel()
        saveTask = nil
        store.saveViewer(viewerState, contentHash: document.contentHash)
    }
}

/// PDFView with hooks for Esc, resizing, layout and the context menu.
final class ReaderPDFView: PDFView {
    var onEscape: (() -> Bool)?
    var onResize: (() -> Void)?
    var onLayout: (() -> Void)?
    /// Items put at the top of the context menu (selection and highlight actions).
    var contextMenuItems: ((NSEvent) -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let items = contextMenuItems?(event), !items.isEmpty else { return menu }
        let result = menu ?? NSMenu()
        for (i, item) in (items + (result.items.isEmpty ? [] : [.separator()])).enumerated() {
            result.insertItem(item, at: i)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           onEscape?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// One table-of-contents entry (the tree is built once, on the main thread, when the Table of
/// Contents is first shown).
final class OutlineNode: Identifiable {
    let id: Int
    let title: String
    let pageIndex: Int?
    let destination: PDFDestination?
    let children: [OutlineNode]?

    private init(id: Int, title: String, pageIndex: Int?, destination: PDFDestination?, children: [OutlineNode]?) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.destination = destination
        self.children = children
    }

    static let maxEntries = 20_000
    static let maxDepth = 32

    /// An entry with a page, in reading order, with the ids of the entries above it.
    struct Entry {
        let id: Int
        let page: Int
        let ancestors: [Int]
    }

    /// Entries under `outline`, depth-first; `flat` collects the entries that have a page.
    static func children(of outline: PDFOutline, in pdf: PDFDocument, counter: inout Int,
                         flat: inout [Entry], ancestors: [Int]) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        guard ancestors.count < maxDepth else { return nodes }
        for i in 0..<outline.numberOfChildren {
            guard counter < maxEntries, let child = outline.child(at: i) else { break }
            counter += 1
            let id = counter
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            var pageIndex: Int?
            if let page = destination?.page {
                let index = pdf.index(for: page)
                if index >= 0 { pageIndex = index }
            }
            if let pageIndex { flat.append(Entry(id: id, page: pageIndex, ancestors: ancestors)) }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sub = child.numberOfChildren > 0
                ? children(of: child, in: pdf, counter: &counter, flat: &flat, ancestors: ancestors + [id]) : []
            nodes.append(OutlineNode(id: id, title: title.isEmpty ? "Untitled" : title, pageIndex: pageIndex,
                                     destination: destination, children: sub.isEmpty ? nil : sub))
        }
        return nodes
    }
}

/// Receives PDFDocument's asynchronous find callbacks (on the main thread) for a ReaderController.
private final class SearchDelegate: NSObject, PDFDocumentDelegate {
    weak var owner: ReaderController?

    init(owner: ReaderController) {
        self.owner = owner
    }

    func didMatchString(_ instance: PDFSelection) {
        MainActor.assumeIsolated { owner?.found(instance) }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        MainActor.assumeIsolated { owner?.findEnded() }
    }
}
