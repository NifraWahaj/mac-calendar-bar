import AppKit
import SwiftUI

/// Colors, metrics and type ramp tuned to match the Microsoft Outlook menu bar popover.
enum Theme {

    // MARK: - Metrics

    static let popoverWidth: CGFloat = 360
    static let popoverHeight: CGFloat = 560
    static let horizontalPadding: CGFloat = 20
    static let gridGutter: CGFloat = 32
    static let cellSize: CGFloat = 36
    static let dayCircle: CGFloat = 30

    // MARK: - Palette

    /// Accent for the "today" badge, today's agenda header, selection ring and buttons.
    /// Driven by the palette the user picked in the "…" menu.
    static var accent: Color { ThemeManager.shared.accentColor }
    static let fallbackEventHex = "3F51B5"

    /// Approximates the fixed green Google's own clients use for `eventType: "birthday"`
    /// events. Google sends no color field for these at all, so this is a guess at parity
    /// with Google's UI, not a value read from the API.
    static let birthdayHex = "0B8043"

    static let popoverBackground = dynamic(light: .white, dark: NSColor(hex: "1E1E1E"))
    static let sectionHeaderBackground = dynamic(light: NSColor(hex: "F5F5F5"),
                                                 dark: NSColor(hex: "2A2A2A"))
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.08),
                                  dark: NSColor(white: 1, alpha: 0.10))

    static let primaryText = dynamic(light: NSColor(hex: "1A1A1A"), dark: NSColor(hex: "F2F2F2"))
    static let secondaryText = dynamic(light: NSColor(hex: "8C8C8C"), dark: NSColor(hex: "8E8E8E"))
    static let tertiaryText = dynamic(light: NSColor(hex: "A6A6A6"), dark: NSColor(hex: "747474"))
    static let iconTint = dynamic(light: NSColor(hex: "3C3C3C"), dark: NSColor(hex: "E0E0E0"))
    static let hoverFill = dynamic(light: NSColor(white: 0, alpha: 0.05),
                                   dark: NSColor(white: 1, alpha: 0.08))

    // MARK: - Type

    static let monthTitleFont = Font.system(size: 20, weight: .semibold)
    static let weekdayFont = Font.system(size: 12, weight: .semibold)
    static let dayNumberFont = Font.system(size: 14, weight: .regular)
    static let dayNumberTodayFont = Font.system(size: 14, weight: .semibold)
    static let monthBadgeFont = Font.system(size: 9, weight: .semibold)
    static let sectionHeaderFont = Font.system(size: 13, weight: .semibold)
    static let eventTitleFont = Font.system(size: 13, weight: .medium)
    static let eventDetailFont = Font.system(size: 11.5, weight: .regular)
    static let placeholderFont = Font.system(size: 13, weight: .regular)

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Hex helpers

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// Nudges an event color so it stays legible against the popover background.
    func legibleOnPopover() -> Color { self }
}

extension NSColor {
    convenience init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            self.init(srgbRed: 0.25, green: 0.32, blue: 0.71, alpha: 1)
            return
        }
        let hasAlpha = cleaned.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
