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
                          textSize: model.chatTextSize.points,
                          fontFamily: model.chatFont.cssFamily) { page, claim in
            model.goTo(page: page, claim: claim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))  // same color chat.css paints; shown while loading
    }
}

/// Message field and Send/Stop; below them the image and whole-document toggles, presets, skills and the
/// context hint. A compact panel puts the toggles, presets and skills in one "+" menu left of the field
/// (with the hint as its last line), so the input is a single row. A chosen skill shows as a chip above
/// the field until the next send.
@MainActor
private struct ChatInputArea: View {
    @Bindable var model: ChatModel
    let compact: Bool
    @FocusState private var editorFocused: Bool
    @State private var showSkills = false

    /// A skill turn may go without text (it then asks to run the skill).
    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.armedSkill != nil
    }

    private var presetsEnabled: Bool {
        !(model.isBusy || model.creditsGuardActive || !model.authState.isSignedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let skill = model.armedSkill {
                SkillChip(skill: skill) { model.armedSkill = nil }
            }
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
                    skillsButton

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
        // Each provider has its own skills.
        .task(id: model.provider) { model.reloadSkills() }
    }

    // MARK: Editor

    private var editorFont: Font { .system(size: model.chatTextSize.points, design: model.chatFont.design) }

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
                    Text(model.armedSkill == nil ? "Ask about this document…" : "Add instructions for the skill (optional)…")
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

    // MARK: Skills

    private var skillsButton: some View {
        Button {
            showSkills.toggle()
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(model.armedSkill == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(SkillChip.accent))
        }
        .fixedSize()
        .disabled(model.installIssue != nil)
        .help("Skills — run one of your \(model.provider.displayName) skills with the next message (tools and network on; files go to ~/Documents/Lectern Output)")
        .accessibilityLabel("Skills")
        .popover(isPresented: $showSkills, arrowEdge: .top) {
            SkillPicker(model: model) { showSkills = false }
        }
    }

    /// Compact panels: the two toggles (checkmarks), the presets, skills and the context hint. Tinted while a
    /// toggle is on.
    private var optionsMenu: some View {
        Menu {
            Toggle("Attach Page Image", isOn: $model.attachPageImage)
            Toggle("Whole Document", isOn: $model.includeWholeDocument)
            Divider()
            Menu("Presets") { presetItems }
                .disabled(!presetsEnabled)
            Button("Skills…") { showSkills = true }
                .disabled(model.installIssue != nil)
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
        .help("Page image, whole document, presets and skills — \(contextHint)")
        .accessibilityLabel("Context, presets and skills")
        .popover(isPresented: $showSkills, arrowEdge: .top) {
            SkillPicker(model: model) { showSkills = false }
        }
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

// MARK: - Skill mode

/// "Skill: <name> · writes to Lectern Output · network on" above the message field; × removes it.
@MainActor
private struct SkillChip: View {
    /// Orange, darker in light mode so the text stays readable (chat.css `--skill`).
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.63, blue: 0.29, alpha: 1)
            : NSColor(srgbRed: 0.71, green: 0.33, blue: 0.04, alpha: 1)
    })

    let skill: SkillInfo
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            Text("Skill: \(skill.name) · writes to Lectern Output · network on")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Self.accent.opacity(0.8))
            .help("Remove the skill: the next message is a normal question")
            .accessibilityLabel("Remove skill")
        }
        .font(.callout)
        .foregroundStyle(Self.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Self.accent.opacity(0.35)))
        .help("""
            The next message runs the skill \(skill.name) with file tools and network access. It can write only \
            in ~/Documents/Lectern Output/<document>, never to the PDF. With network access, a PDF with hidden \
            instructions could make the skill send data out: use skills only with PDFs you trust.
            """)
    }
}

/// The provider's skills by source (name and description), with a search field for long lists. Picking one
/// arms it for the next send.
@MainActor
private struct SkillPicker: View {
    @Bindable var model: ChatModel
    let dismiss: () -> Void
    @State private var query = ""

    /// Lists longer than this get a search field.
    static let searchThreshold = 15

    private var groups: [(source: String, skills: [SkillInfo])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? model.skills : model.skills.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q)
        }
        var order: [String] = []
        var bySource: [String: [SkillInfo]] = [:]
        for skill in shown {
            if bySource[skill.source] == nil { order.append(skill.source) }
            bySource[skill.source, default: []].append(skill)
        }
        return order.map { source in
            (source, bySource[source, default: []].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(model.provider.displayName) Skills")
                    .font(.headline)
                Spacer(minLength: 4)
                if model.isLoadingSkills { ProgressView().controlSize(.small) }
                Button {
                    model.reloadSkills()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the skill list again")
                .accessibilityLabel("Reload skills")
            }
            if model.skills.count > Self.searchThreshold {
                TextField("Search skills", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            if model.skills.isEmpty {
                Text(model.isLoadingSkills ? "Loading skills…" : emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.source) { group in
                            Section {
                                ForEach(group.skills) { skill in
                                    SkillRow(skill: skill, isArmed: model.armedSkill == skill) {
                                        model.armedSkill = skill
                                        dismiss()
                                    }
                                }
                            } header: {
                                Text(group.source)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .background(.background)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
            Divider()
            Label("The skill runs with the next message, with file tools and network access. Files go to ~/Documents/Lectern Output.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(SkillChip.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 340)
        .task { model.reloadSkills() }
    }

    private var emptyText: String {
        switch model.provider {
        case .claude:
            return "No skills found. Lectern looks in ~/.claude/skills, in your Claude Code plugins and in the Claude app's skills."
        case .codex:
            return "No skills found. Lectern shows the skills that Codex reports, including ~/.codex/skills."
        }
    }
}

@MainActor
private struct SkillRow: View {
    let skill: SkillInfo
    let isArmed: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.name)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if isArmed { Image(systemName: "checkmark").foregroundStyle(SkillChip.accent) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(skill.description.isEmpty ? skill.path : skill.description)
    }
}
