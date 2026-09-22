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

    /// Fires when the user adds or edits an event in Calendar.app, so the panel does not
    /// show a stale day.
    public var onExternalChange: (@Sendable () -> Void)?

    public init() {
        access = Self.currentStatus()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.cache.removeAll()
                    self?.onExternalChange?()
                }
            }
    }

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
        let current = Self.currentStatus()
        // Assign only on a real change. `access` is @Published and drives a subscriber
        // that calls back into refresh(); reassigning unconditionally would rely on
        // removeDuplicates() further down the chain to break the cycle.
        if current != access { access = current }
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

    // MARK: - writing

    public enum WriteError: LocalizedError {
        case noAccess
        case noCalendar
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .noAccess: return "Calendar access is off"
            case .noCalendar: return "No writable calendar"
            case .underlying(let message): return message
            }
        }
    }

    /// Creates an all-day event for a task's deadline and returns its identifier.
    ///
    /// This is the only place NotchLog writes anything outside its own database, and it
    /// happens solely because the box was ticked on the capture page. A deadline is a
    /// day rather than a moment, so the event is all-day; the task's notes carry over so
    /// the event is useful on its own.
    public func createAllDayEvent(title: String, notes: String,
                                  on date: Date) -> Result<String, WriteError> {
        guard access == .granted else { return .failure(.noAccess) }
        guard let calendar = store.defaultCalendarForNewEvents,
              calendar.allowsContentModifications else { return .failure(.noCalendar) }

        let day = Calendar.current.startOfDay(for: date)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = notes.isEmpty ? nil : notes
        event.isAllDay = true
        event.startDate = day
        event.endDate = day

        do {
            try store.save(event, span: .thisEvent, commit: true)
            cache.removeAll()
            return .success(event.eventIdentifier ?? "")
        } catch {
            return .failure(.underlying(error.localizedDescription))
        }
    }

    private static func hex(from color: NSColor) -> Int {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0x888888 }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
