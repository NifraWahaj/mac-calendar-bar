import AppKit

/// The menu bar mark: the same calendar language as the app icon (page, header band, today
/// dot), drawn as a template image so macOS tints it for light/dark menu bars and for the
/// highlighted state automatically.
enum StatusItemIcon {

    static func make(pointSize: CGFloat = 16) -> NSImage {
        let size = NSSize(width: pointSize + 2, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let page = rect.insetBy(dx: 1, dy: 0.5)
            let radius = page.width * 0.18
            let lineWidth: CGFloat = 1.3

            // Page outline.
            let outline = NSBezierPath(
                roundedRect: page.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                xRadius: radius, yRadius: radius
            )
            outline.lineWidth = lineWidth
            NSColor.black.setStroke()
            outline.stroke()

            // Solid header band, clipped to the page's rounded corners.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius).addClip()
            let headerHeight = page.height * 0.28
            NSColor.black.setFill()
            NSRect(x: page.minX, y: page.maxY - headerHeight,
                   width: page.width, height: headerHeight).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Today dot in the lower half.
            let dotRadius = page.width * 0.11
            let centerY = (page.minY + (page.maxY - headerHeight)) / 2
            NSBezierPath(ovalIn: NSRect(x: page.midX - dotRadius, y: centerY - dotRadius,
                                        width: dotRadius * 2, height: dotRadius * 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
