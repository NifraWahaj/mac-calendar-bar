import SwiftUI

/// Scrollable agenda for the seven days starting at the anchor date.
struct AgendaListView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // Eager stack: seven day sections is a small enough tree that laziness
                // buys nothing and breaks scroll-to-day and offscreen rendering.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.agendaDays, id: \.timeIntervalSince1970) { day in
                        DaySectionHeader(day: day, store: store)
                            .id(day.timeIntervalSince1970)

                        // Tasks render after this day's events (they carry a due date, not
                        // a time, so there's no meaningful chronological interleave).
                        let rows: [AgendaRow] = store.events(on: day).map(AgendaRow.event)
                            + store.tasks(on: day).map(AgendaRow.task)
                        if rows.isEmpty {
                            Text("No events scheduled")
                                .font(Theme.placeholderFont)
                                .foregroundStyle(Theme.primaryText.opacity(0.85))
                                .padding(.horizontal, Theme.horizontalPadding)
                                .padding(.vertical, 13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(rows) { row in
                                switch row {
                                case .event(let event):
                                    EventRow(event: event, store: store)
                                case .task(let task):
                                    TaskRow(task: task, store: store)
                                }
                                if row.id != rows.last?.id {
                                    Divider()
                                        .overlay(Theme.separator)
                                        .padding(.leading, Theme.horizontalPadding)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: store.anchorDate) { _ in
                // Keep the newly selected day pinned to the top of the agenda.
                if let first = store.agendaDays.first {
                    proxy.scrollTo(first.timeIntervalSince1970, anchor: .top)
                }
            }
        }
        .background(Theme.popoverBackground)
    }
}

// MARK: - Agenda row (event or task, mixed within a day's section)

private enum AgendaRow: Identifiable {
    case event(CalEvent)
    case task(CalTask)

    var id: String {
        switch self {
        case .event(let event): return "event-\(event.id)"
        case .task(let task): return "task-\(task.id)"
        }
    }
}

/// A single Google Task row. Tasks have no per-item color in Google's own API, so every
/// row uses one fixed accent (Theme.taskHex) to read as a distinct category from events.
private struct TaskRow: View {
    let task: CalTask
    @ObservedObject var store: CalendarStore
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Same colored left bar as EventRow, but fixed to one hue (Theme.taskHex) so
            // tasks read as their own category at a glance rather than blending into
            // whichever event color happens to be adjacent.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: Theme.taskHex))
                .frame(width: 3)
                .frame(minHeight: 32)

            Button {
                store.completeTask(task)
            } label: {
                Image(systemName: isCompleting ? "circle.dotted" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: Theme.taskHex))
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Theme.eventTitleFont)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if dueText != nil || task.notes != nil {
                    HStack(spacing: 5) {
                        if let dueText {
                            Text(dueText)
                        }
                        if let notes = task.notes {
                            if dueText != nil { Text("•") }
                            Text(notes).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(Theme.eventDetailFont)
                    .foregroundStyle(Theme.secondaryText)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Theme.hoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(isCompleting ? 0.5 : 1)
    }

    private var isCompleting: Bool { store.completingTaskIDs.contains(task.id) }

    private var dueText: String? {
        guard let due = task.dueDay else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let overdue = due < store.today
        return (overdue ? "Overdue • " : "Due ") + formatter.string(from: due)
    }
}

// MARK: - Section header

private struct DaySectionHeader: View {
    let day: Date
    @ObservedObject var store: CalendarStore

    var body: some View {
        Text(title)
            .font(Theme.sectionHeaderFont)
            .foregroundStyle(isToday ? Theme.accent : Theme.primaryText)
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sectionHeaderBackground)
    }

    private var isToday: Bool { store.calendar.isDateInToday(day) }

    /// "Today • Thursday • August 13", "Tomorrow • Friday • August 14", "Saturday • August 15".
    private var title: String {
        var parts: [String] = []
        if isToday {
            parts.append("Today")
            parts.append(weekday)
        } else if store.calendar.isDateInTomorrow(day) {
            parts.append("Tomorrow")
            parts.append(weekday)
        } else {
            parts.append(weekday)
        }
        parts.append(monthAndDay)
        return parts.joined(separator: " • ")
    }

    private var weekday: String { formatted("EEEE") }
    private var monthAndDay: String { formatted("MMMMd") }

    private func formatted(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day)
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: CalEvent
    @ObservedObject var store: CalendarStore
    @State private var isHovering = false

    var body: some View {
        Button {
            store.open(event.videoLink ?? event.htmlLink)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(event.color)
                    .frame(width: 3)
                    .frame(minHeight: 32)
                    .opacity(event.isDeclined ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(Theme.eventTitleFont)
                        .foregroundStyle(Theme.primaryText)
                        .strikethrough(event.isDeclined, color: Theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        Text(event.timeText)
                        if let detail = secondaryDetail {
                            Text("•")
                            Text(detail).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(Theme.eventDetailFont)
                    .foregroundStyle(Theme.secondaryText)
                }

                Spacer(minLength: 4)

                if event.videoLink != nil {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Theme.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }

    private var secondaryDetail: String? {
        if let location = event.location {
            // A meeting URL pasted in the location field just reads as noise.
            if location.lowercased().hasPrefix("http") { return "Online" }
            return location
        }
        if event.videoLink != nil { return "Online" }
        return nil
    }

    private var tooltip: String {
        var lines = [event.title, event.timeText]
        if let location = event.location { lines.append(location) }
        lines.append(event.calendarName)
        return lines.joined(separator: "\n")
    }
}
