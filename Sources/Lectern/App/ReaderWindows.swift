import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Opens PDFs in reader windows and keeps the Open Recent list.
///
/// Lectern is a viewer, so there is no NSDocument: a document's autosave rewrote the user's PDF when
/// its window closed. A file's bytes are read once, mapped read-only, and nothing ever opens it for
/// writing.
@MainActor @Observable
final class ReaderWindowManager {
    static let shared = ReaderWindowManager()

    static let maxRecentFiles = 10
    private static let recentFilesKey = "recentFiles"

    /// Most recent first, at most `maxRecentFiles`, only files that still exist.
    private(set) var recentFiles: [URL] = []

    /// The viewer controller of the key reader window; the View, Go and Find menus act on it and are
    /// disabled while it is nil (no reader window is key).
    private(set) var activeReader: ReaderController?

    /// Open reader windows by canonical path (see `canonical(_:)`).
    @ObservationIgnored private var controllers: [String: ReaderWindowController] = [:]
    @ObservationIgnored private var openPanel: NSOpenPanel?
    @ObservationIgnored private weak var lastOpenedWindow: NSWindow?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keyMonitor: Any?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: Self.recentFilesKey) ?? []
        recentFiles = Self.cleaned(paths.map { URL(fileURLWithPath: $0) })
        if recentFiles.map(\.path) != paths { saveRecentFiles() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘= zooms in, like ⌘+ (View > Zoom In, whose "+" needs Shift on most layouts), as in Preview.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            guard flags == .command, event.charactersIgnoringModifiers == "=" else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { self?.zoomInFromKeyboard(windowNumber: windowNumber) ?? false }
            return handled ? nil : event
        }
    }

    private func zoomInFromKeyboard(windowNumber: Int) -> Bool {
        guard let reader = activeReader, reader.isReady,
              let window = NSApp.keyWindow, window.windowNumber == windowNumber, window.attachedSheet == nil,
              controllers.values.contains(where: { $0.window === window && $0.reader === reader })
        else { return false }
        reader.zoomIn()
        return true
    }

    var hasReaderWindows: Bool { !controllers.isEmpty }

    /// Identity of a file: standardized and symlink-resolved, so `/tmp/x.pdf` and `/private/tmp/x.pdf`
    /// (or a symlink to it) are the same window.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    // MARK: Opening

    /// Opens each file, or brings its window to the front when it is already open. Windows opened
    /// together cascade from one another.
    func open(_ urls: [URL]) {
        var anchor: NSWindow?
        for url in urls {
            if let window = open(url, cascadingFrom: anchor) { anchor = window }
        }
    }

    func open(_ url: URL) {
        _ = open(url, cascadingFrom: nil)
    }

    private func open(_ url: URL, cascadingFrom anchor: NSWindow?) -> NSWindow? {
        let fileURL = Self.canonical(url)
        if let existing = controller(for: fileURL) {
            existing.bringToFront()
            noteRecent(existing.fileURL)
            return existing.window
        }
        let data: Data
        do {
            // Read-only, mapped when the volume allows it; the file is never opened for writing.
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            forgetRecent(fileURL)
            presentOpenError(error, for: fileURL)
            return nil
        }
        let controller = ReaderWindowController(fileURL: fileURL, data: data,
                                                contentSize: Self.defaultContentSize()) { [weak self] closed in
            self?.windowClosed(closed)
        }
        controllers[fileURL.path] = controller
        place(controller.window, cascadingFrom: anchor)
        controller.window.makeKeyAndOrderFront(nil)
        lastOpenedWindow = controller.window
        noteRecent(fileURL)
        return controller.window
    }

    /// The window already showing this file: same canonical path, or the same file reached another
    /// way (a hard link, different letter case on a case-insensitive volume).
    private func controller(for fileURL: URL) -> ReaderWindowController? {
        if let byPath = controllers[fileURL.path] { return byPath }
        guard let id = ReaderWindowController.resourceIdentifier(of: fileURL) else { return nil }
        return controllers.values.first { $0.resourceIdentifier?.isEqual(id) == true }
    }

    private func windowClosed(_ controller: ReaderWindowController) {
        if controllers[controller.key] === controller {
            controllers.removeValue(forKey: controller.key)
        }
        readerResignedKey(controller.reader)
    }

    /// App quitting: windows aren't closed one by one, so save each reader's place now.
    func saveViewerStates() {
        for controller in controllers.values { controller.reader.saveNow() }
    }

    /// Another reader window already shows a PDF with these bytes.
    fileprivate func otherReaderShows(contentHash: String, besides reader: ReaderController) -> Bool {
        controllers.values.contains { $0.reader !== reader && $0.reader.document?.contentHash == contentHash }
    }

    fileprivate func readerBecameKey(_ reader: ReaderController) {
        if activeReader !== reader { activeReader = reader }
    }

    fileprivate func readerResignedKey(_ reader: ReaderController) {
        if activeReader === reader { activeReader = nil }
    }

    private func presentOpenError(_ error: Error, for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Lectern can\u{2019}t open \u{201C}\(url.lastPathComponent)\u{201D}."
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Window placement

    private static func defaultContentSize() -> NSSize {
        var size = NSSize(width: 1400, height: 900)
        if let visible = NSScreen.main?.visibleFrame {
            // Leave room for the title bar and a margin on small screens.
            size.width = min(size.width, visible.width - 40)
            size.height = min(size.height, visible.height - 80)
        }
        return size
    }

    /// Cascades from the window opened just before in the same batch, else the key reader window, else
    /// the last reader window opened; the first window is centered.
    private func place(_ window: NSWindow, cascadingFrom anchor: NSWindow?) {
        let reference = anchor
            ?? NSApp.keyWindow.flatMap { key in controllers.values.contains { $0.window === key } ? key : nil }
            ?? lastOpenedWindow.flatMap { $0.isVisible ? $0 : nil }
        guard let reference else {
            window.center()
            return
        }
        let topLeft = NSPoint(x: reference.frame.minX, y: reference.frame.maxY)
        // The first call puts the window at the reference's corner and returns the next cascade point.
        let shifted = window.cascadeTopLeft(from: topLeft)
        _ = window.cascadeTopLeft(from: shifted)
    }

    // MARK: Open panel

    /// Shows the Open panel (a single one; asking again brings it to the front).
    func showOpenPanel() {
        NSApp.activate()
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        openPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            if response == .OK { self.open(panel.urls) }
        }
    }

    /// At launch, like Preview: when nothing was opened, offer the Open panel.
    func showOpenPanelIfIdle() {
        guard controllers.isEmpty, openPanel == nil else { return }
        // A "can't open" alert for a file Finder sent: offer the panel once it is dismissed.
        if NSApp.modalWindow != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.showOpenPanelIfIdle()
            }
            return
        }
        // Something else (e.g. Settings) is already on screen.
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else { return }
        showOpenPanel()
    }

    // MARK: Recent files

    private func noteRecent(_ url: URL) {
        recentFiles = Self.cleaned([url] + recentFiles)
        saveRecentFiles()
        // The Dock menu reads the system's recent-documents list.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func forgetRecent(_ url: URL) {
        let path = url.path
        guard recentFiles.contains(where: { $0.path == path }) else { return }
        recentFiles.removeAll { $0.path == path }
        saveRecentFiles()
    }

    func clearRecentFiles() {
        recentFiles = []
        saveRecentFiles()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// Drops files that were deleted or moved since they were opened.
    func pruneRecentFiles() {
        let cleaned = Self.cleaned(recentFiles)
        guard cleaned != recentFiles else { return }
        recentFiles = cleaned
        saveRecentFiles()
    }

    /// Menu titles: the file name, plus its folder when two recent files share a name.
    func menuTitle(for url: URL) -> String {
        let name = url.lastPathComponent
        let clashes = recentFiles.filter { $0.lastPathComponent == name }.count > 1
        return clashes ? "\(name) \u{2014} \(url.deletingLastPathComponent().lastPathComponent)" : name
    }

    private func saveRecentFiles() {
        defaults.set(recentFiles.map(\.path), forKey: Self.recentFilesKey)
    }

    /// De-duplicated (first occurrence wins), existing files only, capped.
    private static func cleaned(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls where out.count < maxRecentFiles {
            let path = url.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            out.append(url)
        }
        return out
    }
}

/// One reader window: an AppKit window hosting `DocumentWindow`, with the reader toolbar. It owns the
/// window's ReaderController and ChatModel lifetimes and shuts the model down exactly once, when the
/// window closes.
@MainActor
private final class ReaderWindowController: NSObject, NSWindowDelegate {
    let fileURL: URL
    let key: String
    let resourceIdentifier: NSObject?
    let window: NSWindow
    let reader = ReaderController()
    private let toolbar: ReaderToolbar
    private var model: ChatModel?
    private var isClosed = false
    private let onClose: (ReaderWindowController) -> Void

    init(fileURL: URL, data: Data, contentSize: NSSize, onClose: @escaping (ReaderWindowController) -> Void) {
        self.fileURL = fileURL
        key = fileURL.path
        resourceIdentifier = Self.resourceIdentifier(of: fileURL)
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        toolbar = ReaderToolbar(controller: reader)
        super.init()

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "Lectern.reader"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified

        let root = DocumentWindow(data: data, fileURL: fileURL, reader: reader) { [weak self] model in
            self?.adopt(model)
        }
        let hosting = NSHostingController(rootView: root)
        // The window keeps its own size; SwiftUI only sets the minimum (provided every DocumentWindow
        // state has an unbounded max size, else the window shrinks to fit). The title and the toolbar
        // (ReaderToolbar, plain AppKit) belong to the window, so SwiftUI bridges neither.
        hosting.sizingOptions = [.minSize]
        hosting.sceneBridgingOptions = []
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        window.delegate = self
    }

    static func resourceIdentifier(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// DocumentWindow made its ChatModel (after loading, or after the password was accepted).
    private func adopt(_ model: ChatModel) {
        // An unlock that finished after the window closed.
        guard !isClosed else {
            model.shutdown()
            return
        }
        self.model = model
        let secondary = ReaderWindowManager.shared.otherReaderShows(contentHash: model.document.contentHash,
                                                                    besides: reader)
        reader.attach(model.document, store: AppServices.shared.sessions, persists: !secondary)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ReaderWindowManager.shared.readerBecameKey(reader)
    }

    func windowDidResignKey(_ notification: Notification) {
        ReaderWindowManager.shared.readerResignedKey(reader)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        reader.close()
        model?.shutdown()
        model = nil
        window.delegate = nil
        onClose(self)
        // Tear the SwiftUI hierarchy down once AppKit has finished closing the window; this releases
        // the view's ChatModel and the closure that points back here.
        Task { @MainActor [self] in
            self.window.contentViewController = nil
        }
    }
}
