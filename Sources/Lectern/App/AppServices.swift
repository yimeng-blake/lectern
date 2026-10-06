import Foundation
import Observation
import LecternCore

/// App-wide backends and stores, shared by every document window and the Settings window.
@MainActor @Observable
final class AppServices {
    static let shared = AppServices()

    let settings: SettingsStore
    let claude: ClaudeService
    let codex: CodexService
    let sessions: SessionStore

    @ObservationIgnored private var started = false
    @ObservationIgnored private var claudeRelocation: Task<Void, Never>?
    @ObservationIgnored private var codexRestart: Task<Void, Never>?
    @ObservationIgnored private var liveModels: [WeakChatModel] = []

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        claude = ClaudeService(pathOverride: { settings.claudePathOverrideValue })
        codex = CodexService(pathOverride: { settings.codexPathOverrideValue },
                             homeMode: { settings.codexHomeMode })
        sessions = SessionStore()
        settings.onBackendChange = { [weak self] change in self?.backendSettingChanged(change) }
    }

    var providerServices: [Provider: ProviderService] { [.claude: claude, .codex: codex] }

    func service(for provider: Provider) -> ProviderService {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// Cheap status checks at launch; never a login.
    func start() {
        guard !started else { return }
        started = true
        for service in providerServices.values {
            service.refreshAuth()
            service.reloadModels()
        }
    }

    func register(_ model: ChatModel) {
        liveModels.removeAll { $0.model == nil }
        liveModels.append(WeakChatModel(model: model))
    }

    /// A window already shows a PDF with these bytes (e.g. a duplicate download).
    func isOpen(contentHash: String) -> Bool {
        liveModels.contains { entry in
            guard let model = entry.model else { return false }
            return !model.isShutDown && model.document.contentHash == contentHash
        }
    }

    /// App is quitting: stop every Claude process and the Codex app-server.
    func shutdown() {
        claudeRelocation?.cancel()
        codexRestart?.cancel()
        for entry in liveModels { entry.model?.shutdown() }
        liveModels.removeAll()
        codex.stop()
    }

    /// Path fields change on every keystroke, so binary changes are applied once typing pauses.
    private func backendSettingChanged(_ change: SettingsStore.BackendChange) {
        switch change {
        case .claudePath:
            claudeRelocation?.cancel()
            claudeRelocation = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                self.claude.relocateBinary()
            }
        case .codexPath:
            scheduleCodexRestart(after: .milliseconds(800))
        case .codexHomeMode:
            scheduleCodexRestart(after: .zero)
        }
    }

    /// The other home has its own login, threads and config, so auth and models are re-read too.
    private func scheduleCodexRestart(after delay: Duration) {
        codexRestart?.cancel()
        codexRestart = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.codex.restart()
            self.codex.refreshAuth()
            self.codex.reloadModels()
        }
    }
}

private struct WeakChatModel {
    weak var model: ChatModel?
}
