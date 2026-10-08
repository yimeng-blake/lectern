import Foundation

/// Progress of a one-click setup step (installing a CLI), for the "Choose your AI" screen and Settings.
public enum SetupState: Equatable, Sendable {
    case idle
    /// Message to show while it runs, e.g. "Installing Grok…".
    case running(String)
    case done
    case failed(String)
}

/// Runs a vendor's official install command, and only after an explicit user click. The command runs
/// under bash with `pipefail` (a failed download fails the step instead of feeding bash nothing) and a
/// clean environment; on failure the error carries the tail of the installer's output.
public enum OfficialInstaller {
    /// Anthropic's official Claude Code installer (native build into ~/.local/bin).
    public static let claudeCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    /// xAI's official Grok CLI installer (into ~/.grok/bin; it also adds that folder to the shell's PATH).
    public static let grokCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"

    static var timeout: TimeInterval = 15 * 60

    /// `environment` is added to the clean environment (tests point HOME and the vendor's install dir at scratch).
    public static func run(_ command: String, environment: [String: String]) async -> Result<Void, BackendError> {
        let r = await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"), ["-o", "pipefail", "-c", command],
                                        environment: CleanEnvironment.make(extra: environment),
                                        currentDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                                        timeout: timeout)
        if r.status == 0, !r.timedOut { return .success(()) }
        let tail = logTail(r.stderr.isEmpty ? r.stdout : r.stderr)
        if r.timedOut {
            return .failure(.notInstalled("The installer took too long and was stopped. Check your internet connection and try again."))
        }
        return .failure(.notInstalled("The installer stopped with an error (exit \(r.status))."
                                      + (tail.isEmpty ? "" : "\n\(tail)")))
    }

    /// Last few non-empty lines, without terminal colour codes.
    static func logTail(_ output: String, lines: Int = 6) -> String {
        let clean = output.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let kept = clean.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(lines).joined(separator: "\n")
        return String(kept.suffix(800))
    }
}
