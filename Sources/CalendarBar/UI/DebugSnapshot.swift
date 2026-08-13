import AppKit
import SwiftUI

/// Design aid: renders the popover contents to a PNG so the layout can be compared
/// against reference screenshots without opening the menu bar.
///
///   CALENDARBAR_DEMO=1 CALENDARBAR_EXPORT_PNG=/tmp/popover.png \
///     "dist/Calendar Bar.app/Contents/MacOS/CalendarBar"
///
/// Options:
///   CALENDARBAR_EXPORT_APPEARANCE=dark   render in dark mode
///   CALENDARBAR_EXPORT_EXPANDED=1        start with the full month grid
///
/// It snapshots a real `NSHostingView` (rather than SwiftUI's `ImageRenderer`, which
/// cannot rasterize `ScrollView` or AppKit-backed views) and exits when the file lands.
@MainActor
enum DebugSnapshot {

    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["CALENDARBAR_EXPORT_PNG"]
    }

    private static var window: NSWindow?

    static func export(store: CalendarStore, to path: String) {
        let environment = ProcessInfo.processInfo.environment
        if environment["CALENDARBAR_EXPORT_EXPANDED"] == "1" {
            store.isGridExpanded = true
        }

        if let paletteID = environment["CALENDARBAR_EXPORT_PALETTE"] {
            ThemeManager.shared.select(palette: Palette.named(paletteID))
        }

        let appearance: NSAppearance? = environment["CALENDARBAR_EXPORT_APPEARANCE"]?.lowercased() == "dark"
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
        NSApp.appearance = appearance

        let hosting = NSHostingView(rootView: PopoverRootView(store: store))
        let frame = NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: Theme.popoverHeight)
        hosting.frame = frame

        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.isOpaque = true
        window.level = .floating
        // On-screen so the window adopts the display's 2x backing scale.
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        self.window = window

        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Give SwiftUI a couple of display cycles to settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            capture(view: hosting, to: path)
        }
    }

    private static func capture(view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail("could not allocate a bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("PNG encoding failed")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardOutput.write(Data("snapshot: wrote \(path)\n".utf8))
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }
}
