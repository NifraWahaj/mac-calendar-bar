import AppKit
import Combine
import Foundation

/// Owns authentication state, the fetched event cache, and the calendar navigation state
/// that the popover renders.
@MainActor
final class CalendarStore: ObservableObject {

    // Data
    @Published private(set) var events: [CalEvent] = [] {
        didSet { rebuildDayIndex() }
    }
    /// Start-of-day dates that have at least one event, for the grid's activity dots.
    private var daysWithEvents: Set<Date> = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    /// Incomplete tasks across every task list, sorted with due tasks first (earliest due
    /// first), then undated tasks. Completed tasks are excluded at fetch time (see
    /// GoogleTasksAPI.fetchTasks), so this list is exactly what still needs doing.
    @Published private(set) var tasks: [CalTask] = []
    /// Task ids currently being marked complete, so their row can show a spinner and
    /// resist double-taps until the server confirms.
    @Published private(set) var completingTaskIDs: Set<String> = []

    // Navigation
    /// The day the agenda starts from (defaults to today).
    @Published var anchorDate: Date
    /// The month the grid is showing, as the first day of that month.
    @Published var visibleMonth: Date
    /// `true` shows the full month grid, `false` shows just the anchor's week.
    @Published var isGridExpanded = false

    let auth = OAuthManager()

    /// `CALENDARBAR_DEMO=1` fills the popover with sample events so the UI can be
    /// previewed (and screenshot-compared) without signing in to Google.
    let isDemoMode = ProcessInfo.processInfo.environment["CALENDARBAR_DEMO"] == "1"

    /// Whether to show the calendar + agenda rather than the sign-in panel.
    var showsCalendar: Bool { auth.isSignedIn || isDemoMode }

    var calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 1 // Sunday-first, matching the Outlook popover.
        return calendar
    }()

    private var api: GoogleCalendarAPI!
    private var tasksAPI: GoogleTasksAPI!
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// hex colors keyed by calendar id, plus the palette used for per-event `colorId`s.
    private var calendarColors: [String: String] = [:]
    private var calendarNames: [String: String] = [:]
    private var eventPalette: [String: String] = [:]
    private var calendarPalette: [String: String] = [:]

    // Diagnostics only (see colorDiagnostics()).
    private var calendarDebugRows: [String] = []
    private var eventDebugRows: [String] = []
    private var eventsWithOwnColor = 0

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        anchorDate = today
        visibleMonth = Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        api = GoogleCalendarAPI(tokenProvider: { [auth] force in
            try await auth.accessToken(forceRefresh: force)
        })
        tasksAPI = GoogleTasksAPI(tokenProvider: { [auth] force in
            try await auth.accessToken(forceRefresh: force)
        })

        // Re-render (and re-fetch) when the signed-in state changes.
        auth.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                self.objectWillChange.send()
                if signedIn {
                    self.refresh()
                } else {
                    self.events = []
                    self.lastUpdated = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        if isDemoMode { loadDemoEvents() }
        // A Keychain read that failed (rather than finding nothing) must be explained
        // instead of silently showing the sign-in panel.
        if let warning = auth.keychainWarning { errorMessage = warning }
        if auth.isSignedIn { refresh() }
        scheduleTimer()

        // Keep "today" correct across midnight and across sleep/wake.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDayChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: AppConfig.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func handleDayChanged() {
        let today = calendar.startOfDay(for: Date())
        anchorDate = today
        visibleMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        refresh()
    }

    // MARK: - Sync

    func refresh() {
        guard auth.isSignedIn else { return }
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    private func performRefresh() async {
        defer { isLoading = false }
        do {
            let (timeMin, timeMax) = fetchWindow()

            async let colorsTask = api.fetchColors()
            async let calendarsTask = api.fetchCalendarList()
            let colors = try await colorsTask
            let calendars = try await calendarsTask

            eventPalette = (colors.event ?? [:]).compactMapValues { $0.background }
            calendarPalette = (colors.calendar ?? [:]).compactMapValues { $0.background }

            let visible = calendars.filter { $0.isVisible }

            calendarDebugRows = calendars.enumerated().map { index, entry in
                let selected = entry.selected.map(String.init) ?? "absent"
                let primary = entry.primary.map(String.init) ?? "absent"
                _ = index
                return "  \"\(entry.summary ?? "(unnamed)")\""
                    + " bg=\(entry.backgroundColor ?? "absent")"
                    + " colorId=\(entry.colorId ?? "absent")"
                    + " selected=\(selected) primary=\(primary)"
                    + " hidden=\(entry.hidden.map(String.init) ?? "absent")"
                    + " access=\(entry.accessRole ?? "nil")"
                    + " FETCHED=\(entry.isVisible ? "yes" : "no")"
            }
            eventsWithOwnColor = 0
            eventDebugRows = []
            calendarColors = [:]
            calendarNames = [:]
            for entry in visible {
                let raw = entry.backgroundColor ?? entry.colorId.flatMap { calendarPalette[$0] }
                calendarColors[entry.id] = GoogleColors.modernize(raw) ?? Theme.fallbackEventHex
                calendarNames[entry.id] = entry.summary ?? entry.id
            }

            // Fetch each visible calendar concurrently. One calendar failing (revoked
            // access, deleted subscription) must not discard the calendars that worked.
            var collected: [CalEvent] = []
            var failures: [Error] = []
            await withTaskGroup(of: (String, Result<[RawEvent], Error>).self) { group in
                for entry in visible {
                    group.addTask { [api] in
                        do {
                            let raw = try await api!.fetchEvents(calendarID: entry.id,
                                                                 timeMin: timeMin,
                                                                 timeMax: timeMax)
                            return (entry.id, .success(raw))
                        } catch {
                            return (entry.id, .failure(error))
                        }
                    }
                }
                for await (calendarID, result) in group {
                    switch result {
                    case .success(let raw):
                        collected.append(contentsOf: raw.compactMap { convert($0, calendarID: calendarID) })
                    case .failure(let error):
                        failures.append(error)
                    }
                }
            }

            // Only hard-fail when every calendar failed. Counting failures (rather than
            // checking for zero events) keeps a genuinely empty calendar from looking
            // like an error.
            if !failures.isEmpty, failures.count == visible.count {
                throw failures[0]
            }

            collected.sort { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            events = collected
            lastUpdated = Date()
            errorMessage = failures.isEmpty
                ? nil
                : "Some calendars did not load: \(failures[0].localizedDescription)"

            // Tasks failing must not blank out events that already loaded successfully;
            // this is a distinct Google API with its own auth scope and its own outage
            // surface, so it's kept independent of the calendar error above.
            do {
                tasks = try await fetchAllTasks()
            } catch {
                tasks = []
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Roughly a month back and two months forward: enough for grid dots while the user
    /// navigates without re-fetching on every arrow tap.
    private func fetchWindow() -> (Date, Date) {
        let today = calendar.startOfDay(for: Date())
        let min = calendar.date(byAdding: .day, value: -35, to: today) ?? today
        let max = calendar.date(byAdding: .day, value: 70, to: today) ?? today
        return (min, max)
    }

    // MARK: - Tasks

    private func fetchAllTasks() async throws -> [CalTask] {
        let lists = try await tasksAPI.fetchTaskLists()
        var collected: [CalTask] = []
        for list in lists {
            let raw = try await tasksAPI.fetchTasks(taskListID: list.id)
            collected.append(contentsOf: raw.compactMap { convert($0, taskListID: list.id) })
        }
        // Due tasks first (earliest first), undated tasks after, alphabetical within each.
        collected.sort { lhs, rhs in
            switch (lhs.dueDay, rhs.dueDay) {
            case (let l?, let r?): return l == r
                ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : l < r
            case (nil, nil): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return collected
    }

    private func convert(_ raw: RawTask, taskListID: String) -> CalTask? {
        guard raw.status != "completed" else { return nil }
        let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var dueDay: Date?
        if let due = raw.due {
            // Google sends fractional seconds here ("2026-08-16T00:00:00.000Z"), which
            // GoogleDateParser.parse already falls back to withFractionalSeconds for.
            let timestamp = RawEvent.Timestamp(date: nil, dateTime: due, timeZone: nil)
            if let parsed = GoogleDateParser.parse(timestamp, timeZone: calendar.timeZone) {
                dueDay = calendar.startOfDay(for: parsed.date)
            }
        }
        return CalTask(
            id: raw.id,
            taskListID: taskListID,
            title: (title?.isEmpty == false) ? title! : "(No title)",
            notes: raw.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            dueDay: dueDay
        )
    }

    /// Marks a task complete. Optimistically removes it from the list (Google Tasks has no
    /// "still visible but done" state in this view — see GoogleTasksAPI.fetchTasks), and
    /// restores it on failure so the row doesn't just silently vanish for good.
    func completeTask(_ task: CalTask) {
        guard !completingTaskIDs.contains(task.id) else { return }
        completingTaskIDs.insert(task.id)
        let previous = tasks
        tasks.removeAll { $0.id == task.id }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.tasksAPI.completeTask(taskListID: task.taskListID, taskID: task.id)
            } catch {
                self.tasks = previous
                self.errorMessage = "Could not complete \"\(task.title)\": \(error.localizedDescription)"
            }
            self.completingTaskIDs.remove(task.id)
        }
    }

    private func convert(_ raw: RawEvent, calendarID: String) -> CalEvent? {
        guard raw.status != "cancelled" else { return nil }
        let timeZone = calendar.timeZone
        guard let startParsed = GoogleDateParser.parse(raw.start, timeZone: timeZone) else { return nil }
        let endParsed = GoogleDateParser.parse(raw.end, timeZone: timeZone)

        let isAllDay = startParsed.isAllDay
        let start = startParsed.date
        let end = endParsed?.date ?? (isAllDay
            ? calendar.date(byAdding: .day, value: 1, to: start) ?? start
            : start.addingTimeInterval(3600))

        // Per-event color wins over the calendar color, which is what preserves the
        // custom colors people set on individual Google Calendar events. `colorId` is the
        // documented classic palette; `eventLabelId` is the newer extended-swatch picker,
        // which Google's API exposes as an opaque UUID with no resolving endpoint — see
        // EventLabelColors for how those are learned. `eventType == "birthday"` never
        // carries a color at all; Google's own clients hardcode that styling, so this does
        // the same rather than showing every birthday in the calendar's default color.
        let hex: String
        if raw.colorId != nil {
            hex = GoogleColors.resolve(eventColorID: raw.colorId,
                                       apiEventPalette: eventPalette,
                                       calendarHex: calendarColors[calendarID],
                                       fallback: Theme.fallbackEventHex)
        } else if let learned = EventLabelColors.resolve(raw.eventLabelId) {
            hex = learned
        } else if raw.eventType == "birthday" {
            hex = Theme.birthdayHex
        } else {
            // calendarColors already stores modernized hex (see below).
            hex = calendarColors[calendarID] ?? Theme.fallbackEventHex
        }
        if raw.colorId != nil || raw.eventLabelId != nil { eventsWithOwnColor += 1 }

        if isDiagnosing {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let title = (raw.summary ?? "(none)").prefix(38)
            eventDebugRows.append("  \(formatter.string(from: start))"
                + " colorId=\(raw.colorId ?? "absent")"
                + " eventLabelId=\(raw.eventLabelId ?? "absent")"
                + " eventType=\(raw.eventType ?? "absent")"
                + " hex=\(hex)"
                + " allDay=\(isAllDay ? "y" : "n")"
                + " cal=\(calendarNames[calendarID] ?? "?")"
                + " | \(title)")
        }

        let identifier = raw.id ?? raw.iCalUID ?? UUID().uuidString
        return CalEvent(
            id: "\(calendarID)#\(identifier)#\(start.timeIntervalSince1970)",
            title: raw.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? raw.summary! : "(No title)",
            start: start,
            end: end,
            isAllDay: isAllDay,
            location: raw.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            videoLink: raw.videoLink,
            htmlLink: raw.htmlLink,
            colorHex: hex,
            calendarName: calendarNames[calendarID] ?? calendarID,
            isDeclined: raw.selfResponseStatus == "declined"
        )
    }

    // MARK: - Diagnostics

    /// A privacy-safe summary of calendars and how colors resolved: flags, counts and hex
    /// values only — never event titles or calendar ids. Used by `--diagnose`.
    func colorDiagnostics() -> String {
        var lines: [String] = []
        lines.append("calendars returned by API: \(calendarDebugRows.count)")
        lines.append(contentsOf: calendarDebugRows)
        lines.append("calendars fetched: \(calendarColors.count)")
        lines.append("events total: \(events.count)")
        lines.append("distinct resolved colors: \(Set(events.map(\.colorHex)).sorted().joined(separator: ", "))")
        lines.append("events with their own colorId: \(eventsWithOwnColor)")
        lines.append("event palette from API: \(eventPalette.count) entries")
        lines.append("calendar palette from API: \(calendarPalette.count) entries")
        lines.append("")
        lines.append("per-event colors (as the agenda renders them):")
        lines.append(contentsOf: eventDebugRows.sorted())
        lines.append("")
        lines.append("events on the fallback hex: \(events.filter { $0.colorHex == Theme.fallbackEventHex }.count)")
        return lines.joined(separator: "\n")
    }

    /// True while a `--diagnose` run is collecting the per-event table.
    private var isDiagnosing = false

    /// Diagnostics: full unfiltered JSON for the events named in CALENDARBAR_DUMP
    /// (comma-separated title substrings). Proves what Google does and does not send.
    private func rawEventDump() async -> String {
        let needles = (ProcessInfo.processInfo.environment["CALENDARBAR_DUMP"]
            ?? "Directed coursework,First Day of Classes,Happy birthday,Fee Payment")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let calendarID = calendarColors.keys.first else { return "no calendar to dump" }
        let (timeMin, timeMax) = fetchWindow()
        do {
            let data = try await api.fetchRawEventsBody(calendarID: calendarID,
                                                        timeMin: timeMin, timeMax: timeMax)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["items"] as? [[String: Any]] else {
                return "unexpected response shape"
            }
            var out: [String] = []
            for item in items {
                let summary = (item["summary"] as? String ?? "").lowercased()
                guard needles.contains(where: { summary.contains($0) }) else { continue }
                // Strip anything identifying before printing.
                var redacted = item
                for key in ["attendees", "creator", "organizer", "htmlLink", "iCalUID",
                            "id", "recurringEventId", "description", "extendedProperties"] {
                    redacted.removeValue(forKey: key)
                }
                let pretty = try JSONSerialization.data(withJSONObject: redacted,
                                                        options: [.prettyPrinted, .sortedKeys])
                out.append(String(decoding: pretty, as: UTF8.self))
            }
            return out.isEmpty ? "no matching events found" : out.joined(separator: "\n")
        } catch {
            return "raw dump failed: \(error.localizedDescription)"
        }
    }

    /// Refresh, then report. Used only by the diagnostics flag.
    func runDiagnostics() async -> String {
        isDiagnosing = true
        defer { isDiagnosing = false }
        if let warning = auth.keychainWarning {
            return "keychain: \(warning)"
        }
        await performRefresh()
        if let error = errorMessage { return "error: \(error)" }
        let dump = await rawEventDump()
        let taskReport = await tasksDiagnostics()
        return colorDiagnostics()
            + "\n\n=== unfiltered JSON from Google (no `fields` filter) ===\n" + dump
            + "\n\n=== tasks ===\n" + taskReport
    }

    private func tasksDiagnostics() async -> String {
        var lines: [String] = []
        do {
            let lists = try await tasksAPI.fetchTaskLists()
            lines.append("task lists: \(lists.count)")
            for list in lists {
                lines.append("  list \"\(list.title ?? "?")\" id=\(list.id)")
                do {
                    let raw = try await tasksAPI.fetchTasks(taskListID: list.id)
                    lines.append("    tasks fetched (showCompleted=false): \(raw.count)")
                    for t in raw {
                        lines.append("    - id=\(t.id) title=\(t.title ?? "?")"
                            + " status=\(t.status ?? "?") due=\(t.due ?? "absent")"
                            + " completed=\(t.completed ?? "absent")")
                    }
                } catch {
                    lines.append("    fetchTasks FAILED: \(error)")
                }
            }
        } catch {
            lines.append("fetchTaskLists FAILED: \(error)")
        }
        lines.append("store.tasks after refresh: \(tasks.count)")
        for t in tasks {
            lines.append("  \(t.title) dueDay=\(t.dueDay?.description ?? "nil")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Queries used by the views

    var today: Date { calendar.startOfDay(for: Date()) }

    func events(on day: Date) -> [CalEvent] {
        events.filter { $0.occurs(on: day, calendar: calendar) }
    }

    /// Tasks to show inside a given day's agenda section. Today's section also absorbs
    /// overdue tasks (due date already passed, so their actual day is never shown in the
    /// forward-looking agenda) and undated tasks (Google Tasks allows no due date at all),
    /// so nothing silently disappears from the popover.
    func tasks(on day: Date) -> [CalTask] {
        let dayStart = calendar.startOfDay(for: day)
        let isToday = calendar.isDate(dayStart, inSameDayAs: today)
        return tasks.filter { task in
            guard let due = task.dueDay else { return isToday }
            return isToday ? due <= dayStart : calendar.isDate(due, inSameDayAs: dayStart)
        }
    }

    /// Backed by a precomputed index: the grid asks this for up to 42 cells per render.
    func hasEvents(on day: Date) -> Bool {
        daysWithEvents.contains(calendar.startOfDay(for: day))
    }

    private func rebuildDayIndex() {
        var days: Set<Date> = []
        for event in events {
            var cursor = calendar.startOfDay(for: event.start)
            // All-day events carry an exclusive end date, so step up to (not through) it.
            let last = calendar.startOfDay(for: event.isAllDay
                ? event.end.addingTimeInterval(-1)
                : event.end)
            var guardCount = 0
            while cursor <= last, guardCount < 400 {
                days.insert(cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                guardCount += 1
            }
        }
        daysWithEvents = days
    }

    /// The seven days the agenda lists, starting at the anchor.
    var agendaDays: [Date] {
        let start = calendar.startOfDay(for: anchorDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: - Navigation

    /// Weeks (as arrays of 7 days) covering the visible month grid.
    var monthWeeks: [[Date]] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }

        var weeks: [[Date]] = []
        var cursor = firstWeek.start
        while cursor < monthInterval.end {
            let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) }
            weeks.append(week)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    /// The single week row shown when the grid is collapsed.
    var anchorWeek: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfMonth, for: anchorDate) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    func step(_ direction: Int) {
        if isGridExpanded {
            guard let next = calendar.date(byAdding: .month, value: direction, to: visibleMonth) else { return }
            visibleMonth = calendar.dateInterval(of: .month, for: next)?.start ?? next
            // Keep the anchor inside the month being browsed.
            if !calendar.isDate(anchorDate, equalTo: visibleMonth, toGranularity: .month) {
                anchorDate = calendar.isDate(visibleMonth, equalTo: today, toGranularity: .month)
                    ? today : visibleMonth
            }
        } else {
            guard let next = calendar.date(byAdding: .weekOfYear, value: direction, to: anchorDate) else { return }
            anchorDate = calendar.startOfDay(for: next)
            syncVisibleMonthToAnchor()
        }
    }

    func select(day: Date) {
        anchorDate = calendar.startOfDay(for: day)
        syncVisibleMonthToAnchor()
    }

    func goToToday() {
        anchorDate = today
        syncVisibleMonthToAnchor()
    }

    private func syncVisibleMonthToAnchor() {
        visibleMonth = calendar.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
    }

    var monthTitle: String {
        let date = isGridExpanded ? visibleMonth : anchorDate
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, equalTo: today, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        )
        return formatter.string(from: date)
    }

    // MARK: - Actions

    func openGoogleCalendar() {
        open("https://calendar.google.com/calendar/r")
    }

    func createEvent() {
        var dateFragment = ""
        if !calendar.isDateInToday(anchorDate) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: anchorDate)
            dateFragment = "&dates=\(day)T090000/\(day)T100000"
        }
        open("https://calendar.google.com/calendar/r/eventedit?text=\(dateFragment)")
    }

    func open(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func signIn() {
        Task {
            do {
                errorMessage = nil
                try await auth.signIn()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() {
        auth.signOut()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Demo data (CALENDARBAR_DEMO=1)

private extension CalendarStore {
    func loadDemoEvents() {
        func date(dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        events = [
            CalEvent(id: "d1", title: "Design review — menu bar popover",
                     start: date(dayOffset: 0, hour: 9, minute: 30),
                     end: date(dayOffset: 0, hour: 10, minute: 30),
                     isAllDay: false, location: nil,
                     videoLink: "https://meet.google.com/demo", htmlLink: nil,
                     colorHex: "7986CB", calendarName: "Work", isDeclined: false),
            CalEvent(id: "d2", title: "Lunch with Sam",
                     start: date(dayOffset: 0, hour: 13),
                     end: date(dayOffset: 0, hour: 14),
                     isAllDay: false, location: "Blue Bottle, 2nd Ave",
                     videoLink: nil, htmlLink: nil,
                     colorHex: "F4511E", calendarName: "Personal", isDeclined: false),
            CalEvent(id: "d3", title: "Sprint planning",
                     start: date(dayOffset: 0, hour: 16),
                     end: date(dayOffset: 0, hour: 17),
                     isAllDay: false, location: nil, videoLink: nil, htmlLink: nil,
                     colorHex: "33B679", calendarName: "Work", isDeclined: true),
            CalEvent(id: "d4", title: "Team offsite",
                     start: date(dayOffset: 1, hour: 0),
                     end: date(dayOffset: 2, hour: 0),
                     isAllDay: true, location: "Hudson Yards",
                     videoLink: nil, htmlLink: nil,
                     colorHex: "8E24AA", calendarName: "Work", isDeclined: false),
            CalEvent(id: "d5", title: "1:1 with Priya",
                     start: date(dayOffset: 1, hour: 11),
                     end: date(dayOffset: 1, hour: 11, minute: 30),
                     isAllDay: false, location: "https://zoom.us/j/123",
                     videoLink: "https://zoom.us/j/123", htmlLink: nil,
                     colorHex: "039BE5", calendarName: "Work", isDeclined: false),
            CalEvent(id: "d6", title: "Dentist",
                     start: date(dayOffset: 3, hour: 8, minute: 15),
                     end: date(dayOffset: 3, hour: 9),
                     isAllDay: false, location: "Dr. Ahmed's clinic",
                     videoLink: nil, htmlLink: nil,
                     colorHex: "E67C73", calendarName: "Personal", isDeclined: false)
        ]
        tasks = [
            CalTask(id: "t1", taskListID: "demo", title: "Send meeting notes",
                    notes: nil, dueDay: calendar.date(byAdding: .day, value: 0, to: today)),
            CalTask(id: "t2", taskListID: "demo", title: "Renew passport",
                    notes: "Appointment booked for next month", dueDay: nil),
            CalTask(id: "t3", taskListID: "demo", title: "Follow up with vendor",
                    notes: nil, dueDay: calendar.date(byAdding: .day, value: -2, to: today))
        ]
        lastUpdated = Date()
    }
}
