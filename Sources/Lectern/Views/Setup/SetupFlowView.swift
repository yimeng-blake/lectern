import AppKit
import LecternCore
import SwiftUI

/// The short inline flow of an open card: one plain sentence for where things stand, a progress line
/// while something runs, and the button for the next step. Everything follows the services' state, so
/// the flow is the same in the setup window and in Settings > Accounts.
@MainActor
struct SetupFlowView: View {
    let provider: Provider
    let model: SetupModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            switch provider {
            case .claude: ClaudeFlow(model: model, compact: compact)
            case .codex: ChatGPTFlow(model: model, compact: compact)
            case .grok: GrokFlow(model: model, compact: compact)
            case .local: LocalFlow(model: model, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(compact ? .callout : .body)
    }
}

// MARK: - Building blocks

enum FlowTone { case info, progress, success, problem }

/// One sentence with an icon that says how it is going. Only the first line of a message shows (an
/// installer's error carries the end of its log); all of it is in the tooltip and can be selected.
@MainActor
struct FlowLine: View {
    let tone: FlowTone
    let text: String

    init(_ tone: FlowTone, _ text: String) {
        self.tone = tone
        self.text = text
    }

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 16)
            Text(firstLine)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .help(firstLine == text ? "" : text)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch tone {
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .progress:
            ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// A smaller, secondary sentence under a FlowLine (aligned with its text).
@MainActor
struct FlowNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 24)
    }
}

/// The flow's buttons: the main one first, then the others.
@MainActor
struct FlowButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, 24)
    }
}

/// The main button of a flow step.
@MainActor
struct FlowMainButton: View {
    let title: String
    var compact = false
    let action: () -> Void

    init(_ title: String, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(SetupProminentButtonStyle(large: !compact))
    }
}

/// A plain text button for a second choice, e.g. "Use a device code".
@MainActor
struct FlowLinkButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
    }
}

/// Sign-in in progress (browser or device code), for ChatGPT and Grok.
@MainActor
struct BrowserSignInProgress: View {
    let progress: LoginProgress
    let compact: Bool
    let cancel: () -> Void
    @State private var copied = false

    var body: some View {
        if let code = progress.userCode, !code.isEmpty {
            FlowLine(.progress, "Enter this code on the sign-in page.")
            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: compact ? 20 : 26, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code: \(code.map(String.init).joined(separator: " "))")
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
            }
            .padding(.leading, 24)
        } else if progress.message.isEmpty {
            FlowLine(.progress, "Waiting for the browser…")
            FlowNote("Finish signing in in your browser, then come back here.")
        } else {
            FlowLine(.progress, progress.message)
        }
        FlowButtons {
            if let url = progress.url {
                Link(progress.userCode == nil ? "Open the sign-in page again" : "Open the sign-in page",
                     destination: url)
            }
            Button("Cancel", action: cancel)
        }
    }
}

/// "Signed in as …" plus the Use button (or "In use").
@MainActor
struct SignedInStep: View {
    let provider: Provider
    let account: String
    let model: SetupModel
    let compact: Bool

    var body: some View {
        FlowLine(.success, account.isEmpty ? "You're signed in. \(provider.displayName) is ready."
                                           : "Signed in as \(account).")
        UseStep(provider: provider, model: model, compact: compact)
    }
}

/// "Use <provider>" for new conversations, or a note that they already use it.
@MainActor
struct UseStep: View {
    let provider: Provider
    let model: SetupModel
    let compact: Bool

    var body: some View {
        if !model.isInUse(provider) {
            FlowButtons {
                FlowMainButton("Use \(provider.displayName)", compact: compact) { model.use(provider) }
            }
        } else if !compact {
            FlowNote("New conversations use \(provider.displayName).")
        }
    }
}

// MARK: - Claude

@MainActor
private struct ClaudeFlow: View {
    let model: SetupModel
    let compact: Bool
    private var service: ClaudeService { model.app.claude }

    var body: some View {
        if case .running(let message) = service.setupState {
            FlowLine(.progress, message.isEmpty ? "Setting up Claude…" : message)
            FlowNote("This takes about a minute.")
        } else if service.installIssue != nil {
            if case .failed(let error) = service.setupState {
                FlowLine(.problem, error)
                FlowButtons { FlowMainButton("Try again", compact: compact) { model.install(.claude) } }
            } else {
                FlowLine(.info, "Lectern installs Claude Code, Claude's official app, from claude.ai. "
                         + "It takes about a minute.")
                FlowButtons { FlowMainButton("Set up Claude", compact: compact) { model.install(.claude) } }
            }
        } else {
            if case .done = service.setupState, !service.authState.isSignedIn {
                FlowLine(.success, "Claude is set up.")
            }
            switch service.authState {
            case .signedIn(let account):
                SignedInStep(provider: .claude, account: account, model: model, compact: compact)
            case .signedOut(let reason):
                FlowLine(.info, reason.isEmpty ? "Log in with your Claude account." : reason)
                FlowNote("Terminal opens with Claude's own sign-in. Follow the steps there, then come back here.")
                FlowButtons {
                    FlowMainButton("Log in", compact: compact) { model.signIn(.claude) }
                    Button("Check again") { model.checkAgain(.claude) }
                }
            case .loggingIn(let progress):
                FlowLine(.progress, progress.message.isEmpty ? "Waiting for Terminal…" : progress.message)
                FlowNote("Lectern finds the new sign-in by itself.")
                FlowButtons { Button("Cancel") { model.cancel(.claude) } }
            case .failed(let message):
                FlowLine(.problem, message)
                FlowButtons { FlowMainButton("Try again", compact: compact) { model.checkAgain(.claude) } }
            case .checking, .unknown:
                FlowLine(.progress, "Checking…")
            }
        }
    }
}

// MARK: - ChatGPT

@MainActor
private struct ChatGPTFlow: View {
    let model: SetupModel
    let compact: Bool
    private var service: CodexService { model.app.codex }

    var body: some View {
        if service.installIssue != nil {
            FlowLine(.info, "ChatGPT works through the ChatGPT app for Mac. Get the app, then come back here.")
            FlowButtons {
                FlowMainButton("Get the ChatGPT app", compact: compact) { model.getChatGPTApp() }
                Button("Check again") { model.checkAgain(.codex) }
            }
        } else {
            switch service.authState {
            case .signedIn(let account):
                SignedInStep(provider: .codex, account: account, model: model, compact: compact)
            case .signedOut:
                FlowLine(.info, "Sign in with your ChatGPT account in your browser.")
                FlowButtons {
                    FlowMainButton("Sign in with ChatGPT", compact: compact) { model.signIn(.codex) }
                    FlowLinkButton("Use a device code") { model.signIn(.codex, method: .deviceCode) }
                }
            case .loggingIn(let progress):
                BrowserSignInProgress(progress: progress, compact: compact) { model.cancel(.codex) }
            case .failed(let message):
                FlowLine(.problem, message)
                FlowButtons { FlowMainButton("Try again", compact: compact) { model.checkAgain(.codex) } }
            case .checking, .unknown:
                FlowLine(.progress, "Checking…")
            }
        }
    }
}

// MARK: - Grok

@MainActor
private struct GrokFlow: View {
    let model: SetupModel
    let compact: Bool
    private var service: GrokService { model.app.grok }

    var body: some View {
        if case .running(let message) = service.setupState {
            FlowLine(.progress, message.isEmpty ? "Setting up Grok…" : message)
            FlowNote("This takes about a minute.")
        } else if service.installIssue != nil {
            if case .failed(let error) = service.setupState {
                FlowLine(.problem, error)
                FlowButtons { FlowMainButton("Try again", compact: compact) { model.install(.grok) } }
            } else {
                FlowLine(.info, "Lectern installs Grok's official app from x.ai. It takes about a minute.")
                FlowNote("The installer also adds Grok to your Terminal settings (for example ~/.zshrc).")
                FlowButtons { FlowMainButton("Set up Grok", compact: compact) { model.install(.grok) } }
            }
        } else {
            if case .done = service.setupState, !service.authState.isSignedIn {
                FlowLine(.success, "Grok is set up.")
            }
            switch service.authState {
            case .signedIn(let account):
                SignedInStep(provider: .grok, account: account, model: model, compact: compact)
            case .signedOut:
                FlowLine(.info, "Sign in with your X or Grok account in your browser. A free account works too.")
                FlowButtons {
                    FlowMainButton("Sign in with Grok", compact: compact) { model.signIn(.grok) }
                    FlowLinkButton("Use a device code") { model.signIn(.grok, method: .deviceCode) }
                }
            case .loggingIn(let progress):
                BrowserSignInProgress(progress: progress, compact: compact) { model.cancel(.grok) }
            case .failed(let message):
                FlowLine(.problem, message)
                FlowButtons { FlowMainButton("Try again", compact: compact) { model.checkAgain(.grok) } }
            case .checking, .unknown:
                FlowLine(.progress, "Checking…")
            }
        }
    }
}

// MARK: - On This Mac

@MainActor
private struct LocalFlow: View {
    let model: SetupModel
    let compact: Bool
    private var service: LocalService { model.app.local }

    var body: some View {
        appleLine
        // A model is ready (Apple's or one in Ollama): the step that makes On This Mac the choice comes
        // first, above the long model list.
        if model.status(.local).isReady {
            UseStep(provider: .local, model: model, compact: compact)
        }
        switch service.ollamaStatus {
        case .notInstalled:
            if service.appleStatus == .available {
                FlowNote("For more models, you can also get Ollama, a free app that runs AI models on your Mac.")
                FlowButtons {
                    Button("Get Ollama") { model.getOllama() }
                }
            } else {
                FlowLine(.info, "Get Ollama, a free app that runs AI models on your Mac. "
                         + "Open it once, then come back here.")
                FlowButtons {
                    FlowMainButton("Get Ollama", compact: compact) { model.getOllama() }
                    Button("Check again") { model.checkAgain(.local) }
                }
            }
        case .notRunning:
            if model.waitingForOllama {
                FlowLine(.progress, "Opening Ollama…")
            } else if case .loggingIn(let progress) = service.authState {
                FlowLine(.progress, progress.message.isEmpty ? "Opening Ollama…" : progress.message)
            } else {
                FlowLine(.info, "Ollama is on this Mac but isn't open.")
                FlowButtons {
                    FlowMainButton("Open Ollama", compact: compact) { model.openOllama() }
                }
            }
        case .ready(let installed):
            downloadStatus
            modelPicker
            suggestionList(installed: installed)
        }
    }

    @ViewBuilder private var appleLine: some View {
        switch service.appleStatus {
        case .available:
            FlowLine(.success, "Apple Intelligence is ready. Nothing to download.")
        case .unavailable(let reason):
            FlowLine(.info, reason.isEmpty ? "Apple Intelligence isn't ready on this Mac." : reason)
        case .unsupported:
            FlowLine(.info, "Apple Intelligence isn't available on this Mac.")
        }
    }

    /// The models new On This Mac conversations can use; a click makes one the default.
    @ViewBuilder private var modelPicker: some View {
        let models = service.models
        if models.count > 1 {
            SectionTitle("Model for new conversations")
            VStack(spacing: 2) {
                ForEach(models) { option in
                    ModelChoiceRow(title: option.displayName, detail: option.detail,
                                   selected: model.localModel == option.id) {
                        model.selectLocalModel(option.id)
                    }
                }
            }
        }
    }

    /// The download running now, or how the last one ended.
    @ViewBuilder private var downloadStatus: some View {
        if let download = service.download {
            let title = LocalService.suggestions.first { $0.id == download.model }?.title ?? download.model
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Button("Cancel") { model.cancelDownload() }
                        .controlSize(.small)
                }
                ProgressView(value: min(max(download.progress, 0), 1))
                    .progressViewStyle(.linear)
                Text(download.status.isEmpty ? "\(Int((download.progress * 100).rounded()))%" : download.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            .accessibilityElement(children: .combine)
        } else if let result = model.downloadResult {
            if result.succeeded {
                FlowLine(.success, "\(result.suggestion.title) is ready.")
            } else {
                FlowLine(.problem, service.downloadError
                         ?? "The download of \(result.suggestion.title) stopped. Check the internet connection, then try again.")
                FlowButtons {
                    FlowMainButton("Try again", compact: compact) { model.download(result.suggestion) }
                }
            }
        }
    }

    @ViewBuilder private func suggestionList(installed: [String]) -> some View {
        let suggestions = LocalService.suggestions.filter { !Self.isInstalled($0.id, in: installed) }
        if !suggestions.isEmpty {
            SectionTitle(installed.isEmpty ? "Download a model" : "Download another model")
            VStack(spacing: 2) {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion, busy: service.download != nil) {
                        model.download(suggestion)
                    }
                }
            }
        }
    }

    /// Ollama reports "name:tag"; a suggestion without a tag means ":latest".
    static func isInstalled(_ id: String, in installed: [String]) -> Bool {
        let wanted = id.contains(":") ? id : id + ":latest"
        return installed.contains { $0 == id || $0 == wanted }
    }
}

@MainActor
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
private struct ModelChoiceRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct SuggestionRow: View {
    let suggestion: LocalService.Suggestion
    let busy: Bool
    let download: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(suggestion.title).lineLimit(1)
                    Text(suggestion.size).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(suggestion.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Download", action: download)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityLabel("Download \(suggestion.title), \(suggestion.size)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}
