import AppKit
import SwiftUI

/// The "..." button in the header.
///
/// This uses a real `NSMenu` rather than SwiftUI's `Menu`: inside a status-bar popover a
/// native menu positions correctly under the button and does not fight the popover for
/// first-responder status.
struct OptionsMenuButton: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.iconTint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Theme.hoverFill : Color.clear)
            )
            .overlay(MenuClickCatcher { buildMenu() })
            .onHover { isHovering = $0 }
            .help("Options")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if store.showsCalendar {
            menu.addItem(ClosureMenuItem(title: "Refresh Now", key: "r") { store.refresh() })
            menu.addItem(ClosureMenuItem(title: "Go to Today", key: "t") { store.goToToday() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Open Google Calendar", key: "") {
                store.openGoogleCalendar()
            })
            menu.addItem(ClosureMenuItem(title: "New Event…", key: "n") { store.createEvent() })
            menu.addItem(.separator())

            if let email = store.auth.accountEmail {
                menu.addItem(disabledItem(email))
            }
            if let updated = store.lastUpdated {
                let time = updated.formatted(date: .omitted, time: .shortened)
                menu.addItem(disabledItem("Updated \(time)"))
            }
            if store.auth.isSignedIn {
                menu.addItem(ClosureMenuItem(title: "Sign Out", key: "") { store.signOut() })
            }
        } else {
            menu.addItem(ClosureMenuItem(title: "Sign In with Google", key: "") { store.signIn() })
        }

        menu.addItem(.separator())
        menu.addItem(appearanceItem())
        menu.addItem(paletteItem())

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Calendar Bar", key: "q") {
            NSApplication.shared.terminate(nil)
        })
        return menu
    }

    // MARK: - Theme submenus

    private func paletteItem() -> NSMenuItem {
        let submenu = NSMenu()
        for palette in Palette.all {
            let item = ClosureMenuItem(title: palette.name, key: "") {
                ThemeManager.shared.select(palette: palette)
            }
            item.image = Self.swatch(hex: palette.swatchHex, isSystem: palette.accent == .systemAccent)
            item.state = palette.id == theme.palette.id ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Color Palette", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func appearanceItem() -> NSMenuItem {
        let submenu = NSMenu()
        for mode in AppearanceMode.allCases {
            let item = ClosureMenuItem(title: mode.title, key: "") {
                ThemeManager.shared.select(appearance: mode)
            }
            item.state = mode == theme.appearance ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// A small rounded color chip shown next to each palette name.
    private static func swatch(hex: String, isSystem: Bool) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = isSystem ? NSColor.controlAccentColor : NSColor(hex: hex)
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: 3, yRadius: 3).fill()
            return true
        }
        return image
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - Plumbing

/// An `NSMenuItem` that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

/// A transparent overlay that pops a native menu beneath itself on click.
private struct MenuClickCatcher: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> NSView {
        ClickView(makeMenu: makeMenu)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.makeMenu = makeMenu
    }

    private final class ClickView: NSView {
        var makeMenu: () -> NSMenu

        init(makeMenu: @escaping () -> NSMenu) {
            self.makeMenu = makeMenu
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        override func mouseDown(with event: NSEvent) {
            let menu = makeMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: bounds.height + 4),
                       in: self)
        }
    }
}
