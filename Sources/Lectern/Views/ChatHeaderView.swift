import LecternCore
import SwiftUI

/// Provider / model / effort / tier pickers, account and quota status, and New chat. A compact (narrow)
/// panel has one row: provider, model and effort in one menu, and the account as a colored dot with the
/// usage. Picker changes are written to `model.settings`, whose setter persists them as the new default.
@MainActor
struct ChatHeaderView: View {
    @Bindable var model: ChatModel
    var compact = false

    private var quota: QuotaSnapshot? {
        guard let quota = model.quota, !quota.windows.isEmpty || quota.includedUsageExhausted else { return nil }
        return quota
    }

    private var resolvedModel: String? {
        guard let resolved = model.resolvedModel, !resolved.isEmpty else { return nil }
        return resolved
    }

    private var offersFastTier: Bool { model.provider == .codex && model.selectedModel?.fastTierId != nil }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    settingsMenu
                    Spacer(minLength: 4)
                    AccountDot(state: model.authState, quota: quota)
                    newChatButton
                }
            } else {
                wideBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 7 : 8)
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // The separate pickers, or the combined menu when long names don't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        providerMenu
                        modelMenu
                        effortMenu
                        if offersFastTier { fastToggle }
                    }
                    settingsMenu
                }
                Spacer(minLength: 4)
                newChatButton
            }

            HStack(spacing: 6) {
                AccountChip(state: model.authState)
                    .layoutPriority(-1)
                if let quota {
                    QuotaChip(quota: quota)
                }
                Spacer(minLength: 4)
                if let resolvedModel {
                    Text(resolvedModel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Model the backend reported for the latest answer")
                        .layoutPriority(-1)
                }
            }
        }
    }

    private var newChatButton: some View {
        Button {
            model.newChat()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.borderless)
        .help("New chat")
        .accessibilityLabel("New chat")
        .disabled(model.isBusy)
    }

    // MARK: Combined menu (compact)

    /// e.g. "Claude · Opus · Medium" (truncated at the end when narrow).
    private var settingsSummary: String {
        var parts = [model.provider.displayName, modelTitle]
        if !model.settings.effort.isEmpty {
            parts.append(Self.effortName(model.settings.effort))
        } else if let fallback = model.selectedModel?.defaultEffort, !fallback.isEmpty {
            parts.append(Self.effortName(fallback))
        }
        if offersFastTier, model.settings.fastTier { parts.append("Fast") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var settingsMenu: some View {
        Menu {
            Section("Provider") { providerItems }
            Section("Model") { modelItems }
            Section("Reasoning Effort") { effortItems }
            if offersFastTier {
                Section {
                    Toggle("Fast (Priority Tier)", isOn: fastBinding)
                }
            }
            if let resolvedModel {
                Section {
                    Text("Last answer: \(resolvedModel)")
                }
            }
        } label: {
            Text(settingsSummary)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .layoutPriority(1)
        .help("Provider, model and reasoning effort: \(settingsSummary)")
        .accessibilityLabel("Provider, model and effort: \(settingsSummary)")
    }

    // MARK: Provider

    private var providerMenu: some View {
        Menu {
            providerItems
        } label: {
            Text(model.provider.displayName)
                .fontWeight(.semibold)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("AI provider — each keeps its own conversation about this document")
        .accessibilityLabel("Provider: \(model.provider.displayName)")
    }

    @ViewBuilder private var providerItems: some View {
        ForEach(Provider.allCases) { provider in
            Toggle(isOn: Binding(
                get: { model.provider == provider },
                set: { if $0 { model.provider = provider } }
            )) {
                Text(provider.displayName)
                Text(providerStatus(provider))
            }
        }
    }

    /// Menu subtitle, e.g. "Signed in · Max", "Signed out", "Answering…".
    private func providerStatus(_ provider: Provider) -> String {
        if model.isBusy(provider) { return "Answering…" }
        switch model.authState(for: provider) {
        case .signedIn(let account):
            if let plan = account.components(separatedBy: " · ").last, plan != account { return "Signed in · \(plan)" }
            return "Signed in"
        case .signedOut: return "Signed out"
        case .failed: return "Sign-in problem"
        case .checking: return "Checking…"
        case .loggingIn: return "Signing in…"
        case .unknown: return ""
        }
    }

    // MARK: Model

    /// Claude's "" option means "your Claude Code default"; make sure it is always offered.
    private var modelOptions: [ModelOption] {
        var options = model.models
        if model.provider == .claude, !options.contains(where: { $0.id.isEmpty }) {
            options.insert(ModelOption(id: "", displayName: "Default", efforts: []), at: 0)
        }
        return options
    }

    private var selectedModelId: String { model.selectedModel?.id ?? model.settings.model }

    private func title(for option: ModelOption) -> String {
        option.id.isEmpty && model.provider == .claude ? "Default" : option.displayName
    }

    private var modelTitle: String {
        if let selected = model.selectedModel { return title(for: selected) }
        return model.settings.model.isEmpty ? "Default" : model.settings.model
    }

    private var modelMenu: some View {
        Menu {
            modelItems
        } label: {
            Text(modelTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Model")
        .accessibilityLabel("Model: \(modelTitle)")
    }

    @ViewBuilder private var modelItems: some View {
        let options = modelOptions
        if options.isEmpty {
            Text("Loading models…")
        }
        ForEach(options) { option in
            Toggle(isOn: Binding(
                get: { selectedModelId == option.id },
                set: { if $0 { select(option) } }
            )) {
                Text(title(for: option))
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                }
            }
        }
    }

    private func select(_ option: ModelOption) {
        var settings = model.settings
        settings.model = option.id
        // Drop choices the new model can't honor rather than sending them on every turn.
        if !settings.effort.isEmpty, !option.efforts.isEmpty, !option.efforts.contains(settings.effort) {
            settings.effort = ""
        }
        if option.fastTierId == nil {
            settings.fastTier = false
        }
        model.settings = settings
    }

    // MARK: Effort

    private var effortTitle: String {
        let effort = model.settings.effort
        return effort.isEmpty ? "Default effort" : Self.effortName(effort)
    }

    private var effortMenu: some View {
        Menu {
            effortItems
        } label: {
            Label(effortTitle, systemImage: "gauge.medium")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort: \(effortTitle)")
    }

    @ViewBuilder private var effortItems: some View {
        Toggle(isOn: effortBinding("")) {
            if let fallback = model.selectedModel?.defaultEffort, !fallback.isEmpty {
                Text("Default (\(Self.effortName(fallback)))")
            } else {
                Text("Default")
            }
        }
        let choices = model.effortChoices.filter { !$0.isEmpty }
        if !choices.isEmpty {
            Divider()
        }
        ForEach(choices, id: \.self) { effort in
            Toggle(Self.effortName(effort), isOn: effortBinding(effort))
        }
    }

    private func effortBinding(_ effort: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.effort == effort },
            set: { isOn in
                guard isOn else { return }
                var settings = model.settings
                settings.effort = effort
                model.settings = settings
            }
        )
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra high"
        case "": return "Default"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    // MARK: Fast tier

    private var fastBinding: Binding<Bool> {
        Binding(
            get: { model.settings.fastTier },
            set: { isOn in
                var settings = model.settings
                settings.fastTier = isOn
                model.settings = settings
            }
        )
    }

    private var fastToggle: some View {
        Toggle(isOn: fastBinding) {
            Label("Fast", systemImage: "hare")
        }
        .toggleStyle(.button)
        .help("Priority tier — uses about 2.5× your included usage")
    }
}

// MARK: - Chips

/// What the account chip and dot say about a sign-in state.
private enum AccountStatus {
    static func text(_ state: AuthState) -> String {
        switch state {
        case .signedIn(let account): return account.isEmpty ? "Signed in" : account
        case .signedOut: return "Signed out"
        case .failed: return "Sign-in problem"
        case .checking: return "Checking…"
        case .loggingIn: return "Signing in…"
        case .unknown: return "Account"
        }
    }

    /// e.g. "Max" from "you@example.com · Max".
    static func shortText(_ state: AuthState) -> String? {
        guard case .signedIn(let account) = state else { return nil }
        if let plan = account.components(separatedBy: " · ").last, plan != account { return plan }
        return account.split(separator: "@").first.map(String.init)
    }

    static func help(_ state: AuthState) -> String {
        switch state {
        case .signedIn(let account): return "Signed in as \(account). Click for account settings."
        case .signedOut(let reason): return reason
        case .failed(let message): return message
        case .checking: return "Checking sign-in status…"
        case .loggingIn(let progress): return progress.message
        case .unknown: return "Account settings"
        }
    }
}

@MainActor
private struct AccountIndicator: View {
    let state: AuthState

    var body: some View {
        switch state {
        case .checking, .loggingIn:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
                .scaleEffect(0.75)
        case .signedIn:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .signedOut, .failed:
            Circle().fill(.orange).frame(width: 8, height: 8)
        case .unknown:
            Circle().fill(.secondary.opacity(0.5)).frame(width: 8, height: 8)
        }
    }
}

/// Account status; opens Settings (Accounts) on click.
@MainActor
private struct AccountChip: View {
    let state: AuthState

    var body: some View {
        SettingsLink {
            // Narrow panes get progressively shorter labels instead of an unreadable "r…x".
            ViewThatFits(in: .horizontal) {
                chip(Text(AccountStatus.text(state)))
                chip(Text(AccountStatus.text(state)).lineLimit(1).truncationMode(.middle)
                    .frame(width: 130, alignment: .leading))
                if let short = AccountStatus.shortText(state) { chip(Text(short)) }
                chip(EmptyView())
            }
        }
        .buttonStyle(.plain)
        .help(AccountStatus.help(state))
        // Narrow panes show only the dot, so the state must be spoken.
        .accessibilityLabel("Account: \(AccountStatus.text(state))")
        .accessibilityHint(AccountStatus.help(state))
    }

    private func chip(_ label: some View) -> some View {
        HStack(spacing: 6) {
            AccountIndicator(state: state)
            label
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// Compact panels: the account as a colored dot (the account and the usage in its tooltip), plus the
/// highest usage percentage when there is a quota. Opens Settings (Accounts) on click.
@MainActor
private struct AccountDot: View {
    let state: AuthState
    let quota: QuotaSnapshot?

    var body: some View {
        SettingsLink {
            HStack(spacing: 5) {
                AccountIndicator(state: state)
                if let quota {
                    Text(QuotaChip.highest(quota))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(QuotaChip.tint(quota))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("Account: \(AccountStatus.text(state))")
        .accessibilityHint(tooltip)
    }

    private var tooltip: String {
        var lines = [AccountStatus.text(state)]
        if let quota { lines.append(QuotaChip.tooltip(quota)) }
        lines.append("Click for account settings.")
        return lines.joined(separator: "\n")
    }
}

/// Plan usage, e.g. "Weekly 1%" or "5h 7% · 7d 4%".
@MainActor
private struct QuotaChip: View {
    let quota: QuotaSnapshot

    var body: some View {
        Text(Self.summary(quota))
            .font(.callout.monospacedDigit())
            .foregroundStyle(Self.tint(quota))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Self.tint(quota).opacity(0.12)))
            .fixedSize()
            .help(Self.tooltip(quota))
    }

    static func summary(_ quota: QuotaSnapshot) -> String {
        if quota.windows.isEmpty { return "Limit reached" }
        if quota.windows.count == 1, let window = quota.windows.first {
            return "\(window.label) \(percent(window.usedPercent))"
        }
        return quota.windows.map { "\(shortLabel($0.label)) \(percent($0.usedPercent))" }
            .joined(separator: " · ")
    }

    /// The most used window, e.g. "7%" ("Limit" when used up without windows).
    static func highest(_ quota: QuotaSnapshot) -> String {
        guard let used = quota.windows.map(\.usedPercent).max() else { return "Limit" }
        return percent(used)
    }

    static func tint(_ quota: QuotaSnapshot) -> Color {
        if quota.includedUsageExhausted { return .red }
        if quota.windows.contains(where: { $0.usedPercent >= 80 }) { return .orange }
        return .secondary
    }

    static func tooltip(_ quota: QuotaSnapshot) -> String {
        var lines = quota.windows.map { window -> String in
            var line = "\(window.label): \(percent(window.usedPercent)) used"
            if let reset = window.resetsAt {
                line += " · resets \(reset.formatted(date: .abbreviated, time: .shortened))"
            }
            return line
        }
        if quota.includedUsageExhausted { lines.append("Included usage is used up.") }
        if let note = quota.note, !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String {
        "\(Int(max(0, value).rounded()))%"
    }

    static func shortLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower == "weekly" || lower == "7-day" { return "7d" }
        if lower == "daily" { return "1d" }
        if lower.hasSuffix("-hour"), let hours = Int(lower.dropLast(5)) { return "\(hours)h" }
        return label
    }
}
