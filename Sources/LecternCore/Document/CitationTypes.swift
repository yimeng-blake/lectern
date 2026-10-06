import Foundation

/// Result of checking one `[p. N]` citation in an answer against the cited pages' text.
public struct CitationCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Every number and quoted phrase in the claim appears on a cited page.
        case verified
        /// Some appear, some don't.
        case partial
        /// None of the checkable items appear on the cited pages.
        case notFound
        /// The citation names a page the document doesn't have.
        case pageMissing
        /// The claim has nothing checkable (no numbers or quotes); shown without a badge.
        case unchecked
    }

    /// 0-based order of this citation among all citations in the answer text.
    public var ordinal: Int
    /// 1-based pages the citation names (e.g. [pp. 3–5] → [3, 4, 5]).
    public var pages: [Int]
    /// The sentence (or clause) the citation supports, as plain text.
    public var claim: String
    public var status: Status
    /// Numbers / quoted phrases from the claim that were not found on the cited pages.
    public var missing: [String]

    public init(ordinal: Int, pages: [Int], claim: String, status: Status, missing: [String]) {
        self.ordinal = ordinal
        self.pages = pages
        self.claim = claim
        self.status = status
        self.missing = missing
    }
}
