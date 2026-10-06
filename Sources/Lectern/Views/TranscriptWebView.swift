import AppKit
import LecternCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The chat transcript, rendered by web/chat.html (Markdown, KaTeX, page links). Messages are
/// pushed with `Lectern.sync(...)`; the page posts back citation clicks, copy and CSV-save requests.
@MainActor
struct TranscriptWebView: NSViewRepresentable {
    let messages: [ChatMessage]
    /// Default name for saved tables: "<title> - table.csv".
    let documentTitle: String
    /// Chat Text Size in CSS px: the page's `--chat-font-size`, which every text size there scales from.
    let textSize: CGFloat
    /// 1-based page, and the sentence that carried the citation.
    let onGoTo: (Int, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakScriptMessageProxy(coordinator), name: Coordinator.handlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        // Opaque on purpose: a transparent WKWebView (drawsBackground = false) left stale pixels behind
        // after scrolling and re-layout in testing. The page paints the system text background itself,
        // and the view stays hidden until it has loaded so dark mode never flashes white.
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.isHidden = true
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif

        coordinator.onGoTo = onGoTo
        coordinator.documentTitle = documentTitle
        coordinator.textSize = textSize
        coordinator.attach(webView)
        coordinator.push(messages)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onGoTo = onGoTo
        context.coordinator.documentTitle = documentTitle
        context.coordinator.setTextSize(textSize)
        context.coordinator.push(messages)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

extension TranscriptWebView {
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handlerName = "lectern"

        /// Contents/Resources/web in the .app (scripts/build-app.sh copies it there). There is no SwiftPM
        /// resource bundle: its generated accessor would embed the absolute build path in the binary.
        static var pageURL: URL? {
            Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "web") ?? sourceTreePageURL
        }

        /// Unbundled dev runs (`swift run Lectern`): the page in the source tree, found by walking up from
        /// the executable (`<repo>/.build/<triple>/debug/Lectern`). Never used inside an .app bundle.
        private static var sourceTreePageURL: URL? {
            guard Bundle.main.bundleURL.pathExtension != "app",
                  var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
            else { return nil }
            for _ in 0..<6 {
                let page = dir.appendingPathComponent("Sources/Lectern/Resources/web/chat.html")
                if FileManager.default.fileExists(atPath: page.path) { return page }
                dir.deleteLastPathComponent()
            }
            return nil
        }

        var onGoTo: (Int, String?) -> Void = { _, _ in }
        var documentTitle = ""
        var textSize: CGFloat = ChatTextSize.medium.points

        private weak var webView: WKWebView?
        private var loadedURL: URL?
        private var pageReady = false

        private var latest: [ChatMessage] = []
        private var hasUnsent = false
        /// What the page currently shows, so unchanged messages go over as `{id}` stubs.
        private var sent: [UUID: WireMessage] = [:]
        private var sentOrder: [UUID] = []
        private var flushScheduled = false
        private var inFlight = false
        private var failedSyncs = 0

        func attach(_ webView: WKWebView) {
            self.webView = webView
            load()
        }

        func detach() {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            webView?.navigationDelegate = nil
            webView = nil
        }

        private func load() {
            guard let webView else { return }
            pageReady = false
            guard let url = Self.pageURL else {
                webView.loadHTMLString(
                    "<p style=\"font: 13px -apple-system; color: gray; padding: 12px\">The transcript page is missing from the app bundle.</p>",
                    baseURL: nil)
                return
            }
            loadedURL = url
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        // MARK: Pushing state

        /// Applied at once to a loaded page; a page still loading gets it before it is shown.
        func setTextSize(_ size: CGFloat) {
            guard size != textSize else { return }
            textSize = size
            guard pageReady, let webView else { return }
            webView.evaluateJavaScript(Self.textSizeScript(size))
        }

        private static func textSizeScript(_ size: CGFloat) -> String {
            "Lectern.setTextSize(\(Int(size.rounded())))"
        }

        func push(_ messages: [ChatMessage]) {
            latest = messages
            hasUnsent = true
            scheduleFlush()
        }

        /// Coalesces bursts of SwiftUI updates (one per streamed delta) into one evaluateJavaScript,
        /// and keeps at most one in flight.
        private func scheduleFlush() {
            guard !flushScheduled else { return }
            flushScheduled = true
            Task { @MainActor [weak self] in self?.flush() }
        }

        private func flush() {
            flushScheduled = false
            guard pageReady, !inFlight, hasUnsent, let webView else { return }
            hasUnsent = false

            var items: [WireItem] = []
            items.reserveCapacity(latest.count)
            var nextSent: [UUID: WireMessage] = [:]
            var changed = false
            for message in latest {
                let wire = WireMessage(message)
                if sent[message.id] == wire {
                    items.append(.unchanged(id: wire.id))
                } else {
                    items.append(.full(wire))
                    changed = true
                }
                nextSent[message.id] = wire
            }
            let order = latest.map(\.id)
            guard changed || order != sentOrder else { return }
            guard let data = try? JSONEncoder().encode(items),
                  let json = String(data: data, encoding: .utf8) else { return }

            sent = nextSent
            sentOrder = order
            inFlight = true
            webView.evaluateJavaScript("Lectern.sync(\(json))") { [weak self] _, error in
                guard let self else { return }
                self.inFlight = false
                if error != nil {
                    // Page state is unknown: resend everything, but don't spin on a broken page.
                    self.sent = [:]
                    self.sentOrder = []
                    self.failedSyncs += 1
                    if self.failedSyncs <= 3 { self.hasUnsent = true }
                } else {
                    self.failedSyncs = 0
                }
                if self.hasUnsent { self.scheduleFlush() }
            }
        }

        private func resetPageState() {
            sent = [:]
            sentOrder = []
            failedSyncs = 0
            hasUnsent = true
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "goto":
                if let page = (body["page"] as? NSNumber)?.intValue, page >= 1 {
                    onGoTo(page, (body["claim"] as? String).map { String($0.prefix(2_000)) })
                }
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "open":
                if let string = body["url"] as? String, let url = URL(string: string), Self.isExternal(url) {
                    NSWorkspace.shared.open(url)
                }
            case "saveCSV":
                if let csv = body["csv"] as? String {
                    saveCSV(csv, name: body["name"] as? String ?? "table")
                }
            case "resync":
                resetPageState()
                scheduleFlush()
            default:
                break
            }
        }

        /// Save panel for a table from an answer. UTF-8 with a BOM so Excel reads CJK text correctly.
        private func saveCSV(_ csv: String, name: String) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.allowsOtherFileTypes = false
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = Self.fileName(title: documentTitle, name: name)
            let write: (NSApplication.ModalResponse) -> Void = { response in
                // The panel only offers .csv names; the extension check keeps a PDF from ever being the target.
                guard response == .OK, let url = panel.url, url.pathExtension.lowercased() == "csv" else { return }
                var data = Data([0xEF, 0xBB, 0xBF])
                data.append(Data(csv.utf8))
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            if let window = webView?.window {
                panel.beginSheetModal(for: window, completionHandler: write)
            } else {
                write(panel.runModal())
            }
        }

        static func fileName(title: String, name: String) -> String {
            let clean = { (s: String) in
                s.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
                    .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let base = clean(String(title.prefix(120)))
            let suffix = clean(String(name.prefix(60)))
            let stem = [base, suffix.isEmpty ? "table" : suffix].filter { !$0.isEmpty }.joined(separator: " - ")
            return stem + ".csv"
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            if url.isFileURL, let loadedURL, url.standardizedFileURL.path == loadedURL.standardizedFileURL.path {
                return decisionHandler(.allow)
            }
            if url.absoluteString == "about:blank", loadedURL == nil {
                return decisionHandler(.allow)  // the "page missing" fallback
            }
            // The transcript never navigates; links from answers open in the default browser.
            if navigationAction.navigationType == .linkActivated, Self.isExternal(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pageReady = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            resetPageState()
            // Shown once the text size applies, so the page never appears at the default size first.
            webView.evaluateJavaScript(Self.textSizeScript(textSize)) { [weak webView] _, _ in
                webView?.isHidden = false
            }
            scheduleFlush()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.isHidden = false
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            load()
        }

        private static func isExternal(_ url: URL) -> Bool {
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        }
    }

    /// Only what chat.js renders.
    struct WireMessage: Encodable, Equatable {
        let id: String
        let role: String
        let provider: String
        let model: String?
        let text: String
        let status: String
        let errorText: String?
        /// Citation badges, by ordinal.
        let checks: [WireCheck]?

        init(_ message: ChatMessage) {
            id = message.id.uuidString
            role = message.role.rawValue
            provider = message.provider.displayName
            model = message.model
            text = message.text
            status = message.status.rawValue
            errorText = message.errorText
            checks = message.citationChecks.map { $0.map(WireCheck.init) }
        }
    }

    struct WireCheck: Encodable, Equatable {
        let ordinal: Int
        let pages: [Int]
        let status: String
        let missing: [String]

        init(_ check: CitationCheck) {
            ordinal = check.ordinal
            pages = check.pages
            status = check.status.rawValue
            missing = check.missing
        }
    }

    enum WireItem: Encodable {
        case full(WireMessage)
        case unchanged(id: String)

        private enum Keys: String, CodingKey { case id }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .full(let message):
                try message.encode(to: encoder)
            case .unchanged(let id):
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(id, forKey: .id)
            }
        }
    }
}

/// WKUserContentController retains its handlers; this proxy keeps it from retaining the coordinator.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
