import Foundation

/// Maps Google's colors to the values the Google Calendar UI actually renders.
///
/// The Calendar v3 `colors` endpoint still returns the *legacy* palette (Banana is
/// `#fbd75b`), while Google Calendar on the web and on phones draws the *modern* palette
/// (Banana is `#f6bf26`). Using the endpoint values verbatim gives technically-correct but
/// visibly wrong colors, so event `colorId`s are resolved through the table below and any
/// legacy hex we receive is upgraded to its modern equivalent.
///
/// Anything unrecognised (a custom calendar color, or a new palette entry) passes through
/// untouched.
enum GoogleColors {

    /// Event `colorId` → modern hex. These are the eleven named event colors.
    static let eventColorsByID: [String: String] = [
        "1": "7986CB",  // Lavender
        "2": "33B679",  // Sage
        "3": "8E24AA",  // Grape
        "4": "E67C73",  // Flamingo
        "5": "F6BF26",  // Banana
        "6": "F4511E",  // Tangerine
        "7": "039BE5",  // Peacock
        "8": "616161",  // Graphite
        "9": "3F51B5",  // Blueberry
        "10": "0B8043", // Basil
        "11": "D50000"  // Tomato
    ]

    /// Legacy hex → modern hex, keyed lowercase without `#`.
    private static let legacyToModern: [String: String] = [
        // Legacy event palette (as returned by the `colors` endpoint).
        "a4bdfc": "7986CB", // Lavender
        "7ae7bf": "33B679", // Sage
        "dbadff": "8E24AA", // Grape
        "ff887c": "E67C73", // Flamingo
        "fbd75b": "F6BF26", // Banana
        "ffb878": "F4511E", // Tangerine
        "46d6db": "039BE5", // Peacock
        "e1e1e1": "616161", // Graphite
        "5484ed": "3F51B5", // Blueberry
        "51b749": "0B8043", // Basil
        "dc2127": "D50000", // Tomato

        // Legacy calendar palette (as returned for calendars).
        "d06b64": "E67C73", // Flamingo
        "f83a22": "D50000", // Tomato
        "fa573c": "F4511E", // Tangerine
        "ffad46": "F09300", // Mango
        "16a765": "0B8043", // Basil
        "7bd148": "7CB342", // Pistachio
        "fad165": "F6BF26", // Banana
        "92e1c0": "33B679", // Sage
        "9fe1e7": "039BE5", // Peacock
        "4986e7": "3F51B5", // Blueberry
        "9a9cff": "7986CB", // Lavender
        "c2c2c2": "616161"  // Graphite
    ]

    /// Upgrades a legacy hex to its modern counterpart, leaving unknown values alone.
    static func modernize(_ hex: String?) -> String? {
        guard let hex else { return nil }
        var key = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("#") { key.removeFirst() }
        return legacyToModern[key] ?? hex
    }

    /// The color Google Calendar shows for an event: its own `colorId` if it has one,
    /// otherwise the calendar's color.
    static func resolve(eventColorID: String?,
                        apiEventPalette: [String: String],
                        calendarHex: String?,
                        fallback: String) -> String {
        if let id = eventColorID {
            if let modern = eventColorsByID[id] { return modern }
            // Unknown id: fall back to whatever the API reported, modernized.
            if let fromAPI = modernize(apiEventPalette[id]) { return fromAPI }
        }
        return modernize(calendarHex) ?? fallback
    }
}
