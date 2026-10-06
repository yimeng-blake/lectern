import Foundation

/// A skill the provider's own harness can run (Agent Skills format: a folder with SKILL.md).
public struct SkillInfo: Identifiable, Hashable, Sendable {
    /// Unique per provider: the skill folder's absolute path.
    public var id: String { path }
    /// Name from SKILL.md front matter (what the harness invokes).
    public let name: String
    public let description: String
    /// Absolute path of the skill folder (the one containing SKILL.md).
    public let path: String
    /// Where it comes from, for grouping in the menu, e.g. "Claude app", "~/.claude/skills", "Plugin: codex", "Codex".
    public let source: String

    public init(name: String, description: String, path: String, source: String) {
        self.name = name
        self.description = description
        self.path = path
        self.source = source
    }
}

/// Everything a backend needs to run one turn in skill mode. Normal turns have no SkillTurn and stay
/// tool-free; a skill turn runs the provider's harness with that skill, file tools and network, sandboxed
/// so it can write only inside `outputFolder`.
public struct SkillTurn: Sendable {
    public let skill: SkillInfo
    /// ~/Documents/Lectern Output/<document>/ — created by the app; the turn's working directory.
    public let outputFolder: URL
    /// The document's full text (OCR included), written by the app into the output folder for the skill to read.
    public let documentTextFile: URL?
    /// The original PDF, read-only (never written).
    public let pdfFile: URL?

    public init(skill: SkillInfo, outputFolder: URL, documentTextFile: URL?, pdfFile: URL?) {
        self.skill = skill
        self.outputFolder = outputFolder
        self.documentTextFile = documentTextFile
        self.pdfFile = pdfFile
    }
}
