// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

public enum AppIcon {
    /// One silhouette at both sizes: a keyboard flowing into a phone.
    public static func drawMark(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        (transform as NSAffineTransform).concat()
        NSAffineTransform().applyScale(rect.width / 32, rect.height / 32)
        color.setStroke(); color.setFill()
        let phone = NSBezierPath()
        phone.move(to: NSPoint(x: 19, y: 20))
        phone.line(to: NSPoint(x: 19, y: 27))
        phone.curve(to: NSPoint(x: 22, y: 30), controlPoint1: NSPoint(x: 19, y: 29), controlPoint2: NSPoint(x: 20, y: 30))
        phone.line(to: NSPoint(x: 27, y: 30))
        phone.curve(to: NSPoint(x: 30, y: 27), controlPoint1: NSPoint(x: 29, y: 30), controlPoint2: NSPoint(x: 30, y: 29))
        phone.line(to: NSPoint(x: 30, y: 11))
        phone.curve(to: NSPoint(x: 27, y: 8), controlPoint1: NSPoint(x: 30, y: 9), controlPoint2: NSPoint(x: 29, y: 8))
        phone.lineWidth = 2; phone.lineCapStyle = .round; phone.stroke()
        let keyboard = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 22, height: 14), xRadius: 3, yRadius: 3)
        keyboard.lineWidth = 2; keyboard.stroke()
        for x in [6, 11, 16] { NSBezierPath(roundedRect: NSRect(x: x, y: 11, width: 3, height: 2), xRadius: 0.7, yRadius: 0.7).fill() }
        NSBezierPath(roundedRect: NSRect(x: 7, y: 6, width: 12, height: 2), xRadius: 1, yRadius: 1).fill()
    }
    public static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: 1, dy: 1), color: .black); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WiFi Remote Input"
        return image
    }
}
private extension NSAffineTransform {
    func applyScale(_ x: CGFloat, _ y: CGFloat) { scaleX(by: x, yBy: y); concat() }
}
