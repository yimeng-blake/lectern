import AppKit
import LecternCore
import SwiftUI

/// The one banner above the transcript: install problems, sign-in, the credits guard, warnings —
/// in that priority order. Logins only ever start from these buttons. "Set Up…" opens the
/// "Choose your AI" window on the provider's card (installations and model downloads start there).
@MainActor
struct AuthBannerView: View {
    let model: ChatModel

    @State private var dismissedWarning: String?
    @State private var copiedCode: String?

    private enum Kind {
        case installIssue(String)
        case signedOut(String)
        case loggingIn(LoginProgress)
        /// The login state couldn't be established (status check failed, or a login attempt failed
        /// without a known prior state). Checking again comes before another login.
        case checkFailed(String)
        case creditsGuard(ChatModel.CreditsGuardReason)
        case warning(String)
    }

    private var kind: Kind? {
        if let issue = model.installIssue { return .installIssue(issue) }
        switch model.authState {
        case .signedOut(let reason): return .signedOut(reason)
        case .loggingIn(let progress): return .loggingIn(progress)
        case .failed(let message): return .checkFailed(message)
        case .unknown, .checking, .signedIn: break
        }
        if let reason = model.creditsGuardReason { return .creditsGuard(reason) }
        if let warning = model.lastWarning, !warning.isEmpty, warning != dismissedWarning { return .warning(warning) }
        return nil
    }

    var body: some View {
        if let kind {
            banner(kind)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func banner(_ kind: Kind) -> some View {
        switch kind {
        case .installIssue(let issue):
            BannerBox(tint: .orange, systemImage: "exclamationmark.triangle.fill") {
                message(issue)
                ButtonRow {
                    setUpButton(prominent: true)
                    if model.provider != .local {
                        // A path override for a CLI in an unusual place.
                        SettingsLink { Text("Open Settings") }
                    }
                }
            }

        case .signedOut(let reason) where model.provider == .local:
            // Nothing to sign in to: no model is ready on this Mac yet.
            BannerBox(tint: .orange, systemImage: "laptopcomputer.trianglebadge.exclamationmark") {
                message(reason)
                ButtonRow {
                    setUpButton(prominent: true)
                    Button("Check again") { model.recheckAuth() }
                }
            }

        case .signedOut(let reason):
            BannerBox(tint: .orange, systemImage: "person.crop.circle.badge.exclamationmark") {
                message(reason)
                ButtonRow {
                    loginButtons()
                    if model.provider == .claude {
                        // After a login in the user's own terminal (`claude auth login`).
                        Button("Check again") { model.recheckAuth() }
                            .help("Reads the login status again; doesn't log in")
                    }
                }
            }

        case .loggingIn(let progress):
            BannerBox(tint: .accentColor, systemImage: "person.crop.circle.badge.clock") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    message(progress.message)
                }
                if let code = progress.userCode, !code.isEmpty {
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copiedCode == code ? "Copied" : "Copy") { copy(code) }
                    }
                }
                HStack(spacing: 8) {
                    if let url = progress.url {
                        Link("Open sign-in page", destination: url)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelLogin() }
                }
            }

        case .checkFailed(let error):
            BannerBox(tint: .red, systemImage: "xmark.octagon.fill") {
                message(error)
                ButtonRow {
                    Button("Check again") { model.recheckAuth() }
                        .buttonStyle(.borderedProminent)
                        .help("Reads the login status again; doesn't log in")
                    loginButtons(prominent: false)
                }
            }

        case .creditsGuard(let reason):
            BannerBox(tint: .red, systemImage: "creditcard.trianglebadge.exclamationmark") {
                switch reason {
                case .exhausted:
                    message("Your included ChatGPT usage is used up. Sending now would spend purchased credits.")
                case .unknown:
                    message("Couldn't check your ChatGPT usage. If your included usage is used up, sending now would spend purchased credits.")
                }
                ButtonRow {
                    Button("Send anyway") { model.confirmSpendCredits() }
                    Button("Cancel") { model.cancelBlockedSend() }
                }
            }

        case .warning(let warning):
            BannerBox(tint: .secondary, systemImage: "info.circle.fill") {
                HStack(alignment: .top, spacing: 6) {
                    message(warning)
                    Spacer(minLength: 0)
                    Button {
                        dismissedWarning = warning
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Claude: only the Terminal login (Claude Code's own `claude auth login`; Lectern doesn't offer
    /// Claude.ai login in-app). ChatGPT and Grok: the browser sign-in plus the device-code alternative.
    /// On This Mac has no sign-in: "Set Up…".
    @ViewBuilder
    private func loginButtons(prominent: Bool = true) -> some View {
        switch model.provider {
        case .claude:
            loginButton("Log in in Terminal", method: .terminal, prominent: prominent)
                .help("Opens Terminal running Claude Code's own `claude auth login`")
        case .codex:
            loginButton("Sign in with ChatGPT", method: .browser, prominent: prominent)
            Button("Use a device code") { model.startLogin(.deviceCode) }
                .help("Shows a code to enter on the ChatGPT sign-in page")
        case .grok:
            loginButton("Sign in with Grok", method: .browser, prominent: prominent)
            Button("Use a device code") { model.startLogin(.deviceCode) }
                .help("Shows a code to enter on the Grok sign-in page")
        case .local:
            setUpButton(prominent: prominent)
        }
    }

    /// Opens "Choose your AI" on this provider's card.
    @ViewBuilder
    private func setUpButton(prominent: Bool) -> some View {
        let title = model.provider == .local ? "Set Up\u{2026}" : "Set Up \(model.provider.displayName)\u{2026}"
        if prominent {
            Button(title) { SetupWindow.shared.show(focus: model.provider) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(title) { SetupWindow.shared.show(focus: model.provider) }
        }
    }

    @ViewBuilder
    private func loginButton(_ title: String, method: LoginMethod, prominent: Bool) -> some View {
        if prominent {
            Button(title) { model.startLogin(method) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(title) { model.startLogin(method) }
        }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedCode = code
    }
}

/// The banner's buttons side by side, or one under another when a narrow panel can't fit them.
@MainActor
private struct ButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

@MainActor
private struct BannerBox<Content: View>: View {
    let tint: Color
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.system(size: 15))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}
