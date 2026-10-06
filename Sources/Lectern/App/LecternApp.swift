import AppKit
import SwiftUI
import LecternCore

/// Reader windows are plain AppKit windows managed by ReaderWindowManager, not a DocumentGroup: an
/// NSDocument counts edits in its window (typing in the chat registered undo) and autosaves on close,
/// which rewrote the user's PDF. Lectern never writes to a PDF.
@main
struct LecternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            ReaderCommands(windows: ReaderWindowManager.shared)
        }
    }
}

/// File menu: Open…, Open Recent, Close and Print… (there is nothing to save); Edit > Find; the
/// viewer's View items; the Go menu. Viewer commands act on the key reader window's ReaderController
/// and are disabled when no reader window is key.
struct ReaderCommands: Commands {
    let windows: ReaderWindowManager

    /// The key reader window's controller, once its document is showing.
    private var reader: ReaderController? {
        guard let reader = windows.activeReader, reader.isReady else { return nil }
        return reader
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") { windows.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                if !windows.recentFiles.isEmpty {
                    ForEach(windows.recentFiles, id: \.self) { url in
                        Button(windows.menuTitle(for: url)) { windows.open(url) }
                    }
                    Divider()
                }
                Button("Clear Menu") { windows.clearRecentFiles() }
                    .disabled(windows.recentFiles.isEmpty)
            }
        }
        // Replacing .saveItem drops Save/Duplicate/Rename/Revert, and also the standard Close.
        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        // Prints the PDF itself (PDFDocument's print operation), never the view.
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { reader?.printDocument() }
                .keyboardShortcut("p")
                .disabled(!(reader?.canPrint ?? false))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find\u{2026}") { reader?.focusSearch() }
                    .keyboardShortcut("f")
                Button("Find Next") { reader?.findNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { reader?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { reader?.useSelectionForFind() }
                    .keyboardShortcut("e")
            }
            .disabled(reader == nil)
        }
        ViewerCommands(reader: reader)
        GoCommands(reader: reader)
    }
}

/// View menu: sidebar, chat, zoom and display mode.
private struct ViewerCommands: Commands {
    let reader: ReaderController?

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(reader?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { reader?.toggleSidebar() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(reader == nil)
            Toggle("Thumbnails", isOn: sidebarBinding(.thumbnails))
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(reader == nil)
            Toggle("Table of Contents", isOn: sidebarBinding(.contents))
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(!(reader?.hasOutline ?? false))
            Divider()
            Button(reader?.chatVisible == false ? "Show Chat" : "Hide Chat") { reader?.toggleChat() }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(reader == nil)
            Divider()
            Button("Actual Size") { reader?.actualSize() }
                .keyboardShortcut("0")
                .disabled(reader == nil)
            Button("Zoom to Fit") { reader?.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(reader == nil)
            Button("Zoom to Width") { reader?.zoomToWidth() }
                .disabled(reader == nil)
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!(reader?.canZoomIn ?? false))
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!(reader?.canZoomOut ?? false))
            Divider()
            ForEach(ReaderController.DisplayMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { reader?.displayMode == mode },
                    set: { _ in reader?.setDisplayMode(mode) }
                ))
                .disabled(reader == nil)
            }
            Divider()
            AppearanceMenu(settings: AppServices.shared.settings)
            Divider()
        }
    }

    private func sidebarBinding(_ mode: ReaderController.SidebarMode) -> Binding<Bool> {
        Binding(
            get: { reader?.sidebarVisible == true && reader?.sidebarMode == mode },
            set: { _ in reader?.showSidebar(mode) }
        )
    }
}

/// View > Appearance: works with or without a reader window.
private struct AppearanceMenu: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Menu("Appearance") {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Dark Pages", isOn: $settings.darkPages)
        }
    }
}

/// Go menu: page navigation and history.
private struct GoCommands: Commands {
    let reader: ReaderController?

    var body: some Commands {
        CommandMenu("Go") {
            Button("Previous Page") { reader?.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToPreviousPage ?? false))
            Button("Next Page") { reader?.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToNextPage ?? false))
            Button("First Page") { reader?.goToFirstPage() }
                .keyboardShortcut(.home, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToPreviousPage ?? false))
            Button("Last Page") { reader?.goToLastPage() }
                .keyboardShortcut(.end, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToNextPage ?? false))
            Divider()
            Button("Back") { reader?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(reader?.canGoBack ?? false))
            Button("Forward") { reader?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(reader?.canGoForward ?? false))
            Divider()
            Button("Go to Page\u{2026}") { reader?.focusPageField() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(reader == nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lets `swift run` (no app bundle) show a Dock icon and menu bar like the bundled app.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.settings.applyAppearance()
        AppServices.shared.start()
        // Finder's open-document events can arrive just after launch. Only when none brought a window,
        // show the Open panel, as Preview does.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            ReaderWindowManager.shared.showOpenPanelIfIdle()
        }
    }

    /// Finder, `open -a`, the Dock icon and the Dock's recent-documents menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        ReaderWindowManager.shared.open(urls.filter(ReaderWindowManager.isPDF))
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon clicked: with no windows at all, offer the Open panel. Minimized reader windows are
    /// left to AppKit, which brings one back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || ReaderWindowManager.shared.hasReaderWindows { return true }
        ReaderWindowManager.shared.showOpenPanel()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ReaderWindowManager.shared.pruneRecentFiles()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReaderWindowManager.shared.saveViewerStates()
        AppServices.shared.shutdown()
    }
}
