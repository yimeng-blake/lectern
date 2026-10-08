import LecternCore
import SwiftUI

/// "Choose your AI": four cards in a 2×2 grid. A click on a card (or its button) opens it in place of
/// the grid, with its short flow; the other three become small tiles below it.
@MainActor
struct ChooseAIView: View {
    @Bindable var model: SetupModel
    let done: () -> Void

    @Namespace private var cards
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var anyReady: Bool { Provider.setupOrder.contains { model.status($0).isReady } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let focused = model.focused {
                    openLayout(focused)
                } else {
                    grid
                }
            }
            .padding(.top, 22)
            .frame(maxHeight: .infinity, alignment: .top)
            footer
                .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: SetupWindow.size.width, height: SetupWindow.size.height)
        .background(SetupBackdrop())
        .background {
            // Escape closes an open card first, then the window.
            Button("") { model.focused == nil ? done() : focus(nil) }
                .keyboardShortcut(.cancelAction)
                .focusable(false)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose your AI")
                .font(.system(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("Ask about your PDFs with the AI you already use — or one that runs on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                card(.local)
                card(.codex)
            }
            GridRow {
                card(.claude)
                card(.grok)
            }
        }
    }

    private func card(_ p: Provider) -> some View {
        ProviderGridCard(provider: p, model: model) { focus(p) }
            .matchedGeometryEffect(id: p, in: cards)
    }

    private func openLayout(_ p: Provider) -> some View {
        VStack(spacing: 12) {
            OpenProviderCard(provider: p, model: model) { focus(nil) }
                .matchedGeometryEffect(id: p, in: cards)
            HStack(spacing: 12) {
                ForEach(Provider.setupOrder.filter { $0 != p }) { other in
                    ProviderTile(provider: other, model: model) { focus(other) }
                        .matchedGeometryEffect(id: other, in: cards)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Text("You can change this later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if anyReady {
                Button(action: done) { Text("Done").frame(minWidth: 64) }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(action: done) { Text("Done").frame(minWidth: 64) }
                    .controlSize(.large)
            }
        }
    }

    private func focus(_ p: Provider?) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86)) {
            model.focused = p
        }
    }
}

/// A soft wash behind the cards, so the material cards stand out in light and dark mode.
@MainActor
private struct SetupBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if colorScheme == .light { Color.black.opacity(0.035) }
            LinearGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.06), .clear],
                           startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// One card of the grid: icon and status, name, one line, and the one button.
@MainActor
private struct ProviderGridCard: View {
    let provider: Provider
    let model: SetupModel
    let open: () -> Void

    var body: some View {
        let status = model.status(provider)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ProviderIcon(provider: provider, size: 40)
                Spacer(minLength: 8)
                StatusPill(status: status)
            }
            Text(provider.displayName)
                .font(.title3.weight(.semibold))
                .padding(.top, 12)
            Text(model.account(provider) ?? provider.setupTagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            Spacer(minLength: 10)
            HStack {
                SetupPrimaryButton(provider: provider, model: model, expand: open)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(height: 32)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
        .setupCard(highlighted: status.isReady && model.isInUse(provider))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName), \(status.title)")
        .accessibilityAction(named: "Show details", open)
    }
}

/// The open card: header, then the flow (scrolls when long, e.g. the model list).
@MainActor
private struct OpenProviderCard: View {
    let provider: Provider
    let model: SetupModel
    let close: () -> Void

    var body: some View {
        let status = model.status(provider)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ProviderIcon(provider: provider, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(provider.displayName).font(.title2.weight(.semibold))
                        StatusPill(status: status)
                    }
                    Text(provider.setupTagline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Show all choices")
                .accessibilityLabel("Show all choices")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)
            ScrollView {
                SetupFlowView(provider: provider, model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .scrollIndicators(.automatic)
            // Long content (the model list) fades out at the card's edge instead of being cut.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .setupCard(highlighted: status.isReady && model.isInUse(provider))
        .accessibilityElement(children: .contain)
    }
}
