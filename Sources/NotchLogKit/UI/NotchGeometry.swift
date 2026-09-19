import AppKit

/// Where the panel lives, in AppKit's bottom-left origin coordinate space.
///
/// On a notched Mac the collapsed panel sits exactly behind the camera housing, which
/// has no pixels — so the resting state is genuinely invisible rather than merely small,
/// while the cursor still passes through that region and triggers hover. On a Mac with
/// no notch there is nothing to hide behind, so the collapsed state is a slim pill just
/// under the menu bar instead.
public struct NotchGeometry: Sendable {
    public let hasNotch: Bool
    public let collapsed: NSRect
    public let bandHeight: CGFloat
    public let centerX: CGFloat
    public let topY: CGFloat
    public let screenFrame: NSRect

    public static func current(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0,
           right.minX > left.maxX {
            let h = screen.safeAreaInsets.top
            let rect = NSRect(x: left.maxX, y: frame.maxY - h,
                              width: right.minX - left.maxX, height: h)
            return NotchGeometry(hasNotch: true, collapsed: rect, bandHeight: h,
                                 centerX: rect.midX, topY: frame.maxY, screenFrame: frame)
        }
        // No notch: rest a pill directly beneath the menu bar.
        let band = max(24, frame.maxY - screen.visibleFrame.maxY)
        let pill = NSSize(width: 200, height: 24)
        let rect = NSRect(x: frame.midX - pill.width / 2,
                          y: frame.maxY - band - pill.height,
                          width: pill.width, height: pill.height)
        return NotchGeometry(hasNotch: false, collapsed: rect, bandHeight: band,
                             centerX: frame.midX, topY: frame.maxY - band, screenFrame: frame)
    }

    public static let expandedSize = NSSize(width: 640, height: 330)

    /// Expanded panel, centred on the notch and clamped to stay on screen.
    public var expanded: NSRect {
        let size = NotchGeometry.expandedSize
        var x = centerX - size.width / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        let y = topY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Top inset the content must leave clear so nothing important is drawn behind
    /// the camera housing.
    public var contentTopInset: CGFloat { hasNotch ? bandHeight : 6 }
}
