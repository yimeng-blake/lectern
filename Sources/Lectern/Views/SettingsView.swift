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

@MainActor
private struct AccountsSettings: View {
    private var app: AppServices { .shared }

    var body: some View {
        Form {
            Section("Claude") {
                ClaudeAccountSection(service: app.claude)
            }
            Section("ChatGPT") {
                CodexAccountSection(service: app.codex, homeMode: app.settings.codexHomeMode)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct ClaudeAccountSection: View {
    let service: ClaudeService

    private enum Verification: Equatable { case idle, running, passed, failed }
    @State private var verification = Verification.idle
    @State private var version: String?

    var body: some View {
        AuthStatusRows(state: service.authState, email: service.accountEmail, plan: service.planName,
                       installIssue: service.installIssue, refresh: service.refreshAuth)
        BinaryRow(path: service.binaryPath, version: version)
            .task(id: service.binaryPath) { version = await Self.cliVersion(service.binaryPath) }
        LoginProgressRow(state: service.authState, cancel: service.cancelLogin)
        HStack {
            Button("Log in in Terminal") { service.startLogin(.terminal) }
                .help("Opens Terminal running Claude Code's own `claude auth login`")
            Spacer()
            verificationLabel
            Button("Verify connection") { verify() }
                .disabled(verification == .running)
                .help("Sends one tiny message with Haiku. The login status alone can be out of date.")
        }
        .disabled(service.installIssue != nil || service.authState.settingsLoginInProgress)
        Text("You sign in with Claude Code itself, in Terminal. Lectern uses that login and never sees your credentials.")
            .font(.caption)
            .foregroundStyle(.secondary)
        QuotaRows(quota: service.quota)
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
        AuthStatusRows(state: service.authState, email: service.accountEmail, plan: service.planName,
                       installIssue: service.installIssue, refresh: service.refreshAuth)
        BinaryRow(path: service.binaryPath, version: service.binaryVersion)
        LoginProgressRow(state: service.authState, cancel: service.cancelLogin)
        HStack {
            Button("Sign in with ChatGPT") { service.startLogin(.browser) }
            Button("Use a device code") { service.startLogin(.deviceCode) }
            Spacer()
            if homeMode == .isolated {
                Button("Sign out") { confirmSignOut = true }
                    .disabled(!service.authState.isSignedIn)
            }
        }
        .disabled(service.installIssue != nil || service.authState.settingsLoginInProgress)
        .confirmationDialog("Sign out of ChatGPT in Lectern?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { service.signOut() }
        } message: {
            Text("Only Lectern's own sign-in is removed. The ChatGPT app and the Codex CLI stay signed in.")
        }
        if homeMode == .shared {
            Text("Shared mode uses the login in ~/.codex. Signing in here also changes the login the Codex CLI uses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        QuotaRows(quota: service.quota)
    }
}

@MainActor
private struct AuthStatusRows: View {
    let state: AuthState
    let email: String?
    let plan: String?
    let installIssue: String?
    let refresh: () -> Void

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(statusText).multilineTextAlignment(.trailing)
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check the login status again")
                    .disabled(state == .checking || state.settingsLoginInProgress)
            }
        }
        let account = [email, plan].compactMap { $0 }.joined(separator: " · ")
        if !account.isEmpty {
            LabeledContent("Account", value: account)
        }
        if let installIssue {
            Text(installIssue).font(.caption).foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch state {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .signedIn: return "Signed in"
        case .signedOut(let reason): return reason
        case .loggingIn: return "Signing in…"
        case .failed(let message): return message
        }
    }

    private var symbol: String {
        switch state {
        case .signedIn: return "checkmark.circle.fill"
        case .signedOut, .failed: return "exclamationmark.circle.fill"
        case .unknown, .checking, .loggingIn: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch state {
        case .signedIn: return .green
        case .signedOut, .failed: return .orange
        case .unknown, .checking, .loggingIn: return .secondary
        }
    }
}

@MainActor
private struct LoginProgressRow: View {
    let state: AuthState
    let cancel: () -> Void

    var body: some View {
        if case .loggingIn(let progress) = state {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.message)
                    Spacer()
                    Button("Cancel", action: cancel)
                }
                if let code = progress.userCode {
                    HStack {
                        Text(code).font(.title3.monospaced()).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                }
                if let url = progress.url {
                    Link("Open the sign-in page", destination: url)
                }
            }
        }
    }
}

@MainActor
private struct BinaryRow: View {
    let path: String?
    let version: String?

    var body: some View {
        LabeledContent("CLI") {
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
            Text(service.installIssue ?? "Loading models…").font(.caption).foregroundStyle(.secondary)
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
