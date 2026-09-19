import SwiftUI

/// Which page the expanded panel is showing.
@MainActor
public final class PanelState: ObservableObject {
    public static let pageCount = 2
    @Published public var page: Int = 0

    public init() {}

    public func advance(by delta: Int) {
        let next = page + delta
        guard next >= 0, next < Self.pageCount else { return }
        page = next
    }
}
