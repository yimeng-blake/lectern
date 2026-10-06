import AppKit
import Observation

/// The reader window's toolbar (AppKit, so it lives in the window's title bar like Preview's):
/// sidebar toggle · page box "12 of 340" · zoom − / + · scale menu · display-mode menu · search ·
/// chat toggle. It mirrors a ReaderController and sends it the user's actions.
@MainActor
final class ReaderToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate, NSToolbarItemValidation, NSMenuDelegate {
    private enum ID {
        static let sidebar = NSToolbarItem.Identifier("lectern.sidebar")
        static let page = NSToolbarItem.Identifier("lectern.page")
        static let zoom = NSToolbarItem.Identifier("lectern.zoom")
        static let scale = NSToolbarItem.Identifier("lectern.scale")
        static let display = NSToolbarItem.Identifier("lectern.display")
        static let search = NSToolbarItem.Identifier("lectern.search")
        static let chat = NSToolbarItem.Identifier("lectern.chat")
        static let appearance = NSToolbarItem.Identifier("lectern.appearance")
    }

    let toolbar: NSToolbar
    private let controller: ReaderController

    private let pageField = NSTextField()
    private let pageCountLabel = NSTextField(labelWithString: "")
    private let zoomControl: NSSegmentedControl
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = NSSearchField()
    private let counterLabel = NSTextField(labelWithString: "")
    private var displayItem: NSMenuToolbarItem?
    private let displayMenu = NSMenu()
    private let appearanceMenu = NSMenu()
    private var scaleMenuItems: [ReaderController.ZoomMode: NSMenuItem] = [:]
    private var actualSizeItem: NSMenuItem?
    private var displayMenuItems: [ReaderController.DisplayMode: NSMenuItem] = [:]

    init(controller: ReaderController) {
        self.controller = controller
        toolbar = NSToolbar(identifier: "Lectern.reader")
        zoomControl = NSSegmentedControl(
            images: [Self.symbol("minus.magnifyingglass", "Zoom Out"), Self.symbol("plus.magnifyingglass", "Zoom In")],
            trackingMode: .momentary, target: nil, action: nil)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        configureControls()
        controller.searchField = searchField
        controller.pageField = pageField
        observe()
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: description)
            ?? NSImage()
    }

    // MARK: Controls

    private func configureControls() {
        pageField.alignment = .center
        pageField.bezelStyle = .roundedBezel
        pageField.usesSingleLineMode = true
        pageField.cell?.isScrollable = true
        pageField.lineBreakMode = .byTruncatingTail
        pageField.delegate = self
        pageField.placeholderString = "–"
        pageField.toolTip = "Page number or label — press Return to go there (\u{2325}\u{2318}G)"
        pageField.setAccessibilityLabel("Page")
        pageField.setAccessibilityIdentifier("pageField")
        pageField.translatesAutoresizingMaskIntoConstraints = false
        pageField.widthAnchor.constraint(equalToConstant: 58).isActive = true

        pageCountLabel.textColor = .secondaryLabelColor
        pageCountLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        pageCountLabel.lineBreakMode = .byClipping
        pageCountLabel.setAccessibilityIdentifier("pageCount")
        pageCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        zoomControl.target = self
        zoomControl.action = #selector(zoomClicked(_:))
        zoomControl.setToolTip("Zoom Out (\u{2318}\u{2212})", forSegment: 0)
        zoomControl.setToolTip("Zoom In (\u{2318}+)", forSegment: 1)
        zoomControl.setAccessibilityLabel("Zoom")
        zoomControl.segmentStyle = .separated

        let scaleMenu = scalePopup.menu ?? NSMenu()
        scaleMenu.autoenablesItems = false
        scaleMenu.removeAllItems()
        scaleMenu.addItem(withTitle: "100%", action: nil, keyEquivalent: "")
        let actual = scaleMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "")
        actual.target = self
        actualSizeItem = actual
        let fit = scaleMenu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFit(_:)), keyEquivalent: "")
        fit.target = self
        let width = scaleMenu.addItem(withTitle: "Zoom to Width", action: #selector(zoomToWidth(_:)), keyEquivalent: "")
        width.target = self
        scaleMenuItems = [.fitPage: fit, .fitWidth: width]
        scalePopup.menu = scaleMenu
        scalePopup.toolTip = "Scale"
        scalePopup.setAccessibilityLabel("Scale")
        scalePopup.setAccessibilityIdentifier("scaleMenu")
        scalePopup.translatesAutoresizingMaskIntoConstraints = false
        scalePopup.widthAnchor.constraint(equalToConstant: 78).isActive = true

        for mode in ReaderController.DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(displayModeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            displayMenu.addItem(item)
            displayMenuItems[mode] = item
        }

        for appearance in AppAppearance.allCases {
            let item = NSMenuItem(title: appearance.title, action: #selector(appearanceChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
            appearanceMenu.addItem(item)
        }
        appearanceMenu.addItem(.separator())
        let darkPages = NSMenuItem(title: "Dark Pages", action: #selector(toggleDarkPages(_:)), keyEquivalent: "")
        darkPages.target = self
        darkPages.toolTip = "Show pages with inverted colors for reading at night. The PDF itself does not change."
        appearanceMenu.addItem(darkPages)
        appearanceMenu.delegate = self

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.toolTip = "Search the PDF (\u{2318}F) — Return / \u{21E7}Return for the next / previous match, Esc to clear"
        searchField.setAccessibilityLabel("Search PDF")
        searchField.setAccessibilityIdentifier("searchField")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 210)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        counterLabel.textColor = .secondaryLabelColor
        counterLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counterLabel.alignment = .right
        counterLabel.lineBreakMode = .byClipping
        counterLabel.setAccessibilityIdentifier("searchCounter")
        counterLabel.setAccessibilityLabel("Search results")
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        counterLabel.isHidden = true
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.sidebar, ID.page, ID.zoom, ID.scale, ID.display, ID.appearance, .flexibleSpace, ID.search, ID.chat]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.sidebar:
            return button(id, symbol: "sidebar.left", label: "Sidebar",
                          tip: "Show or hide the sidebar (\u{2325}\u{2318}1)", action: #selector(toggleSidebar(_:)))
        case ID.chat:
            return button(id, symbol: "sidebar.right", label: "Chat",
                          tip: "Show or hide the chat (\u{2303}\u{2318}C)", action: #selector(toggleChat(_:)))
        case ID.page:
            let stack = NSStackView(views: [pageField, pageCountLabel])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .firstBaseline
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Page"
            item.paletteLabel = "Page"
            item.visibilityPriority = .high
            item.menuFormRepresentation = NSMenuItem(title: "Go to Page\u{2026}", action: #selector(goToPageMenu(_:)), keyEquivalent: "")
            item.menuFormRepresentation?.target = self
            return item
        case ID.zoom:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = zoomControl
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
            return item
        case ID.scale:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = scalePopup
            item.label = "Scale"
            item.paletteLabel = "Scale"
            return item
        case ID.display:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = displayMenu
            item.image = Self.symbol("rectangle.portrait.on.rectangle.portrait", "Display Mode")
            item.label = "Display"
            item.paletteLabel = "Display Mode"
            item.toolTip = "Single page, continuous scrolling, two pages"
            item.showsIndicator = true
            displayItem = item
            return item
        case ID.appearance:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = appearanceMenu
            item.image = Self.symbol("circle.lefthalf.filled", "Appearance")
            item.label = "Appearance"
            item.paletteLabel = "Appearance"
            item.toolTip = "Light, Dark or System appearance, and Dark Pages"
            item.showsIndicator = true
            return item
        case ID.search:
            let stack = NSStackView(views: [counterLabel, searchField])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Search"
            item.paletteLabel = "Search"
            item.visibilityPriority = .high
            item.menuFormRepresentation = NSMenuItem(title: "Find\u{2026}", action: #selector(findMenu(_:)), keyEquivalent: "")
            item.menuFormRepresentation?.target = self
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String,
                        action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = Self.symbol(symbol, label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        controller.isReady
    }

    // MARK: Actions

    @objc private func toggleSidebar(_ sender: Any?) { controller.toggleSidebar() }
    @objc private func toggleChat(_ sender: Any?) { controller.toggleChat() }
    @objc private func goToPageMenu(_ sender: Any?) { controller.focusPageField() }
    @objc private func findMenu(_ sender: Any?) { controller.focusSearch() }
    @objc private func actualSize(_ sender: Any?) { controller.actualSize() }
    @objc private func zoomToFit(_ sender: Any?) { controller.zoomToFit() }
    @objc private func zoomToWidth(_ sender: Any?) { controller.zoomToWidth() }

    @objc private func appearanceChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let appearance = AppAppearance(rawValue: raw) else { return }
        AppServices.shared.settings.appearance = appearance
    }

    @objc private func toggleDarkPages(_ sender: Any?) {
        AppServices.shared.settings.darkPages.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === appearanceMenu else { return }
        let settings = AppServices.shared.settings
        for item in menu.items {
            if let raw = item.representedObject as? String {
                item.state = raw == settings.appearance.rawValue ? .on : .off
            } else if item.action == #selector(toggleDarkPages(_:)) {
                item.state = settings.darkPages ? .on : .off
            }
        }
    }

    @objc private func zoomClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { controller.zoomOut() } else { controller.zoomIn() }
    }

    @objc private func displayModeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ReaderController.DisplayMode(rawValue: raw) else { return }
        controller.setDisplayMode(mode)
    }

    /// The field's clear button (and typing) sends this.
    @objc private func searchFieldAction(_ sender: NSSearchField) {
        controller.searchTextChanged(sender.stringValue)
    }

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        controller.searchTextChanged(searchField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // The page box shows the current page again when it loses focus without Return.
        if (obj.object as? NSTextField) === pageField { render() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === pageField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                commitPageField()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                pageField.stringValue = controller.currentPageLabel
                controller.focusPDF()
                return true
            default:
                return false
            }
        }
        if control === searchField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                controller.searchSubmitted(searchField.stringValue, backwards: shift)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Clears the search (if any) and hands the keyboard back to the document.
                controller.endSearch()
                controller.focusPDF()
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Return in the page box: a page number or label goes there; anything else beeps and reverts.
    private func commitPageField() {
        if controller.goToPage(text: pageField.stringValue) {
            pageField.stringValue = controller.currentPageLabel
            controller.focusPDF()
        } else {
            NSSound.beep()
            pageField.stringValue = controller.currentPageLabel
            pageField.currentEditor()?.selectAll(nil)
        }
    }

    // MARK: Mirroring the controller

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    private func render() {
        let c = controller
        let ready = c.isReady

        pageField.isEnabled = ready
        if pageField.currentEditor() == nil {
            let label = ready ? c.currentPageLabel : ""
            if pageField.stringValue != label { pageField.stringValue = label }
        }
        if pageCountLabel.stringValue != c.pageCountText { pageCountLabel.stringValue = c.pageCountText }

        zoomControl.isEnabled = ready
        zoomControl.setEnabled(c.canZoomOut, forSegment: 0)
        zoomControl.setEnabled(c.canZoomIn, forSegment: 1)

        scalePopup.isEnabled = ready
        let percent = "\(Int((c.scaleFactor * 100).rounded()))%"
        if let title = scalePopup.item(at: 0), title.title != percent {
            title.title = percent
            scalePopup.setAccessibilityValue(percent)
        }
        scaleMenuItems[.fitPage]?.state = c.zoomMode == .fitPage ? .on : .off
        scaleMenuItems[.fitWidth]?.state = c.zoomMode == .fitWidth ? .on : .off
        actualSizeItem?.state = c.zoomMode == .custom && abs(c.scaleFactor - 1) < 0.005 ? .on : .off

        for (mode, item) in displayMenuItems {
            item.state = mode == c.displayMode ? .on : .off
            item.isEnabled = ready
        }

        searchField.isEnabled = ready
        if searchField.currentEditor() == nil, searchField.stringValue != c.searchText {
            searchField.stringValue = c.searchText
        }
        let counter = c.searchCounterText
        if counterLabel.stringValue != counter { counterLabel.stringValue = counter }
        counterLabel.isHidden = counter.isEmpty
    }
}
