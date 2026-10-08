import AppKit
import SwiftUI
import LecternCore

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            ModelsSettings(settings: AppServices.shared.settings)
                .tabItem { Label("Models", systemImage: "cpu") }
            AdvancedSettings(settings: AppServices.shared.settings)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Accounts

/// The four providers as the setup window's cards in compact rows (status, the one button and the
/// inline flow), each followed by its details.
@MainActor
private struct AccountsSettings: View {
    private var app: AppServices { .shared }
    private var setup: SetupModel { .shared }

    var body: some View {
        Form {
            ForEach(Provider.setupOrder) { provider in
                Section {
                    ProviderSetupRow(provider: provider, model: setup)
                    details(provider)
                }
            }
            Section {
                HStack {
                    Text("New to Lectern? The setup window shows the four choices side by side.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up AI\u{2026}") { SetupWindow.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func details(_ provider: Provider) -> some View {
        switch provider {
        case .claude: ClaudeAccountSection(service: app.claude)
        case .codex: CodexAccountSection(service: app.codex, homeMode: app.settings.codexHomeMode)
        case .grok: GrokAccountSection(service: app.grok)
        case .local: LocalAccountSection(service: app.local)
        }
    }
}

@MainActor
private struct ClaudeAccountSection: View {
    let service: ClaudeService

    private enum Verification: Equatable { case idle, running, passed, failed }
    @State private var verification = Verification.idle
    @State private var version: String?

    var body: some View {
        if service.binaryPath != nil {
            BinaryRow(path: service.binaryPath, version: version)
                .task(id: service.binaryPath) { version = await Self.cliVersion(service.binaryPath) }
            QuotaRows(quota: service.quota)
            HStack {
                Button("Log in again") { service.startLogin(.terminal) }
                    .help("Opens Terminal running Claude Code's own `claude auth login`")
                    .disabled(!service.authState.isSignedIn)
                Spacer()
                verificationLabel
                Button("Verify connection") { verify() }
                    .disabled(verification == .running || !service.authState.isSignedIn)
                    .help("Sends one tiny message with Haiku. The login status alone can be out of date.")
            }
            .disabled(service.installIssue != nil || service.authState.settingsLoginInProgress)
            Text("You sign in with Claude Code itself, in Terminal. Lectern uses that login and never sees your credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var verificationLabel: some View {
        switch verification {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed: Label("Connection works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Claude refused the request — log in again", systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
        }
    }

    private func verify() {
        verification = .running
        Task {
            verification = await service.verifyConnection() ? .passed : .failed
        }
    }

    /// `claude --version` is a local call (no model request).
    static func cliVersion(_ path: String?) async -> String? {
        guard let path else { return nil }
        let result = await ProcessRunner.run(URL(fileURLWithPath: path), ["--version"], timeout: 10)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !text.isEmpty ? text : nil
    }
}

@MainActor
private struct CodexAccountSection: View {
    let service: CodexService
    let homeMode: CodexHomeMode

    @State private var confirmSignOut = false

    var body: some View {
        if service.binaryPath != nil {
            BinaryRow(path: service.binaryPath, version: service.binaryVersion)
            QuotaRows(quota: service.quota)
            if homeMode == .isolated, service.authState.isSignedIn {
                HStack {
                    Spacer()
                    Button("Sign out") { confirmSignOut = true }
                }
                .confirmationDialog("Sign out of ChatGPT in Lectern?", isPresented: $confirmSignOut) {
                    Button("Sign Out", role: .destructive) { service.signOut() }
                } message: {
                    Text("Only Lectern's own sign-in is removed. The ChatGPT app and the Codex CLI stay signed in.")
                }
            }
            if homeMode == .shared {
                Text("Shared mode uses the login in ~/.codex. Signing in here also changes the login the Codex CLI uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct GrokAccountSection: View {
    let service: GrokService
    @State private var version: String?

    var body: some View {
        if service.binaryPath != nil {
            BinaryRow(path: service.binaryPath, version: version)
                .task(id: service.binaryPath) { version = await ClaudeAccountSection.cliVersion(service.binaryPath) }
            QuotaRows(quota: service.quota)
            Text("You sign in on Grok's own sign-in page. Lectern never sees your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct LocalAccountSection: View {
    let service: LocalService

    var body: some View {
        LabeledContent("Apple Intelligence", value: appleText)
        LabeledContent("Ollama", value: ollamaText)
        Text("Models on this Mac are free and private: your questions and the PDF stay on this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var appleText: String {
        switch service.appleStatus {
        case .available: return "Ready"
        case .unavailable: return "Not ready"
        case .unsupported: return "Not available on this Mac"
        }
    }

    private var ollamaText: String {
        switch service.ollamaStatus {
        case .notInstalled: return "Not installed"
        case .notRunning: return "Not open"
        case .ready(let models):
            return models.isEmpty ? "No models" : models.count == 1 ? "1 model" : "\(models.count) models"
        }
    }
}

@MainActor
private struct BinaryRow: View {
    let path: String?
    let version: String?

    var body: some View {
        LabeledContent("Program") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(path ?? "Not found").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if let version { Text(version).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

@MainActor
private struct QuotaRows: View {
    let quota: QuotaSnapshot?

    var body: some View {
        if let quota {
            ForEach(quota.windows, id: \.label) { window in
                LabeledContent(window.label) {
                    Text(Self.describe(window))
                }
            }
            if quota.includedUsageExhausted {
                Text("Included usage is used up for now.").font(.caption).foregroundStyle(.orange)
            }
            if let note = quota.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ window: QuotaWindow) -> String {
        var text = "\(Int(window.usedPercent.rounded()))% used"
        if let reset = window.resetsAt {
            text += " · resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return text
    }
}

// MARK: - Models

@MainActor
private struct ModelsSettings: View {
    @Bindable var settings: SettingsStore
    private var app: AppServices { .shared }

    var body: some View {
        Form {
            Section("Claude") {
                ModelDefaultsRows(provider: .claude, service: app.claude, settings: settings)
            }
            Section("ChatGPT") {
                ModelDefaultsRows(provider: .codex, service: app.codex, settings: settings)
            }
            Section("Grok") {
                ModelDefaultsRows(provider: .grok, service: app.grok, settings: settings)
            }
            Section("On This Mac") {
                ModelDefaultsRows(provider: .local, service: app.local, settings: settings)
            }
            Section {
                Toggle("Protect purchased credits", isOn: $settings.protectCredits)
                Text("When your included ChatGPT usage runs out, more messages would be paid from purchased credits. With this on, Lectern asks before sending such a message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct ModelDefaultsRows: View {
    let provider: Provider
    let service: ProviderService
    @Bindable var settings: SettingsStore

    private var models: [ModelOption] { service.models }
    private var current: TurnSettings { settings.turnSettings(for: provider, models: models) }
    private var selected: ModelOption? { ModelCatalog.selected(current.model, in: models) }

    var body: some View {
        Picker("Model", selection: binding(\.model)) {
            if provider == .claude, !models.contains(where: { $0.id.isEmpty }) {
                Text("Default").tag("")
            }
            ForEach(models) { option in
                Text(option.displayName).tag(option.id)
            }
            if !current.model.isEmpty, !models.contains(where: { $0.id == current.model }) {
                Text(current.model).tag(current.model)
            }
        }
        .disabled(models.isEmpty)
        Picker("Reasoning effort", selection: binding(\.effort)) {
            Text(selected?.defaultEffort.map { "Default (\(EffortLabel.text($0)))" } ?? "Default").tag("")
            ForEach(selected?.efforts ?? [], id: \.self) { effort in
                Text(EffortLabel.text(effort)).tag(effort)
            }
        }
        .disabled(models.isEmpty)
        if provider == .codex {
            Toggle("Fast tier (≈2.5× usage)", isOn: binding(\.fastTier))
                .disabled(selected?.fastTierId == nil)
                .help("Faster answers; each message uses about 2.5× as much of your included usage.")
        }
        if models.isEmpty {
            Text(provider == .local ? "No model is ready on this Mac yet. Set one up in Accounts."
                 : service.installIssue ?? "Loading models…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TurnSettings, Value>) -> Binding<Value> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var s = current
                s[keyPath: keyPath] = value
                settings.setTurnSettings(s, for: provider, models: models)
            }
        )
    }
}

private enum EffortLabel {
    static func text(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra high"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

// MARK: - Advanced

@MainActor
private struct AdvancedSettings: View {
    @Bindable var settings: SettingsStore
    private var app: AppServices { .shared }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Dark Pages (inverted page colors; the PDF does not change)", isOn: $settings.darkPages)
                Picker("Chat text size", selection: $settings.chatTextSize) {
                    ForEach(ChatTextSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Chat font", selection: $settings.chatFont) {
                    ForEach(ChatFont.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Claude Code CLI") {
                TextField("Path override", text: $settings.claudePathOverride, prompt: Text("Auto-detect"))
                DetectedPathRow(path: app.claude.binaryPath)
            }
            Section("Codex") {
                TextField("Path override", text: $settings.codexPathOverride, prompt: Text("Auto-detect"))
                DetectedPathRow(path: app.codex.binaryPath)
                Picker("Codex home", selection: $settings.codexHomeMode) {
                    Text("Isolated — separate sign-in, no plugins, standard tier").tag(CodexHomeMode.isolated)
                    Text("Shared — uses ~/.codex login and your plugins").tag(CodexHomeMode.shared)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Grok") {
                TextField("Path override", text: $settings.grokPathOverride, prompt: Text("Auto-detect"))
                DetectedPathRow(path: app.grok.binaryPath)
            }
            Section("Context") {
                Stepper(value: $settings.neighborRadius, in: 0...3) {
                    Text(settings.contextRadius == 0
                         ? "Current page only"
                         : "Current page ± \(settings.contextRadius) page\(settings.contextRadius == 1 ? "" : "s")")
                }
                Text("Pages around the one you are reading that are sent with each question. Each page is sent once per conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Conversations") {
                Toggle("AI conversation titles", isOn: $settings.aiConversationTitles)
                Text("After a conversation's first answer, its provider's lightest model names it in a few words. ChatGPT titles never use purchased credits. Off: titles come from the first question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct DetectedPathRow: View {
    let path: String?

    var body: some View {
        LabeledContent("Detected") {
            HStack {
                Text(path ?? "Not found").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Reveal in Finder") {
                    guard let path else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .disabled(path == nil)
            }
        }
    }
}

// MARK: - Helpers

private extension AuthState {
    var settingsLoginInProgress: Bool {
        if case .loggingIn = self { return true }
        return false
    }
}
