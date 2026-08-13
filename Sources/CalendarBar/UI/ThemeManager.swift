import AppKit
import Combine
import SwiftUI

/// An accent palette. Only the accent varies — the popover keeps its Outlook-style
/// neutral background so it still reads as a system menu bar surface.
struct Palette: Identifiable, Equatable {
    enum Accent: Equatable {
        case fixed(light: String, dark: String)
        /// Follows System Settings → Appearance → accent color.
        case systemAccent
    }

    let id: String
    let name: String
    let accent: Accent

    /// A representative swatch for menus (the light-mode accent).
    var swatchHex: String {
        switch accent {
        case .fixed(let light, _): return light
        case .systemAccent: return "007AFF"
        }
    }

    func accentColor() -> Color {
        switch accent {
        case .systemAccent:
            return Color(nsColor: .controlAccentColor)
        case .fixed(let light, let dark):
            return Theme.dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
        }
    }
}

extension Palette {
    /// Dark variants are lightened a little so they hold up against the dark popover.
    static let all: [Palette] = [
        Palette(id: "outlook-green", name: "Outlook Green",
                accent: .fixed(light: "2E9E67", dark: "3EB47A")),
        Palette(id: "outlook-blue", name: "Outlook Blue",
                accent: .fixed(light: "0F6CBD", dark: "479EF5")),
        Palette(id: "blueberry", name: "Blueberry",
                accent: .fixed(light: "3F51B5", dark: "7986CB")),
        Palette(id: "grape", name: "Grape",
                accent: .fixed(light: "8E24AA", dark: "BA68C8")),
        Palette(id: "tomato", name: "Tomato",
                accent: .fixed(light: "D50000", dark: "F26D6D")),
        Palette(id: "tangerine", name: "Tangerine",
                accent: .fixed(light: "F4511E", dark: "FF8A65")),
        Palette(id: "peacock", name: "Peacock",
                accent: .fixed(light: "039BE5", dark: "4FC3F7")),
        Palette(id: "graphite", name: "Graphite",
                accent: .fixed(light: "5A5A5A", dark: "A8A8A8")),
        Palette(id: "system", name: "Match macOS Accent", accent: .systemAccent)
    ]

    static let fallback = all[0]

    static func named(_ id: String?) -> Palette {
        all.first { $0.id == id } ?? fallback
    }
}

/// Light/dark override for the popover.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Holds the selected palette and appearance, persisted in `UserDefaults`.
///
/// Not actor-isolated so `Theme`'s static color accessors can read it; every mutation goes
/// through the main thread from menu actions.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private enum Keys {
        static let palette = "theme.palette"
        static let appearance = "theme.appearance"
    }

    @Published private(set) var palette: Palette
    @Published private(set) var appearance: AppearanceMode
    /// Bumped on every change; the root view keys off this to rebuild the whole tree so
    /// deeply nested views cannot hold on to a stale accent.
    @Published private(set) var revision = 0

    private var accentObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        palette = Palette.named(defaults.string(forKey: Keys.palette))
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
            ?? .system

        // "Match macOS Accent" needs to follow live changes in System Settings.
        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.palette.accent == .systemAccent else { return }
            self.revision += 1
        }
    }

    var accentColor: Color { palette.accentColor() }

    func select(palette newValue: Palette) {
        guard newValue != palette else { return }
        palette = newValue
        UserDefaults.standard.set(newValue.id, forKey: Keys.palette)
        revision += 1
    }

    func select(appearance newValue: AppearanceMode) {
        guard newValue != appearance else { return }
        appearance = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Keys.appearance)
        applyAppearance()
        revision += 1
    }

    /// Applies the stored appearance to the app. Call once at launch.
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}
