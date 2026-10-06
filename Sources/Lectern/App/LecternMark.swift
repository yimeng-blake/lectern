import AppKit

/// The app icon's mark (an open book under two cobalt quote marks), drawn small for menus.
enum LecternMark {
    static let accent = NSColor(srgbRed: 0x2F / 255.0, green: 0x5B / 255.0, blue: 0xEA / 255.0, alpha: 1)

    /// 16 pt menu image. The book uses the menu's text color, so it reads in light and dark
    /// appearance; the quotes keep the icon's cobalt.
    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            // Geometry from design/icon/AppIcon-32.svg (y down), centered and scaled to 16 pt without the tile.
            let transform = NSAffineTransform()
            transform.translateX(by: 8, yBy: 8)
            transform.scale(by: 0.76)
            transform.translateX(by: -16, yBy: -16)
            transform.concat()

            accent.setFill()
            for x: CGFloat in [0, 7] {
                NSBezierPath(ovalIn: NSRect(x: 10 + x, y: 6, width: 5, height: 5)).fill()
                let tail = NSBezierPath()
                tail.move(to: NSPoint(x: 15 + x, y: 8.5))
                tail.curve(to: NSPoint(x: 11.125 + x, y: 14.5),
                           controlPoint1: NSPoint(x: 15 + x, y: 11.75), controlPoint2: NSPoint(x: 13.75 + x, y: 13.75))
                tail.curve(to: NSPoint(x: 12.75 + x, y: 10.988),
                           controlPoint1: NSPoint(x: 12.375 + x, y: 13.5), controlPoint2: NSPoint(x: 13.25 + x, y: 12.25))
                tail.close()
                tail.fill()
            }

            NSColor.labelColor.set()
            for mirrored in [false, true] {
                func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: mirrored ? 32 - x : x, y: y) }
                let page = NSBezierPath()
                page.move(to: p(14.5, 18.5))
                page.curve(to: p(7.5, 16), controlPoint1: p(12.4, 16.3), controlPoint2: p(9.25, 16))
                page.line(to: p(7.5, 23))
                page.curve(to: p(14.5, 25.5), controlPoint1: p(9.25, 23), controlPoint2: p(12.4, 23.3))
                page.close()
                page.lineWidth = 1
                page.lineJoinStyle = .round
                page.fill()
                page.stroke()
            }
            return true
        }
        // Re-draw for each appearance (the book color is resolved at draw time).
        image.cacheMode = .never
        image.accessibilityDescription = "Lectern"
        return image
    }()
}
