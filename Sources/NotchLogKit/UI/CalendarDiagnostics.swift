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

    nonisolated(unsafe) private static var storeBox: EKEventStore?
}
