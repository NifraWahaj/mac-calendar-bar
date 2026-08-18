import Foundation
import SwiftUI

// MARK: - Google Calendar v3 wire types

struct CalendarListResponse: Decodable {
    let items: [CalendarListEntry]?
    let nextPageToken: String?
}

struct CalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let primary: Bool?
    let selected: Bool?
    let accessRole: String?
    let backgroundColor: String?
    let foregroundColor: String?
    let colorId: String?
    let hidden: Bool?
    let deleted: Bool?

    /// Include a calendar unless Google explicitly says it is hidden.
    ///
    /// `selected` documents a default of False, but it is omitted for plenty of real
    /// calendars that are ticked in the Google Calendar UI. Treating "absent" as hidden
    /// silently dropped most of the user's calendars, so only an explicit `false` excludes
    /// one now (the primary calendar is always included).
    var isVisible: Bool {
        if deleted == true { return false }
        if primary == true { return true }
        return selected != false
    }
}

struct ColorsResponse: Decodable {
    struct Definition: Decodable {
        let background: String?
        let foreground: String?
    }
    let event: [String: Definition]?
    let calendar: [String: Definition]?
}

struct EventsResponse: Decodable {
    let items: [RawEvent]?
    let nextPageToken: String?
}

struct RawEvent: Decodable {
    struct Timestamp: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }
        let entryPoints: [EntryPoint]?
    }

    /// Only the `self` flag is read; no email is ever surfaced in diagnostics.
    struct Person: Decodable {
        let `self`: Bool?
    }

    struct Attendee: Decodable {
        let email: String?
        let responseStatus: String?
        let `self`: Bool?
    }

    let id: String?
    let iCalUID: String?
    let status: String?
    let summary: String?
    let location: String?
    let colorId: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: Timestamp?
    let end: Timestamp?
    let conferenceData: ConferenceData?
    let attendees: [Attendee]?
    let transparency: String?
    let creator: Person?
    let organizer: Person?
    let eventType: String?
    /// Undocumented field carrying the newer "event label" swatch (the ~23-color extended
    /// picker in Google Calendar's UI), as opposed to the classic 11-value `colorId`. Google
    /// gives no endpoint to resolve this UUID to a color; see `EventLabelColors`.
    let eventLabelId: String?

    var videoLink: String? {
        if let hangoutLink { return hangoutLink }
        return conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
    }

    var selfResponseStatus: String? {
        attendees?.first { $0.`self` == true }?.responseStatus
    }
}

// MARK: - Google Tasks v1 wire types

struct TaskListsResponse: Decodable {
    let items: [RawTaskList]?
    let nextPageToken: String?
}

struct RawTaskList: Decodable {
    let id: String
    let title: String?
}

struct TasksResponse: Decodable {
    let items: [RawTask]?
    let nextPageToken: String?
}

struct RawTask: Decodable {
    let id: String
    let title: String?
    let notes: String?
    let status: String?
    /// RFC 3339 timestamp but always midnight UTC — Google Tasks due dates carry no time
    /// component regardless of what's sent, so only the date part is meaningful.
    let due: String?
    let completed: String?
}

// MARK: - View model

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let videoLink: String?
    let htmlLink: String?
    let colorHex: String
    let calendarName: String
    let isDeclined: Bool

    var color: Color { Color(hex: colorHex) }

    /// Whether this event occupies any part of the given day.
    func occurs(on day: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        // All-day events use an exclusive end date; timed events that end exactly at
        // midnight belong to the previous day only.
        if isAllDay {
            return start < dayEnd && end > dayStart
        }
        return start < dayEnd && max(end, start.addingTimeInterval(1)) > dayStart
    }

    var timeText: String {
        if isAllDay { return "All day" }
        let startText = start.formatted(date: .omitted, time: .shortened)
        let endText = end.formatted(date: .omitted, time: .shortened)
        if startText == endText { return startText }
        return "\(startText) – \(endText)"
    }
}

struct CalTask: Identifiable, Equatable {
    let id: String
    let taskListID: String
    let title: String
    let notes: String?
    /// Start-of-day; Google Tasks due dates have no time component.
    let dueDay: Date?

    var color: Color { Color(hex: Theme.taskHex) }
}

// MARK: - Date parsing

enum GoogleDateParser {
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let allDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Returns the parsed date plus whether it was an all-day (date-only) value.
    static func parse(_ timestamp: RawEvent.Timestamp?, timeZone: TimeZone) -> (date: Date, isAllDay: Bool)? {
        guard let timestamp else { return nil }
        if let dateTime = timestamp.dateTime {
            if let date = iso8601WithFraction.date(from: dateTime) ?? iso8601.date(from: dateTime) {
                return (date, false)
            }
            return nil
        }
        if let dateOnly = timestamp.date {
            allDay.timeZone = timeZone
            if let date = allDay.date(from: dateOnly) {
                return (date, true)
            }
        }
        return nil
    }
}
