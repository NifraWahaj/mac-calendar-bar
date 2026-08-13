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

                        let events = store.events(on: day)
                        if events.isEmpty {
                            Text("No events scheduled")
                                .font(Theme.placeholderFont)
                                .foregroundStyle(Theme.primaryText.opacity(0.85))
                                .padding(.horizontal, Theme.horizontalPadding)
                                .padding(.vertical, 13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(events) { event in
                                EventRow(event: event, store: store)
                                if event.id != events.last?.id {
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
