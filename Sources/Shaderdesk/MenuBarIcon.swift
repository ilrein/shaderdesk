import AppKit

/// The menu bar glyph: a small display with a four-point star on it ("a desk that
/// shines"). Drawn in code as a template image, so macOS tints it for light/dark
/// menu bars and the highlighted state.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // screen
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 4.75, width: 14.5, height: 10.5), xRadius: 2.2, yRadius: 2.2)
            screen.lineWidth = 1.5
            NSColor.black.setStroke()
            screen.stroke()
            // stand
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 6.0, y: 1.75)); stand.line(to: NSPoint(x: 12.0, y: 1.75))
            stand.lineWidth = 1.5; stand.lineCapStyle = .round
            stand.stroke()
            // four-point star: concave diamond centred on the screen
            let c = NSPoint(x: 9.0, y: 10.0), r = 3.6, w = 0.95
            let star = NSBezierPath()
            star.move(to: NSPoint(x: c.x, y: c.y + r))
            star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w * 0.35, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w * 0.35))
            star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w * 0.35), controlPoint2: NSPoint(x: c.x + w * 0.35, y: c.y - w))
            star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w * 0.35, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w * 0.35))
            star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w * 0.35), controlPoint2: NSPoint(x: c.x - w * 0.35, y: c.y + w))
            star.close()
            NSColor.black.setFill()
            star.fill()
            // a tiny companion star
            NSBezierPath(ovalIn: NSRect(x: 12.6, y: 12.1, width: 1.4, height: 1.4)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Shaderdesk"
        return img
    }()
}
