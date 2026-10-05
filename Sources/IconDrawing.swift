import AppKit

/// Draws the app's magnifying glass with "IP" inside the lens.
enum IPIcon {
    /// Draws the glyph into `rect` (y-up coordinates) using `color`.
    static func drawGlyph(in rect: CGRect, color: NSColor) {
        let s = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }

        let center = p(0.41, 0.59)
        let radius = 0.355 * s
        let ringWidth = 0.085 * s

        color.setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        ring.lineWidth = ringWidth
        ring.stroke()

        let angle = -CGFloat.pi / 4
        let handleStart = CGPoint(x: center.x + cos(angle) * (radius + ringWidth * 0.3),
                                  y: center.y + sin(angle) * (radius + ringWidth * 0.3))
        let handle = NSBezierPath()
        handle.move(to: handleStart)
        handle.line(to: p(0.93, 0.07))
        handle.lineWidth = 0.15 * s
        handle.lineCapStyle = .round
        handle.stroke()

        let fontSize = 0.34 * s
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let text = NSAttributedString(string: "IP", attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: -0.02 * fontSize,
        ])
        let size = text.size()
        // Center on cap height rather than the line box so the letters sit visually centered.
        let baselineY = center.y - font.capHeight / 2
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: baselineY + font.descender))
    }

    /// Template image for the menu bar; macOS tints it for light/dark menu bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawGlyph(in: rect.insetBy(dx: 0.5, dy: 0.5), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "IP Toolkit"
        return image
    }

    /// Full-color application icon rendered at `pixels` x `pixels`.
    static func appIconBitmap(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let full = CGFloat(pixels)
        // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
        let inset = full * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: full - inset * 2, height: full - inset * 2)
        let shape = NSBezierPath(roundedRect: body, xRadius: full * 185 / 1024, yRadius: full * 185 / 1024)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -full * 10 / 1024)
        shadow.shadowBlurRadius = full * 20 / 1024
        shadow.set()
        NSColor(calibratedRed: 0.11, green: 0.33, blue: 0.75, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.60, blue: 0.98, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.09, green: 0.29, blue: 0.70, alpha: 1))!
        gradient.draw(in: shape, angle: -90)

        drawGlyph(in: body.insetBy(dx: body.width * 0.17, dy: body.height * 0.17), color: .white)
        return rep
    }
}
