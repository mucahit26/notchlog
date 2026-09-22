import EventKit
import Foundation

/// Reports how macOS identifies this process for TCC, and what a real access request
/// does. Split out from `CalendarService` so it can run without any UI.
public enum CalendarDiagnostics {
    /// Mirrors the transcript to a file so the diagnostic is readable when the app is
    /// launched through LaunchServices (`open`), where stdout goes nowhere.
    public static let logPath = NSHomeDirectory() + "/notchlog-calendar-test.log"
    nonisolated(unsafe) private static var transcript = ""
    private static let lock = NSLock()

    public static func log(_ line: String) {
        lock.lock()
        transcript += line + "\n"
        let snapshot = transcript
        lock.unlock()
        try? snapshot.write(toFile: logPath, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    public static func statusDescription() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "notDetermined (never asked)"
        case .restricted: return "restricted (blocked by policy)"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly (cannot read events)"
        @unknown default: return "unknown"
        }
    }

    public static func request(_ completion: @escaping @Sendable (Bool, Error?) -> Void) {
        let store = EKEventStore()
        // Hold the store alive until the callback fires; a released store cancels it.
        storeBox = store
        store.requestFullAccessToEvents { granted, error in
            DispatchQueue.main.async { completion(granted, error) }
        }
    }

    public static func eventCountToday() -> Int {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return -1 }
        let store = EKEventStore()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return -1 }
        return store.events(matching: store.predicateForEvents(withStart: start,
                                                               end: end, calendars: nil)).count
    }

    /// Dumps the next `days` days so it is obvious whether future days resolve —
    /// clicking ahead to Monday is the whole point of the page.
    public static func upcoming(days: Int = 8) -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return ["(no access)"]
        }
        let store = EKEventStore()
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE d MMM"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm"

        var out: [String] = []
        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: offset,
                                     to: cal.startOfDay(for: Date())),
                  let end = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let events = store.events(matching: store.predicateForEvents(
                withStart: day, end: end, calendars: nil))
                .sorted { ($0.startDate ?? day) < ($1.startDate ?? day) }
            let summary = events.isEmpty
                ? "—"
                : events.map { ev in
                    let time = ev.isAllDay ? "all-day" : tf.string(from: ev.startDate ?? day)
                    return "\(time) \(ev.title ?? "?")"
                  }.joined(separator: " | ")
            out.append("  \(df.string(from: day))  \(summary)")
        }
        return out
    }

    /// How many calendars the user actually has, which distinguishes "no events" from
    /// "no calendars are being read".
    public static func calendarNames() -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKEventStore().calendars(for: .event).map { "\($0.title) [\($0.type.rawValue)]" }
    }

    /// Whether an event could be written, without writing one.
    public static func writeTarget() -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "no access"
        }
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else {
            return "NO default calendar for new events — events cannot be created"
        }
        let modifiable = calendar.allowsContentModifications
        return "\(calendar.title) [\(calendar.source.title)] writable=\(modifiable)"
    }

    nonisolated(unsafe) private static var storeBox: EKEventStore?
}
