import AppKit
import Foundation
import Observation

/// "On This Mac": free models with no account. Apple's on-device model (FoundationModels) and models the
/// user downloaded into Ollama (HTTP API on 127.0.0.1:11434). Model ids: "apple.on-device", "ollama:<name>".
/// "Signed in" means some model is usable right now; otherwise the reason says, in plain words, what to do.
@MainActor @Observable
public final class LocalService: ProviderService {
    public enum AppleStatus: Equatable, Sendable {
        case available
        /// Supported here but not ready; the text says what to do.
        case unavailable(String)
        /// This Mac or macOS version can't run it (Intel, macOS < 26, or built without the framework).
        case unsupported
    }

    public enum OllamaStatus: Equatable, Sendable {
        case notInstalled
        /// Installed (app or command-line tool) but the server isn't answering.
        case notRunning
        /// Installed local chat models, by Ollama name.
        case ready(models: [String])
    }

    public struct Suggestion: Identifiable, Hashable, Sendable {
        /// Ollama model name to download, e.g. "qwen3.5:4b".
        public let id: String
        public let title: String
        public let size: String
        public let note: String
        /// Download size, for progress before Ollama reports every layer.
        let bytes: Int64
    }

    public static let appleModelId = "apple.on-device"

    public let provider: Provider = .local
    public var installIssue: String? { nil }
    public private(set) var authState: AuthState = .unknown
    public private(set) var models: [ModelOption] = []
    public var quota: QuotaSnapshot? { nil }

    public private(set) var appleStatus: AppleStatus = .unsupported
    public private(set) var ollamaStatus: OllamaStatus = .notInstalled
    /// Ollama.app is installed, so `openOllama()` can start the server.
    public private(set) var canOpenOllama = false
    /// The /api/pull in progress.
    public private(set) var download: (model: String, progress: Double, status: String)?
    /// Why the last download failed (nil after a success or a cancel).
    public private(set) var downloadError: String?
    /// Model a turn uses when none is picked; nil when nothing is usable.
    public private(set) var defaultModelId: String?

    /// Opens web pages and apps. Replaceable so lectern-probe never opens anything.
    @ObservationIgnored public var urlOpener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored public var appOpener: @MainActor (URL) -> Void = { url in
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    @ObservationIgnored let client: OllamaClient
    @ObservationIgnored private(set) var ollamaModels: [OllamaModel] = []
    @ObservationIgnored private var showCache: [String: (capabilities: [String], contextLength: Int?)] = [:]
    @ObservationIgnored private var observers: [@MainActor (AuthState) -> Void] = []
    @ObservationIgnored private var refreshCounter = 0
    @ObservationIgnored private var appliedRefresh = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastAction = Date()
    @ObservationIgnored private var startingOllama: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Bool, Never>?

    public convenience init() {
        self.init(ollamaURL: URL(string: "http://127.0.0.1:11434")!)
    }

    /// `ollamaURL` other than the default is for tests (lectern-probe `--ollama-url`).
    public init(ollamaURL: URL) {
        client = OllamaClient(base: ollamaURL)
        refreshAuth()
    }

    public var isUsable: Bool { defaultModelId != nil }

    /// Small models that run well on ordinary Macs (names verified on ollama.com/library, Oct 2026).
    /// The first one is the pick for this Mac's memory.
    public static var suggestions: [Suggestion] {
        let all = [
            Suggestion(id: "qwen3.5:4b", title: "Qwen 3.5 · 4B", size: "3.3 GB",
                       note: "Good answers, reads long passages and page images.", bytes: 3_320_000_000),
            Suggestion(id: "llama3.2:3b", title: "Llama 3.2 · 3B", size: "2.0 GB",
                       note: "Smallest and fastest. Fine on Macs with 8 GB of memory.", bytes: 2_020_000_000),
            Suggestion(id: "gemma4:e4b", title: "Gemma 4 · E4B", size: "6.6 GB",
                       note: "Sharper answers. Needs 16 GB of memory or more.", bytes: 6_580_000_000),
            Suggestion(id: "qwen3.5:9b", title: "Qwen 3.5 · 9B", size: "6.6 GB",
                       note: "Best answers of these. Needs 24 GB of memory or more.", bytes: 6_550_000_000),
        ]
        let gb = ProcessInfo.processInfo.physicalMemory >> 30
        let pickId = gb >= 32 ? "qwen3.5:9b" : gb >= 16 ? "qwen3.5:4b" : "llama3.2:3b"
        guard let pick = all.first(where: { $0.id == pickId }) else { return all }
        let recommended = Suggestion(id: pick.id, title: pick.title, size: pick.size,
                                     note: "Recommended for this Mac. " + pick.note, bytes: pick.bytes)
        return [recommended] + all.filter { $0.id != pickId }
    }

    // MARK: - ProviderService

    public func refreshAuth() {
        Task { await self.refresh() }
    }

    public func reloadModels() {
        Task { await self.refresh() }
    }

    /// Sessions call this when Ollama stopped answering or Apple's model became unavailable.
    public func markAuthExpired(_ reason: String) {
        Task { await self.refresh() }
    }

    public func addAuthObserver(_ handler: @escaping @MainActor (AuthState) -> Void) {
        observers.append(handler)
    }

    public func makeSession(conversationId: String?) -> ChatSession {
        LocalSession(service: self)
    }

    /// Nothing to sign in to: starts Ollama when it is installed but not running, otherwise opens the
    /// Ollama download page when no model can run here. Only ever from an explicit click.
    public func startLogin(_ method: LoginMethod) {
        if ollamaStatus == .notRunning, canOpenOllama {
            openOllama()
        } else if ollamaStatus == .notInstalled, !isUsable {
            openOllamaDownloadPage()
        } else {
            refreshAuth()
        }
    }

    public func cancelLogin() {
        startingOllama?.cancel()
        startingOllama = nil
        refreshAuth()
    }

    // MARK: - Status

    /// Re-reads Apple Intelligence availability and the Ollama server (version, installed models).
    /// No model is loaded or called.
    public func refresh() async {
        refreshCounter += 1
        let check = refreshCounter
        if case .unknown = authState { setAuth(.checking) }
        let apple = AppleModel.status()
        let app = Self.findOllamaApp()
        let (status, installed) = await readOllama(installedApp: app != nil)
        // Overlapping checks: an older one that finishes last must not overwrite a newer result.
        guard check > appliedRefresh else { return }
        appliedRefresh = check
        // Assign only on change: every assignment re-renders observers, and this runs on a timer.
        if appleStatus != apple { appleStatus = apple }
        if canOpenOllama != (app != nil) { canOpenOllama = app != nil }
        if ollamaStatus != status { ollamaStatus = status }
        ollamaModels = installed
        rebuildModels()
        updateAuth()
        schedulePoll()
    }

    private func readOllama(installedApp: Bool) async -> (OllamaStatus, [OllamaModel]) {
        guard await client.version() != nil else {
            return (installedApp || Self.ollamaCLI() != nil ? .notRunning : .notInstalled, [])
        }
        guard let listed = try? await client.tags() else { return (.ready(models: []), []) }
        var out: [OllamaModel] = []
        for var m in listed {
            if showCache[m.digest] == nil, let info = await client.show(m.name) { showCache[m.digest] = info }
            m.capabilities = showCache[m.digest]?.capabilities ?? []
            m.contextLength = showCache[m.digest]?.contextLength
            if m.canChat { out.append(m) }
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (.ready(models: out.map(\.name)), out)
    }

    /// Installed model info for a session, re-reading Ollama once if it isn't known yet.
    func ollamaModel(_ name: String) async -> OllamaModel? {
        if let m = ollamaModels.first(where: { $0.name == name }) { return m }
        await refresh()
        return ollamaModels.first { $0.name == name }
    }

    private func rebuildModels() {
        let memory = Int64(ProcessInfo.processInfo.physicalMemory)
        // The newest model that fits comfortably in memory is most likely the one just downloaded.
        let fitting = ollamaModels.filter { Double($0.sizeBytes) < Double(memory) * 0.6 }
        let newest = fitting.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        let apple = appleStatus == .available
        defaultModelId = newest.map { "ollama:\($0.name)" } ?? (apple ? Self.appleModelId : ollamaModels.first.map { "ollama:\($0.name)" })

        var list: [ModelOption] = []
        if apple {
            list.append(ModelOption(id: Self.appleModelId, displayName: "Apple Intelligence (on device)",
                                    detail: "Built into macOS · reads short passages", efforts: [],
                                    isDefault: defaultModelId == Self.appleModelId))
        }
        for m in ollamaModels {
            let id = "ollama:\(m.name)"
            let size = ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)
            list.append(ModelOption(id: id, displayName: Self.displayName(m.name), detail: "Ollama · \(size)",
                                    efforts: [], isDefault: defaultModelId == id))
        }
        if list != models { models = list }
        var lengths: [String: Int] = [:]
        for m in ollamaModels { lengths[m.name] = m.contextLength }
        LocalModelLimits.remember(contextLengths: lengths, defaultModel: defaultModelId)
    }

    /// "qwen3.5:4b" → "Qwen 3.5 · 4B" for suggested models; otherwise the name without ":latest".
    static func displayName(_ name: String) -> String {
        if let s = suggestionTitles[name] { return s }
        return name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
    }

    private static let suggestionTitles: [String: String] = {
        var out: [String: String] = [:]
        for s in suggestions { out[s.id] = s.title }
        return out
    }()

    /// Plain-language reason nothing can answer yet (empty when something can).
    public var unusableReason: String {
        var parts: [String] = []
        if case .unavailable(let why) = appleStatus { parts.append(why) }
        let ollama: String
        switch ollamaStatus {
        case .notInstalled: ollama = "Install Ollama to download a free AI model that runs on this Mac."
        case .notRunning:
            ollama = canOpenOllama ? "Open Ollama to use the models you downloaded."
                                   : "Start Ollama (in Terminal: ollama serve) to use the models you downloaded."
        case .ready(let names):
            ollama = names.isEmpty ? "Download a model with Ollama to answer questions on this Mac." : ""
        }
        if !ollama.isEmpty { parts.append(parts.isEmpty ? ollama : "Or " + ollama.prefix(1).lowercased() + ollama.dropFirst()) }
        return parts.joined(separator: " ")
    }

    private func updateAuth() {
        if isUsable {
            startingOllama?.cancel()
            startingOllama = nil
            setAuth(.signedIn(account: "On this Mac"))
        } else if startingOllama == nil {
            setAuth(.signedOut(reason: unusableReason))
        }
    }

    private func setAuth(_ state: AuthState) {
        guard state != authState else { return }
        authState = state
        for observer in observers { observer(state) }
    }

    /// While nothing is usable, check again now and then so a question waiting for setup is sent once
    /// Ollama starts, a model finishes downloading or Apple Intelligence is turned on.
    private func schedulePoll() {
        guard !isUsable else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let recent = Date().timeIntervalSince(self?.lastAction ?? .distantPast) < 120
                try? await Task.sleep(nanoseconds: (recent ? 5 : 30) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                if self.isUsable { break }
            }
            self?.pollTask = nil
        }
    }

    // MARK: - Ollama app

    public func openOllamaDownloadPage() {
        lastAction = Date()
        urlOpener(URL(string: "https://ollama.com/download")!)
    }

    /// Starts the installed Ollama app (in the background) and waits up to 30 s for its server.
    public func openOllama() {
        lastAction = Date()
        guard let app = Self.findOllamaApp() else {
            openOllamaDownloadPage()
            return
        }
        appOpener(app)
        guard startingOllama == nil else { return }
        if !isUsable { setAuth(.loggingIn(LoginProgress(message: "Starting Ollama…"))) }
        startingOllama = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if await self.client.version() != nil { break }
            }
            guard !Task.isCancelled, let self else { return }
            self.startingOllama = nil
            await self.refresh()
        }
    }

    static func findOllamaApp() -> URL? {
        for id in ["com.electron.ollama", "com.ollama.ollama"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
            .first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func ollamaCLI() -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Downloads

    /// Downloads a model with Ollama (/api/pull), updating `download` as it goes. Explicit user action only.
    public func downloadModel(_ name: String) async -> Bool {
        guard download == nil else { return false }
        lastAction = Date()
        downloadError = nil
        download = (name, 0, "Starting download…")
        let expected = Self.suggestions.first { $0.id == name }?.bytes ?? 0
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let bytes = try await self.client.openStream("/api/pull", ["model": name, "stream": true])
                var totals: [String: (total: Int64, done: Int64)] = [:]
                var progress = 0.0
                for try await line in bytes.lines {
                    guard let obj = JSONLine.parse(line) else { continue }
                    if let error = obj.str("error") { throw OllamaError.server(status: 200, message: error) }
                    let status = obj.str("status") ?? ""
                    if status == "success" { return true }
                    if let digest = obj.str("digest"), let total = (obj["total"] as? NSNumber)?.int64Value, total > 0 {
                        totals[digest] = (total, (obj["completed"] as? NSNumber)?.int64Value ?? 0)
                    }
                    let total = max(totals.values.reduce(0) { $0 + $1.total }, expected)
                    let done = totals.values.reduce(0) { $0 + $1.done }
                    if total > 0 { progress = max(progress, min(1, Double(done) / Double(total))) }
                    let text: String
                    if status.hasPrefix("pulling"), total > 0, done > 0 {
                        text = "Downloading… \(Self.gigabytes(done)) of \(Self.gigabytes(total))"
                    } else if status.hasPrefix("verifying") || status.hasPrefix("writing") {
                        text = "Finishing…"
                    } else {
                        text = "Starting download…"
                    }
                    self.download = (name, progress, text)
                }
                if !Task.isCancelled { self.downloadError = "The download stopped before it finished. Try again." }
            } catch {
                if Task.isCancelled { return false }
                if OllamaError.isUnreachable(error) {
                    self.downloadError = "Ollama isn't running. Open Ollama, then try again."
                } else if case OllamaError.server(_, let message) = error {
                    self.downloadError = message.contains("file does not exist")
                        ? "Ollama has no model called “\(name)”." : "Ollama couldn't download \(name): \(message)"
                } else {
                    self.downloadError = "Couldn't download \(name): \(error.localizedDescription)"
                }
            }
            return false
        }
        downloadTask = task
        let ok = await task.value
        downloadTask = nil
        download = nil
        await refresh()
        return ok
    }

    /// Stops the download; Ollama keeps the finished parts, so starting it again resumes.
    public func cancelDownload() {
        downloadTask?.cancel()
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
