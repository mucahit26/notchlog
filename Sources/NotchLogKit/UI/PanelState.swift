import SwiftUI

/// Which page the expanded panel is showing.
///
/// Order is deliberate: the task list comes first because it is what gets looked at,
/// and it is what the panel returns to when it closes. Writing a task is a less
/// frequent act than checking what is outstanding, and the live metrics — while the
/// original point of the app — are something you go and look at rather than something
/// you need in front of you every time the pointer crosses the notch.
@MainActor
public final class PanelState: ObservableObject {
    public enum Page: Int, CaseIterable {
        case tasks = 0
        case newTask = 1
        case live = 2
        case calendar = 3

        /// Pages that contain text fields. The panel has to become key for these, which
        /// activates the app, so it is done only where typing is the point.
        var needsKeyboard: Bool { self == .newTask }

        /// Only the live page shows per-app numbers that change second to second.
        /// Sampling at 2 s behind a task list is pure cost — it competes with typing
        /// and scrolling for the main thread and changes nothing on screen.
        var needsFastSampling: Bool { self == .live }

        var title: String {
            switch self {
            case .tasks: return "Tasks"
            case .newTask: return "New task"
            case .live: return "Live"
            case .calendar: return "Calendar"
            }
        }
    }

    public static var pageCount: Int { Page.allCases.count }

    @Published public var page: Int = 0
    public var current: Page { Page(rawValue: page) ?? .tasks }

    public init() {}

    public func advance(by delta: Int) {
        let next = page + delta
        guard next >= 0, next < Self.pageCount else { return }
        page = next
    }
}
