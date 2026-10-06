import Foundation

/// Actions in the PDF selection's context menu ("Ask Lectern"). Each sends a ready-made question
/// about the selected text to the current provider.
enum SelectionAction: String, CaseIterable, Identifiable {
    case explain, summarize, define, translateChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: return "Explain"
        case .summarize: return "Summarize"
        case .define: return "Define Terms"
        case .translateChinese: return "Translate to Chinese"
        }
    }

    /// The question; the selection itself travels in the context envelope as usual.
    var prompt: String {
        switch self {
        case .explain:
            return "Explain the selected passage in plain language. Say what it means in the context of this document."
        case .summarize:
            return "Summarize the selected passage in 2–4 bullet points. Keep every number."
        case .define:
            return "Define the technical terms, acronyms and metrics in the selected passage, as they are used in this document."
        case .translateChinese:
            return "Translate the selected passage into native-quality Simplified Chinese. Keep numbers, units and company names exact. Avoid translationese: write it the way a Chinese financial analyst would. Output only the translation."
        }
    }
}

/// One-click prompts in the chat pane's Presets menu.
struct ChatPreset: Identifiable, Hashable {
    enum Group: String, CaseIterable { case general = "General", finance = "Finance" }

    let id: String
    let group: Group
    let title: String
    let prompt: String
    /// Send with "Whole document" on for this question only.
    let wholeDocument: Bool

    static let all: [ChatPreset] = [
        ChatPreset(id: "summarize-page", group: .general, title: "Summarize This Page",
                   prompt: "Summarize the current page in 3–6 bullet points. Keep every number.", wholeDocument: false),
        ChatPreset(id: "summarize-doc", group: .general, title: "Summarize the Document",
                   prompt: "Summarize the whole document: its purpose, the main points, and the key numbers, with page citations.",
                   wholeDocument: true),
        ChatPreset(id: "takeaways", group: .general, title: "Key Takeaways",
                   prompt: "What are the 5 most important takeaways from the pages provided? One line each, with page citations.",
                   wholeDocument: false),
        ChatPreset(id: "critique", group: .general, title: "Weak Points in the Argument",
                   prompt: "List the weakest points, unsupported claims, or missing evidence in the argument on the pages provided, with page citations.",
                   wholeDocument: false),
        ChatPreset(id: "kpi-table", group: .finance, title: "KPI Table",
                   prompt: "Extract the key financial and operating metrics into a Markdown table with the columns Metric | Period | Value | Change (YoY or QoQ, if stated) | Page. Use only numbers stated in the document; do not compute new ones unless you label them as computed.",
                   wholeDocument: true),
        ChatPreset(id: "guidance", group: .finance, title: "Guidance vs. Prior Period",
                   prompt: "Find the forward guidance in the document and compare it with the prior period's actual results (and prior guidance, if stated). Use a Markdown table: Item | Guidance | Prior actual | Implied change | Page.",
                   wholeDocument: true),
        ChatPreset(id: "segments", group: .finance, title: "Segment / Region Breakdown",
                   prompt: "Build a Markdown table of revenue (and margin or growth, if stated) by segment and by region, with page citations.",
                   wholeDocument: true),
        ChatPreset(id: "risks", group: .finance, title: "Risks and Red Flags",
                   prompt: "List the risks, one-off items, accounting changes, and red flags an analyst should notice, with page citations.",
                   wholeDocument: true),
    ]
}

/// Where the reader should go when a citation is clicked: the page, and the claim text that
/// cited it so the reader can highlight the supporting passage.
struct PassageRequest: Equatable {
    /// 0-based page index.
    let page: Int
    /// Sentence that carried the citation; nil when only the page is known.
    let claim: String?
    /// Distinguishes repeated clicks on the same citation.
    let id = UUID()
}
