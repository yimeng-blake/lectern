import AppKit
import LecternCore
import SwiftUI

/// Shared pieces of the setup window's cards and of the rows in Settings > Accounts.

/// A tinted rounded square with the provider's symbol.
@MainActor
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [provider.setupTint.opacity(0.78), provider.setupTint],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: provider.setupSymbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: provider.setupTint.opacity(0.25), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

@MainActor
struct StatusPill: View {
    let status: SetupStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .ready:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            case .busy:
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            default:
                EmptyView()
            }
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(status.tint.opacity(0.13)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.title)")
    }
}

/// The material card used by the setup window (grid, open card and the small tiles). A light wash on the
/// material lifts the card off the window in light mode; in dark mode it stays a shade above it.
struct SetupCardBackground: ViewModifier {
    var highlighted = false
    var radius: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(Color.white.opacity(dark ? 0.04 : 0.72)))
            }
            .overlay(shape.strokeBorder(highlighted ? Color.accentColor.opacity(0.75)
                                                    : Color.primary.opacity(dark ? 0.12 : 0.07),
                                        lineWidth: highlighted ? 1.5 : 1))
            .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 12, y: 4)
    }
}

extension View {
    func setupCard(highlighted: Bool = false, radius: CGFloat = 16) -> some View {
        modifier(SetupCardBackground(highlighted: highlighted, radius: radius))
    }
}

/// The card's one button, or "In use" when the provider is ready and already chosen.
@MainActor
struct SetupPrimaryButton: View {
    let provider: Provider
    let model: SetupModel
    var large = true
    /// Opens the card (or the row) to show the next step.
    let expand: () -> Void

    var body: some View {
        if let action = model.primaryAction(provider) {
            let button = Button {
                if action.expands { expand() }
                action.perform()
            } label: {
                Text(action.title).frame(minWidth: large ? 64 : 44)
            }
            .controlSize(large ? .large : .regular)
            .accessibilityLabel("\(action.title): \(provider.displayName)")
            if action.prominent {
                button.buttonStyle(SetupProminentButtonStyle(large: large))
            } else {
                button.buttonStyle(.bordered)
            }
        } else if model.status(provider).isReady {
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(large ? .body.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(.green)
                .help("New conversations use \(provider.displayName)")
        }
    }
}

/// The main call to action: a filled accent capsule. SwiftUI's `.borderedProminent` draws white text on
/// a near-white fill while the window isn't key (e.g. while the user signs in in the browser), which hides
/// the one button that matters; this style keeps its color.
struct SetupProminentButtonStyle: ButtonStyle {
    var large = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, large ? 16 : 11)
            .frame(minHeight: large ? 28 : 22)
            .background(Capsule().fill(Color.accentColor.opacity(isEnabled ? 1 : 0.4)))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            .contentShape(Capsule())
    }
}

/// One of the three small cards under the open card; a click opens that card instead.
@MainActor
struct ProviderTile: View {
    let provider: Provider
    let model: SetupModel
    let select: () -> Void

    var body: some View {
        let status = model.status(provider)
        Button(action: select) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.headline).lineLimit(1)
                    Text(status.title).font(.caption).foregroundStyle(status.tint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .setupCard(highlighted: status.isReady && model.isInUse(provider), radius: 14)
        .accessibilityLabel("\(provider.displayName), \(status.title)")
        .accessibilityHint("Shows how to use \(provider.displayName)")
    }
}

/// Settings > Accounts: the card as a row. The next step opens under it while something runs, or when
/// the user asks for it.
@MainActor
struct ProviderSetupRow: View {
    let provider: Provider
    let model: SetupModel
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsFlow: Bool {
        expanded || model.status(provider).isBusy
    }

    var body: some View {
        let status = model.status(provider)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProviderIcon(provider: provider, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName).font(.headline)
                        StatusPill(status: status)
                    }
                    Text(model.account(provider) ?? provider.setupTagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // While something runs, the open flow below has its own Cancel.
                if !(showsFlow && model.canCancel(provider)) {
                    SetupPrimaryButton(provider: provider, model: model, large: false) { setExpanded(true) }
                }
                Button {
                    setExpanded(!expanded)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showsFlow ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(showsFlow ? "Hide details" : "Show details")
                .accessibilityLabel(showsFlow ? "Hide details" : "Show details")
            }
            if showsFlow {
                SetupFlowView(provider: provider, model: model, compact: true)
                    .padding(.leading, 44)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.88)) { expanded = value }
    }
}

/// Small colored circles for menu items. AppKit menus draw SwiftUI images as templates (one color), so
/// the dots are non-template NSImages.
@MainActor
enum StatusDot {
    private static var cache: [String: NSImage] = [:]

    static func image(_ status: SetupStatus) -> NSImage {
        let color: NSColor
        switch status {
        case .ready: color = .systemGreen
        case .signIn: color = .systemOrange
        case .setUp: color = .tertiaryLabelColor
        case .unavailable: color = .systemRed
        case .busy: color = .systemBlue
        }
        let key = color.description
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
