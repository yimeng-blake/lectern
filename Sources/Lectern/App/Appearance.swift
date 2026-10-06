import AppKit
import CoreImage

/// App-wide look, chosen in the toolbar's Appearance menu, View > Appearance, or Settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    /// Posted when the Dark Pages setting changes; reader windows re-filter their PDF views.
    static let lecternDarkPagesChanged = Notification.Name("lecternDarkPagesChanged")
}

/// "Dark Pages": draws PDF pages with inverted brightness for night reading. It only filters what
/// the views draw — the document, and the page images sent to the AI, are untouched.
@MainActor
enum PageInversion {
    /// Behind the inverted pages; filtered too, so it ends up dark (≈ 1 - 0.86).
    private static let invertedBackground = NSColor(white: 0.86, alpha: 1)

    static func apply(_ on: Bool, to pdfView: NSView, background: (NSColor) -> Void, thumbnails: NSView?) {
        for view in [pdfView, thumbnails].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            view.contentFilters = on ? filters() : []
        }
        background(on ? invertedBackground : .windowBackgroundColor)
    }

    /// Invert, then turn hues half a circle so colors keep roughly their original hue.
    private static func filters() -> [CIFilter] {
        guard let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust") else { return [] }
        hue.setValue(Double.pi, forKey: kCIInputAngleKey)
        return [invert, hue]
    }
}
