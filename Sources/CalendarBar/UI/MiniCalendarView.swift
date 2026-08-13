import SwiftUI

/// The month/week grid at the top of the popover, including the weekday letters,
/// the "today" badge, the side navigation arrows and the collapse chevron.
struct MiniCalendarView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        VStack(spacing: 6) {
            weekdayHeader
            HStack(spacing: 0) {
                arrow(systemName: "chevron.left", direction: -1)
                grid
                arrow(systemName: "chevron.right", direction: 1)
            }
            collapseButton
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.bottom, 6)
    }

    // MARK: - Weekday letters

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Theme.gridGutter)
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(Theme.weekdayFont)
                    // Weekend columns are muted, matching Outlook.
                    .foregroundStyle(isWeekend(column: index) ? Theme.secondaryText : Theme.primaryText)
                    .frame(width: Theme.cellSize)
            }
            Spacer().frame(width: Theme.gridGutter)
        }
        .padding(.bottom, 2)
    }

    private var weekdaySymbols: [String] {
        let symbols = store.calendar.veryShortStandaloneWeekdaySymbols
        let firstWeekday = store.calendar.firstWeekday - 1
        return (0..<7).map { symbols[(firstWeekday + $0) % 7] }
    }

    private func isWeekend(column: Int) -> Bool {
        let weekday = ((store.calendar.firstWeekday - 1 + column) % 7) + 1
        return store.calendar.isDateInWeekend(dateForWeekday(weekday))
    }

    /// A reference date with the given weekday, used only to ask the calendar about weekends.
    private func dateForWeekday(_ weekday: Int) -> Date {
        let reference = store.calendar.dateInterval(of: .weekOfMonth, for: Date())?.start ?? Date()
        let offset = (weekday - store.calendar.component(.weekday, from: reference) + 7) % 7
        return store.calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 2) {
            ForEach(Array(visibleWeeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.timeIntervalSince1970) { day in
                        DayCell(day: day, store: store)
                            .frame(width: Theme.cellSize, height: 32)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.isGridExpanded)
    }

    private var visibleWeeks: [[Date]] {
        store.isGridExpanded ? store.monthWeeks : [store.anchorWeek]
    }

    // MARK: - Chrome

    private func arrow(systemName: String, direction: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { store.step(direction) }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.iconTint)
                .frame(width: Theme.gridGutter, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.isGridExpanded
              ? (direction < 0 ? "Previous month" : "Next month")
              : (direction < 0 ? "Previous week" : "Next week"))
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { store.isGridExpanded.toggle() }
        } label: {
            Image(systemName: store.isGridExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.iconTint)
                .frame(width: 40, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.isGridExpanded ? "Show one week" : "Show the whole month")
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: Date
    @ObservedObject var store: CalendarStore
    @State private var isHovering = false

    var body: some View {
        Button {
            store.select(day: day)
        } label: {
            ZStack {
                if isToday {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: Theme.dayCircle, height: Theme.dayCircle)
                } else if isSelected {
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
                        .frame(width: Theme.dayCircle, height: Theme.dayCircle)
                } else if isHovering {
                    Circle()
                        .fill(Theme.hoverFill)
                        .frame(width: Theme.dayCircle, height: Theme.dayCircle)
                }

                label
            }
            .frame(width: Theme.cellSize, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// The 1st of a month shows the abbreviated month above the number, as Outlook does.
    private var label: some View {
        VStack(spacing: -1) {
            if isFirstOfMonth && !isToday {
                Text(monthAbbreviation)
                    .font(Theme.monthBadgeFont)
                    .foregroundStyle(foreground)
            }
            Text(dayNumber)
                .font(isToday ? Theme.dayNumberTodayFont : Theme.dayNumberFont)
                .foregroundStyle(isToday ? Color.white : foreground)
            if store.hasEvents(on: day) && !isToday {
                Circle()
                    .fill(Theme.accent.opacity(0.75))
                    .frame(width: 3.5, height: 3.5)
                    .offset(y: 1)
            }
        }
    }

    private var foreground: Color {
        if isToday { return .white }
        // Outlook keeps the "Aug 1" style month markers emphasized even in the past.
        if isFirstOfMonth { return Theme.primaryText }
        // Past days and days outside the visible month are muted.
        if day < store.today { return Theme.tertiaryText }
        if store.isGridExpanded,
           !store.calendar.isDate(day, equalTo: store.visibleMonth, toGranularity: .month) {
            return Theme.tertiaryText
        }
        return Theme.primaryText
    }

    private var isToday: Bool { store.calendar.isDateInToday(day) }

    private var isSelected: Bool {
        !isToday && store.calendar.isDate(day, inSameDayAs: store.anchorDate)
    }

    private var isFirstOfMonth: Bool { store.calendar.component(.day, from: day) == 1 }

    private var dayNumber: String {
        String(store.calendar.component(.day, from: day))
    }

    private var monthAbbreviation: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: day)
    }
}
