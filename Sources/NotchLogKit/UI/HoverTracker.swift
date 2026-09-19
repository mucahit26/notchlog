import AppKit

/// Decides when the panel should be open.
///
/// Entering uses an `NSTrackingArea` with `.activeAlways`, which the AppKit header
/// documents as firing "regardless of activation" — so it works while another app is
/// frontmost and needs no Accessibility or Input Monitoring permission.
///
/// Leaving does **not** use the tracking area. Once the panel expands, its bounds change
/// underneath the cursor and the enter/exit pair oscillates — an early experiment produced
/// 18 enter/exit cycles in 25 seconds. Instead, while expanded the cursor position is
/// polled and the panel closes only after the cursor has been outside the expanded frame
/// continuously for a grace period. Reading `NSEvent.mouseLocation` is a coordinate
/// query, not an event tap, so it also requires no permission.
@MainActor
public final class HoverTracker {
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?

    public var openDelay: TimeInterval = 0.12
    public var closeGrace: TimeInterval = 0.35
    public var exitMargin: CGFloat = 4

    private var openTimer: Timer?
    private var pollTimer: Timer?
    private var outsideSince: Date?
    private(set) public var isOpen = false

    /// Frame the cursor must stay within to keep the panel open.
    public var activeFrame: NSRect = .zero

    public init() {}

    public func cursorEnteredCollapsedArea() {
        guard !isOpen, openTimer == nil else { return }
        openTimer = Timer.scheduledTimer(withTimeInterval: openDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.open() }
        }
    }

    /// The tracking area's exit is only used to cancel a pending open — a cursor that
    /// merely crossed the notch on its way to the menu bar should never open the panel.
    public func cursorLeftCollapsedArea() {
        guard !isOpen else { return }
        openTimer?.invalidate(); openTimer = nil
    }

    private func open() {
        openTimer?.invalidate(); openTimer = nil
        guard !isOpen else { return }
        isOpen = true
        outsideSince = nil
        onOpen?()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard isOpen else { return }
        let inside = activeFrame.insetBy(dx: -exitMargin, dy: -exitMargin)
            .contains(NSEvent.mouseLocation)
        if inside {
            outsideSince = nil
            return
        }
        if let since = outsideSince {
            if Date().timeIntervalSince(since) >= closeGrace { close() }
        } else {
            outsideSince = Date()
        }
    }

    public func close() {
        pollTimer?.invalidate(); pollTimer = nil
        openTimer?.invalidate(); openTimer = nil
        outsideSince = nil
        guard isOpen else { return }
        isOpen = false
        onClose?()
    }
}
