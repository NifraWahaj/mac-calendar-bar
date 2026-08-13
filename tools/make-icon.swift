// Generates Resources/AppIcon.icns (and a preview PNG) for Calendar Bar.
//
//   swift tools/make-icon.swift
//
// The mark is deliberately minimal: a rounded calendar body, a solid header bar, and a
// single dot for "today" — the same shape the menu bar template icon draws, so the app
// icon and the status item read as one family.

import AppKit
import Foundation

// MARK: - Geometry shared with the menu bar icon

/// Draws a calendar page: a solid `page`-colored sheet, a `header`-colored band across the
/// top, and a single `header`-colored dot marking today. Normalized to a `size` box.
func drawCalendarMark(size: CGFloat, page: NSColor, header: NSColor, drawNubs: Bool = true) {
    let pageRect = NSRect(x: 0, y: 0, width: size, height: size * 0.92)
    let radius = size * 0.15
    let pagePath = NSBezierPath(roundedRect: pageRect, xRadius: radius, yRadius: radius)

    page.setFill()
    pagePath.fill()

    // Header band, clipped to the page so it inherits the rounded top corners.
    NSGraphicsContext.saveGraphicsState()
    pagePath.addClip()
    let headerHeight = pageRect.height * 0.30
    header.setFill()
    NSRect(x: pageRect.minX, y: pageRect.maxY - headerHeight,
           width: pageRect.width, height: headerHeight).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Two binding nubs punched out of the header, which is what makes it read as a
    // calendar rather than a generic card. Below ~128px they are sub-pixel, so they are
    // dropped and the header reads as a clean solid band instead.
    if drawNubs {
        let nubWidth = size * 0.075
        let nubHeight = headerHeight * 0.52
        let nubY = pageRect.maxY - headerHeight * 0.78
        page.setFill()
        for fraction in [0.32, 0.68] {
            let rect = NSRect(x: pageRect.minX + pageRect.width * fraction - nubWidth / 2,
                              y: nubY, width: nubWidth, height: nubHeight)
            NSBezierPath(roundedRect: rect, xRadius: nubWidth / 2, yRadius: nubWidth / 2).fill()
        }
    }

    // Today dot, centered in the sheet below the header.
    let dotRadius = size * 0.115
    let bodyCenterY = (pageRect.minY + (pageRect.maxY - headerHeight)) / 2
    header.setFill()
    NSBezierPath(ovalIn: NSRect(x: pageRect.midX - dotRadius, y: bodyCenterY - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2)).fill()
}

// MARK: - App icon

func makeAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS app icons sit in a rounded rect inset from the canvas.
    let inset = size * 0.098
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = plate.width * 0.2237
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

    // Accent gradient, matching the app's default Outlook Green palette.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.69, blue: 0.46, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.46, blue: 0.30, alpha: 1)
    ])
    gradient?.draw(in: platePath, angle: -90)

    // A soft top highlight so the plate is not flat.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
              angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The mark, centered in the plate.
    let markSize = plate.width * 0.58
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: plate.midX - markSize / 2, yBy: plate.midY - markSize * 0.92 / 2)
    transform.concat()
    drawCalendarMark(size: markSize,
                     page: .white,
                     header: NSColor(srgbRed: 0.11, green: 0.44, blue: 0.29, alpha: 1),
                     drawNubs: size >= 128)
    NSGraphicsContext.restoreGraphicsState()

    return image
}

func png(from image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// name -> pixel size, per Apple's iconset conventions.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in variants {
    let icon = makeAppIcon(size: CGFloat(pixels))
    guard let data = png(from: icon, pixels: pixels) else {
        FileHandle.standardError.write(Data("failed rendering \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

// A standalone preview for the README / design review.
let previews = root.appendingPathComponent("docs/previews")
try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
if let data = png(from: makeAppIcon(size: 512), pixels: 512) {
    try data.write(to: previews.appendingPathComponent("app-icon.png"))
}

print("wrote \(iconset.path)")
