import Foundation

/// Maps Google's undocumented `eventLabelId` (the newer ~23-swatch "event label" picker) to
/// a hex color.
///
/// Unlike the classic `colorId` (1-11), Google's public Calendar API gives no endpoint that
/// resolves an `eventLabelId` UUID to a color — it is not in the v3 reference at all. The
/// working assumption, unverified beyond one account, is that these UUIDs are a fixed global
/// palette (the same swatch always has the same UUID for every user), which would make a
/// static table meaningful rather than account-specific guesswork.
///
/// The table lives in `~/Library/Application Support/CalendarBar/event-label-colors.json`
/// so it can grow by editing a file, not by shipping a new build. Entries are learned by
/// coloring a throwaway event with a known swatch, then reading its `eventLabelId` back via
/// `--diagnose` (see CalendarStore.colorDiagnostics()).
enum EventLabelColors {

    private static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CalendarBar", isDirectory: true)
    }()

    private static let fileURL = supportDirectory.appendingPathComponent("event-label-colors.json")

    /// `eventLabelId` (lowercase UUID) -> hex, learned from real events.
    private static var table: [String: String] = load()

    static func resolve(_ labelID: String?) -> String? {
        guard let labelID else { return nil }
        return table[labelID.lowercased()]
    }

    /// Records a new mapping and persists it immediately, so it survives past this launch
    /// and this rebuild. Returns `true` if this was a new or changed entry.
    @discardableResult
    static func record(labelID: String, hex: String) -> Bool {
        let key = labelID.lowercased()
        guard table[key] != hex else { return false }
        table[key] = hex
        save()
        return true
    }

    static var knownCount: Int { table.count }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
