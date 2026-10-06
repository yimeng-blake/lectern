import AppKit
import LecternCore
import SwiftUI

/// The one banner above the transcript: install problems, sign-in, the credits guard, warnings —
/// in that priority order. Logins only ever start from these buttons.
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
                HStack {
                    SettingsLink { Text("Open Settings") }
                }
            }

        case .signedOut(let reason):
            BannerBox(tint: .orange, systemImage: "person.crop.circle.badge.exclamationmark") {
                message(reason)
                HStack(spacing: 8) {
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
                HStack(spacing: 8) {
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
                HStack(spacing: 8) {
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
    /// Claude.ai login in-app). ChatGPT: Codex's browser sign-in plus its device-code alternative.
    @ViewBuilder
    private func loginButtons(prominent: Bool = true) -> some View {
        switch model.provider {
        case .claude:
            loginButton("Log in in Terminal", method: .terminal, prominent: prominent)
                .help("Opens Terminal running Claude Code's own `claude auth login`")
        case .codex:
            HStack(spacing: 8) {
                loginButton("Sign in with ChatGPT", method: .browser, prominent: prominent)
                Button("Use a device code") { model.startLogin(.deviceCode) }
                    .help("Shows a code to enter on the ChatGPT sign-in page")
            }
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
