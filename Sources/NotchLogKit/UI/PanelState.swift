import SwiftUI

/// Which page the expanded panel is showing.
@MainActor
public final class PanelState: ObservableObject {
    public enum Page: Int, CaseIterable {
        case live = 0
        case calendar = 1
        case newTask = 2
        case tasks = 3

        /// Pages that contain text fields. The panel has to become key for these, which
        /// activates the app, so it is done only where typing is the point.
        var needsKeyboard: Bool { self == .newTask }

        /// Only the live page shows per-app numbers that change second to second.
        /// Sampling at 2 s behind a task list is pure cost — it competes with typing
        /// and scrolling for the main thread and changes nothing on screen.
        var needsFastSampling: Bool { self == .live }
    }

    public static var pageCount: Int { Page.allCases.count }

    @Published public var page: Int = 0
    public var current: Page { Page(rawValue: page) ?? .live }

    public init() {}

    public func advance(by delta: Int) {
        let next = page + delta
        guard next >= 0, next < Self.pageCount else { return }
        page = next
    }
}
