import LecternCore
import SwiftUI

/// Provider / model / effort / tier pickers, account and quota status, and New chat.
/// Picker changes are written to `model.settings`, whose setter persists them as the new default.
@MainActor
struct ChatHeaderView: View {
    @Bindable var model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                providerMenu
                modelMenu
                effortMenu
                if model.provider == .codex, model.selectedModel?.fastTierId != nil {
                    fastToggle
                }
                Spacer(minLength: 4)
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
            .controlSize(.small)

            HStack(spacing: 6) {
                AccountChip(state: model.authState)
                    .layoutPriority(-1)
                if let quota = model.quota, !quota.windows.isEmpty || quota.includedUsageExhausted {
                    QuotaChip(quota: quota)
                }
                Spacer(minLength: 4)
                if let resolved = model.resolvedModel, !resolved.isEmpty {
                    Text(resolved)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Model the backend reported for the latest answer")
                        .layoutPriority(-1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Provider

    private var providerMenu: some View {
        Menu {
            ForEach(Provider.allCases) { provider in
                Toggle(isOn: Binding(
                    get: { model.provider == provider },
                    set: { if $0 { model.provider = provider } }
                )) {
                    Text(provider.displayName)
                    Text(providerStatus(provider))
                }
            }
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
        } label: {
            Text(modelTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Model")
        .accessibilityLabel("Model: \(modelTitle)")
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
        } label: {
            Label(effortTitle, systemImage: "gauge.medium")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort: \(effortTitle)")
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

    private var fastToggle: some View {
        Toggle(isOn: Binding(
            get: { model.settings.fastTier },
            set: { isOn in
                var settings = model.settings
                settings.fastTier = isOn
                model.settings = settings
            }
        )) {
            Label("Fast", systemImage: "hare")
        }
        .toggleStyle(.button)
        .help("Priority tier — uses about 2.5× your included usage")
    }
}

// MARK: - Chips

/// Account status; opens Settings (Accounts) on click.
@MainActor
private struct AccountChip: View {
    let state: AuthState

    var body: some View {
        SettingsLink {
            // Narrow panes get progressively shorter labels instead of an unreadable "r…x".
            ViewThatFits(in: .horizontal) {
                chip(Text(text))
                chip(Text(text).lineLimit(1).truncationMode(.middle).frame(width: 110, alignment: .leading))
                if let shortText { chip(Text(shortText)) }
                chip(EmptyView())
            }
        }
        .buttonStyle(.plain)
        .help(help)
        // Narrow panes show only the dot, so the state must be spoken.
        .accessibilityLabel("Account: \(text)")
        .accessibilityHint(help)
    }

    private func chip(_ label: some View) -> some View {
        HStack(spacing: 5) {
            indicator
            label
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .contentShape(Capsule())
        .fixedSize()
    }

    /// e.g. "Max" from "you@example.com · Max".
    private var shortText: String? {
        guard case .signedIn(let account) = state else { return nil }
        if let plan = account.components(separatedBy: " · ").last, plan != account { return plan }
        return account.split(separator: "@").first.map(String.init)
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .checking, .loggingIn:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 9, height: 9)
                .scaleEffect(0.7)
        case .signedIn:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .signedOut, .failed:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .unknown:
            Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
        }
    }

    private var text: String {
        switch state {
        case .signedIn(let account): return account.isEmpty ? "Signed in" : account
        case .signedOut: return "Signed out"
        case .failed: return "Sign-in problem"
        case .checking: return "Checking…"
        case .loggingIn: return "Signing in…"
        case .unknown: return "Account"
        }
    }

    private var help: String {
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

/// Plan usage, e.g. "Weekly 1%" or "5h 7% · 7d 4%".
@MainActor
private struct QuotaChip: View {
    let quota: QuotaSnapshot

    var body: some View {
        Text(summary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
            .help(tooltip)
    }

    private var summary: String {
        if quota.windows.isEmpty { return "Limit reached" }
        if quota.windows.count == 1, let window = quota.windows.first {
            return "\(window.label) \(Self.percent(window.usedPercent))"
        }
        return quota.windows.map { "\(Self.shortLabel($0.label)) \(Self.percent($0.usedPercent))" }
            .joined(separator: " · ")
    }

    private var tint: Color {
        if quota.includedUsageExhausted { return .red }
        if quota.windows.contains(where: { $0.usedPercent >= 80 }) { return .orange }
        return .secondary
    }

    private var tooltip: String {
        var lines = quota.windows.map { window -> String in
            var line = "\(window.label): \(Self.percent(window.usedPercent)) used"
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
