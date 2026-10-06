import AppKit
import LecternCore
import SwiftUI

/// One conversation's chat (a panel of the window's ConversationStack, under its title bar). Each part
/// is its own view so that streaming updates (which only touch `model.messages`) re-render only the
/// transcript. A narrow panel (two side by side) combines controls instead of shrinking text.
@MainActor
struct ChatPaneView: View {
    @Bindable var model: ChatModel

    /// At this panel width and below, the header and the input area use their compact forms (chat.css
    /// has the same breakpoint).
    static let compactWidth: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width <= Self.compactWidth
            VStack(spacing: 0) {
                ChatHeaderView(model: model, compact: compact)
                Divider()
                AuthBannerView(model: model)
                TranscriptSection(model: model)
                Divider()
                ChatInputArea(model: model, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct TranscriptSection: View {
    let model: ChatModel

    var body: some View {
        TranscriptWebView(messages: model.messages, documentTitle: model.document.title,
                          textSize: model.chatTextSize.points) { page, claim in
            model.goTo(page: page, claim: claim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))  // same color chat.css paints; shown while loading
    }
}

/// Message field and Send/Stop; below them the image and whole-document toggles, presets and the context
/// hint. A compact panel puts the toggles and presets in one "+" menu left of the field (with the hint
/// as its last line), so the input is a single row.
@MainActor
private struct ChatInputArea: View {
    @Bindable var model: ChatModel
    let compact: Bool
    @FocusState private var editorFocused: Bool

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var presetsEnabled: Bool {
        !(model.isBusy || model.creditsGuardActive || !model.authState.isSignedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The field keeps its place in the view tree in both forms, so it keeps the keyboard focus.
            HStack(alignment: .bottom, spacing: compact ? 6 : 8) {
                if compact { optionsMenu }
                editor
                sendOrStopButton
            }
            if !compact {
                HStack(spacing: 6) {
                    Toggle(isOn: $model.attachPageImage) {
                        Image(systemName: "photo")
                    }
                    .help("Attach page image — sends a picture of the current page (charts, scans, tables)")
                    .accessibilityLabel("Attach page image")

                    Toggle(isOn: $model.includeWholeDocument) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .help("Whole document — sends every page if it fits, otherwise the best-matching pages")
                    .accessibilityLabel("Whole document")

                    presetsMenu

                    Text(contextHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                        .help(contextHint)
                    Spacer(minLength: 0)
                }
                .toggleStyle(.button)
            }
        }
        .padding(compact ? 8 : 10)
        // Typing in a conversation makes it the one Ask Lectern goes to.
        .onChange(of: editorFocused) { _, focused in
            if focused { model.takeFocus() }
        }
        // A new conversation's input takes the keyboard focus.
        .task(id: model.inputFocusRequest) {
            guard model.inputFocusRequest > 0, !model.isCollapsed else { return }
            try? await Task.sleep(for: .milliseconds(50))
            editorFocused = true
        }
        // A collapsed panel's hidden input must not keep the keyboard.
        .onChange(of: model.isCollapsed) { _, collapsed in
            if collapsed { editorFocused = false }
        }
    }

    // MARK: Editor

    private var editorFont: Font { .system(size: model.chatTextSize.points) }

    private var editor: some View {
        // The hidden Text sizes the box (1 to 7 lines) and the editor overlays it, scrolling beyond that.
        // The trailing space keeps a trailing newline's empty line counted.
        Text(model.draft.isEmpty ? " " : model.draft + " ")
            .font(editorFont)
            .lineLimit(7)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .hidden()
            .overlay(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(editorFont)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .onKeyPress(.return, phases: .down, action: handleReturn)
                    .onKeyPress(.escape, phases: .down) { _ in showAllConversations() }
                    .accessibilityLabel("Message")
            }
            .overlay(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Ask about this document…")
                        .font(editorFont)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(editorFocused ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.28))
            )
    }

    /// Return sends; Shift-Return (or Option-Return) inserts a newline.
    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
        // Let an input method (Pinyin, Japanese, …) commit its composition instead of sending.
        let window = NSApp.currentEvent?.window ?? NSApp.keyWindow
        if let textView = window?.firstResponder as? NSTextView, textView.hasMarkedText() {
            return .ignored
        }
        send()
        return .handled
    }

    private func send() {
        guard canSend, !model.isBusy else { return }
        model.send()
    }

    /// Esc in the empty field of a conversation shown alone shows all of them again.
    private func showAllConversations() -> KeyPress.Result {
        guard model.isMaximized, model.draft.isEmpty else { return .ignored }
        model.toggleMaximize()
        return .handled
    }

    // MARK: Send / Stop

    @ViewBuilder private var sendOrStopButton: some View {
        if model.isBusy {
            Button {
                model.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.borderless)
            // Only the focused conversation's Stop answers ⌘. (several may be answering at once).
            .keyboardShortcut(model.isFocused ? KeyboardShortcut(".", modifiers: .command) : nil)
            .help(model.isFocused ? "Stop (⌘.)" : "Stop")
            .accessibilityLabel("Stop")
            .padding(.bottom, 4)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
            .padding(.bottom, 4)
        }
    }

    // MARK: Presets

    private var presetsMenu: some View {
        Menu {
            presetItems
        } label: {
            Image(systemName: "text.badge.star")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!presetsEnabled)
        .help("Presets — one-click questions about this document")
        .accessibilityLabel("Presets")
    }

    @ViewBuilder private var presetItems: some View {
        ForEach(ChatPreset.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
                ForEach(ChatPreset.all.filter { $0.group == group }) { preset in
                    Button(preset.title) {
                        model.takeFocus()
                        model.runPreset(preset)
                    }
                }
            }
        }
    }

    /// Compact panels: the two toggles (checkmarks), the presets and the context hint. Tinted while a
    /// toggle is on.
    private var optionsMenu: some View {
        Menu {
            Toggle("Attach Page Image", isOn: $model.attachPageImage)
            Toggle("Whole Document", isOn: $model.includeWholeDocument)
            Divider()
            Menu("Presets") { presetItems }
                .disabled(!presetsEnabled)
            Divider()
            Text(contextHint)
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(model.attachPageImage || model.includeWholeDocument ? Color.accentColor : .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 7)
        .help("Page image, whole document and presets — \(contextHint)")
        .accessibilityLabel("Context and presets")
    }

    // MARK: Context hint

    private var contextHint: String {
        guard model.document.pageCount > 0 else { return "Context: none" }
        let state = model.readingState
        var parts: [String] = []
        if model.includeWholeDocument {
            parts.append("whole document")
        } else {
            parts.append("around p. \(state.currentPage + 1)")
        }
        if let selection = state.selectionText, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("selection")
        }
        if model.attachPageImage {
            parts.append("page image")
        }
        return "Context: " + parts.joined(separator: " · ")
    }
}
