import AppKit
import EventKit
import SwiftUI

public struct CalendarEvent: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The colour the user assigned to the owning calendar, so events look like theirs.
    public let colorHex: Int?
}

/// Reads events from the user's Calendar, and asks for permission only when the
/// calendar page is actually opened.
///
/// This is the one place NotchLog can prompt for anything, and it is deliberately
/// **lazy and optional**: the monitoring core never touches EventKit, so a user who
/// never opens page 2 is never asked. If access is denied the page still works — the
/// month grid and the activity heat map come from NotchLog's own database — and only
/// the event list is empty. Nothing here is written, and no event data is ever stored:
/// events are read for display and dropped.
@MainActor
public final class CalendarService: ObservableObject {
    public enum Access: Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    @Published public private(set) var access: Access = .notDetermined
    @Published public private(set) var isRequesting = false

    private let store = EKEventStore()
    private var cache: [Int: [CalendarEvent]] = [:]

    public init() { access = Self.currentStatus() }

    private static func currentStatus() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        // .writeOnly means we may add events but not read them, which is no use here
        // and cannot be upgraded by asking again — treat it as denied for reading.
        case .writeOnly: return .denied
        default: return .notDetermined
        }
    }

    /// Called the first time the calendar page is shown. Safe to call repeatedly.
    public func requestAccessIfNeeded() {
        access = Self.currentStatus()
        guard access == .notDetermined, !isRequesting else { return }
        isRequesting = true
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequesting = false
                self.access = Self.currentStatus()
                self.cache.removeAll()
            }
        }
    }

    public func refresh() {
        cache.removeAll()
        access = Self.currentStatus()
    }

    /// Events on one local day. Results are cached per day and cleared when access
    /// changes, because this is called from a view body on every redraw.
    public func events(on date: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let key = Retention.dayKey(for: date)
        if let hit = cache[key] { return hit }

        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? start) < ($1.startDate ?? start) }
            .map { ev in
                CalendarEvent(
                    id: ev.eventIdentifier ?? UUID().uuidString,
                    title: ev.title ?? "(untitled)",
                    start: ev.startDate ?? start,
                    end: ev.endDate ?? start,
                    isAllDay: ev.isAllDay,
                    colorHex: ev.calendar?.color.map(Self.hex(from:)))
            }
        cache[key] = events
        return events
    }

    /// Days in a month that have at least one event, for the dot markers in the grid.
    public func daysWithEvents(in month: Date) -> Set<Int> {
        guard access == .granted else { return [] }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start,
                                                 end: interval.end, calendars: nil)
        var days: Set<Int> = []
        for ev in store.events(matching: predicate) {
            guard let s = ev.startDate else { continue }
            days.insert(Retention.dayKey(for: s))
        }
        return days
    }

    private static func hex(from color: NSColor) -> Int {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0x888888 }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
