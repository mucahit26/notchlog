import Foundation
import SwiftUI

/// Backing state for the calendar page: which month is shown, which day is selected,
/// and the activity totals behind the heat map.
@MainActor
public final class CalendarModel: ObservableObject {
    @Published public var month: Date = Date()
    @Published public var selected: Date = Date()
    @Published public private(set) var heat: [Int: DayActivity] = [:]
    @Published public private(set) var dayApps: [DayApp] = []
    @Published public private(set) var eventDays: Set<Int> = []
    @Published public private(set) var loadError: String?

    /// Busiest day in the displayed month, used to normalise the heat scale. The scale
    /// is relative to the month on screen, so a quiet month still shows contrast rather
    /// than reading as uniformly blank.
    public private(set) var heatMax: Int64 = 0

    private let db: Database
    private let calendar = Calendar.current

    public init(database: Database) {
        self.db = database
    }

    public var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month)
    }

    public var selectedTitle: String {
        // An explicit template rather than .full: .full follows the region's ordering
        // while the month names come from the app's (English-only) localisation, which
        // on a Turkish region produced "19 September 2026 Saturday".
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: selected)
    }

    public var selectedActivity: DayActivity? { heat[Retention.dayKey(for: selected)] }

    /// Weekday initials, rotated to the user's first day of week.
    public var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Cells for the month grid: nil for the leading/trailing blanks.
    public var gridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<days {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        // Pad to whole weeks so the grid height never jumps between months.
        while cells.count % 7 != 0 { cells.append(nil) }
        while cells.count < 42 { cells.append(nil) }
        return cells
    }

    /// Heat level 0...4 for a day, GitHub-contribution style. Discrete steps read more
    /// reliably than a continuous ramp at this cell size.
    public func heatLevel(for date: Date) -> Int {
        guard heatMax > 0,
              let activity = heat[Retention.dayKey(for: date)],
              activity.cpuMS > 0 else { return 0 }
        let ratio = Double(activity.cpuMS) / Double(heatMax)
        return min(4, max(1, Int((ratio * 4).rounded(.up))))
    }

    public func hasEvents(_ date: Date) -> Bool {
        eventDays.contains(Retention.dayKey(for: date))
    }

    public func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }
    public func isSelected(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: selected) }
    public func isInDisplayedMonth(_ date: Date) -> Bool {
        calendar.isDate(date, equalTo: month, toGranularity: .month)
    }

    // MARK: - navigation

    public func step(months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = next
        reloadMonth()
    }

    public func goToToday() {
        month = Date()
        selected = Date()
        reloadMonth()
        reloadSelectedDay()
    }

    public func select(_ date: Date) {
        selected = date
        reloadSelectedDay()
    }

    // MARK: - loading

    public func reloadMonth(eventDays: Set<Int> = []) {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        let from = Retention.dayKey(for: interval.start)
        let to = Retention.dayKey(for: interval.end.addingTimeInterval(-1))
        self.eventDays = eventDays
        let db = self.db
        Task.detached(priority: .userInitiated) {
            let result = Result { try db.dailyActivity(from: from, to: to) }
            await MainActor.run {
                switch result {
                case .success(let map):
                    self.heat = map
                    self.heatMax = map.values.map(\.cpuMS).max() ?? 0
                    self.loadError = nil
                case .failure(let error):
                    self.loadError = String(describing: error)
                }
            }
        }
    }

    public func reloadSelectedDay() {
        let key = Retention.dayKey(for: selected)
        let db = self.db
        Task.detached(priority: .userInitiated) {
            let result = Result { try db.apps(onDay: key, limit: 5) }
            await MainActor.run {
                if case .success(let apps) = result { self.dayApps = apps }
            }
        }
    }
}
