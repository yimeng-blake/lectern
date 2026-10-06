import AppKit
import Observation
import LecternCore

/// App-wide preferences, persisted in UserDefaults.
@MainActor @Observable
final class SettingsStore {
    enum BackendChange { case claudePath, codexPath, codexHomeMode }

    private enum Key {
        static func turnSettings(_ p: Provider) -> String { "turnSettings.\(p.rawValue)" }
        static let protectCredits = "protectCredits"
        static let codexHomeMode = "codexHomeMode"
        static let claudePathOverride = "claudePathOverride"
        static let codexPathOverride = "codexPathOverride"
        static let neighborRadius = "neighborRadius"
        static let lastProvider = "lastProvider"
        static let appearance = "appearance"
        static let darkPages = "darkPages"
        static let aiConversationTitles = "aiConversationTitles"
        static let chatTextSize = "chatTextSize"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Set by AppServices: binary discovery and the Codex server depend on these values.
    @ObservationIgnored var onBackendChange: ((BackendChange) -> Void)?

    /// Saved per-provider defaults as stored. A Codex model of "" means "the catalog default".
    private(set) var savedTurnSettings: [Provider: TurnSettings]

    /// Ask before a ChatGPT turn would run on purchased credits.
    var protectCredits: Bool {
        didSet { defaults.set(protectCredits, forKey: Key.protectCredits) }
    }
    var codexHomeMode: CodexHomeMode {
        didSet {
            guard codexHomeMode != oldValue else { return }
            defaults.set(codexHomeMode.rawValue, forKey: Key.codexHomeMode)
            onBackendChange?(.codexHomeMode)
        }
    }
    /// "" = auto-detect.
    var claudePathOverride: String {
        didSet {
            guard claudePathOverride != oldValue else { return }
            defaults.set(claudePathOverride, forKey: Key.claudePathOverride)
            onBackendChange?(.claudePath)
        }
    }
    /// "" = auto-detect.
    var codexPathOverride: String {
        didSet {
            guard codexPathOverride != oldValue else { return }
            defaults.set(codexPathOverride, forKey: Key.codexPathOverride)
            onBackendChange?(.codexPath)
        }
    }
    /// Pages on each side of the current page sent as context (0–3).
    var neighborRadius: Int {
        didSet { defaults.set(neighborRadius, forKey: Key.neighborRadius) }
    }
    var lastProvider: Provider {
        didSet { defaults.set(lastProvider.rawValue, forKey: Key.lastProvider) }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }
    /// Inverted page colors in every reader window (display only).
    var darkPages: Bool {
        didSet {
            defaults.set(darkPages, forKey: Key.darkPages)
            NotificationCenter.default.post(name: .lecternDarkPagesChanged, object: nil)
        }
    }

    /// Name each conversation with a short model title after its first answer (else the question's
    /// first words). ChatGPT titles never spend purchased credits.
    var aiConversationTitles: Bool {
        didSet { defaults.set(aiConversationTitles, forKey: Key.aiConversationTitles) }
    }

    /// Every open transcript and message field follows it at once.
    var chatTextSize: ChatTextSize {
        didSet { defaults.set(chatTextSize.rawValue, forKey: Key.chatTextSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var turns: [Provider: TurnSettings] = [:]
        for p in Provider.allCases {
            if let data = defaults.data(forKey: Key.turnSettings(p)),
               let saved = try? JSONDecoder().decode(TurnSettings.self, from: data) {
                turns[p] = saved
            } else {
                turns[p] = TurnSettings()
            }
        }
        savedTurnSettings = turns
        protectCredits = defaults.object(forKey: Key.protectCredits) as? Bool ?? true
        codexHomeMode = defaults.string(forKey: Key.codexHomeMode).flatMap(CodexHomeMode.init(rawValue:)) ?? .isolated
        claudePathOverride = defaults.string(forKey: Key.claudePathOverride) ?? ""
        codexPathOverride = defaults.string(forKey: Key.codexPathOverride) ?? ""
        neighborRadius = defaults.object(forKey: Key.neighborRadius) as? Int ?? 1
        lastProvider = defaults.string(forKey: Key.lastProvider).flatMap(Provider.init(rawValue:)) ?? .claude
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        darkPages = defaults.bool(forKey: Key.darkPages)
        aiConversationTitles = defaults.object(forKey: Key.aiConversationTitles) as? Bool ?? true
        chatTextSize = defaults.string(forKey: Key.chatTextSize).flatMap(ChatTextSize.init(rawValue:)) ?? .medium
    }

    /// Called at launch and on every change; every window, including Settings, follows NSApp.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    var claudePathOverrideValue: String? { Self.nonEmpty(claudePathOverride) }
    var codexPathOverrideValue: String? { Self.nonEmpty(codexPathOverride) }
    var contextRadius: Int { min(max(neighborRadius, 0), 3) }

    /// The defaults to use for a turn, made valid against the provider's current model catalog.
    func turnSettings(for provider: Provider, models: [ModelOption]) -> TurnSettings {
        ModelCatalog.resolve(savedTurnSettings[provider] ?? TurnSettings(), provider: provider, models: models)
    }

    func setTurnSettings(_ settings: TurnSettings, for provider: Provider, models: [ModelOption]) {
        let clamped = ModelCatalog.clampEffort(settings, models: models)
        guard savedTurnSettings[provider] != clamped else { return }
        savedTurnSettings[provider] = clamped
        if let data = try? JSONEncoder().encode(clamped) {
            defaults.set(data, forKey: Key.turnSettings(provider))
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum ModelCatalog {
    /// Option for `model`, else the catalog default, else the first entry.
    static func selected(_ model: String, in models: [ModelOption]) -> ModelOption? {
        models.first { $0.id == model } ?? models.first { $0.isDefault } ?? models.first
    }

    /// Codex models come and go (gpt-5.5 retires 2026-10-14), so a saved Codex model that is missing
    /// from the catalog falls back to the catalog default with its default effort. Claude accepts any
    /// alias or full id, so its saved model is kept. Unknown catalogs leave settings untouched.
    static func resolve(_ saved: TurnSettings, provider: Provider, models: [ModelOption]) -> TurnSettings {
        guard !models.isEmpty else { return saved }
        var s = saved
        if provider == .codex, !models.contains(where: { $0.id == s.model }) {
            let fallback = models.first(where: { $0.isDefault }) ?? models[0]
            s.model = fallback.id
            s.effort = fallback.defaultEffort ?? ""
        }
        return clampEffort(s, models: models)
    }

    /// An effort the selected model doesn't support becomes "" (the model's default).
    static func clampEffort(_ settings: TurnSettings, models: [ModelOption]) -> TurnSettings {
        var s = settings
        if !s.effort.isEmpty, let m = selected(s.model, in: models), !m.efforts.contains(s.effort) {
            s.effort = ""
        }
        return s
    }
}
