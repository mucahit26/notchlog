import AppKit
import Combine
import SwiftUI

/// Container view whose only job is to report that the cursor arrived.
///
/// `.activeAlways` is the important flag: the AppKit header states such an owner
/// receives mouseEntered/Exited "regardless of activation", which is why this works
/// while another app is frontmost and without any permission prompt.
final class HoverHostView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// -1 for "previous page", +1 for "next page".
    var onSwipe: ((Int) -> Void)?

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var lastFlip = Date.distantPast

    /// Two-finger horizontal swipe, verified to reach this panel even though it never
    /// becomes key and the app is never frontmost — `scrollWheel` is delivered by hit
    /// test, so it needs no permission.
    ///
    /// Two things in the raw event stream will misfire if ignored, both observed live:
    ///  * **Momentum.** Inertia keeps delivering events after the fingers lift, which
    ///    would flip a second page for one gesture.
    ///  * **Vertical scrolling.** It arrives through the same callback, so a gesture is
    ///    only accepted when it is clearly more horizontal than vertical.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }

        if event.hasPreciseScrollingDeltas {
            switch event.phase {
            case .began:
                accumulatedX = 0
                accumulatedY = 0
            case .changed:
                accumulatedX += event.scrollingDeltaX
                accumulatedY += event.scrollingDeltaY
            case .ended, .cancelled:
                commitSwipe(threshold: 40)
            default:
                break
            }
        } else {
            // A classic mouse wheel has no phases, so accumulate and fire on threshold.
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            commitSwipe(threshold: 6)
        }
    }

    private func commitSwipe(threshold: CGFloat) {
        guard abs(accumulatedX) >= threshold,
              abs(accumulatedX) > abs(accumulatedY) * 1.5,
              Date().timeIntervalSince(lastFlip) > 0.35 else {
            if abs(accumulatedX) >= threshold { accumulatedX = 0; accumulatedY = 0 }
            return
        }
        lastFlip = Date()
        // Swipe left (negative delta) moves forward, matching Safari's page gesture.
        let direction = accumulatedX < 0 ? 1 : -1
        accumulatedX = 0
        accumulatedY = 0
        onSwipe?(direction)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
public final class NotchController {
    private let panel: NSPanel
    private let host: NSHostingView<ExpandedView>
    private let container: HoverHostView
    private let model = LiveModel()
    private let panelState = PanelState()
    private let calendarModel: CalendarModel
    private let calendarService = CalendarService()
    private let hover = HoverTracker()
    private let monitor: Monitor
    private var geometry: NotchGeometry
    private var pageObserver: AnyCancellable?

    public init(monitor: Monitor) {
        self.monitor = monitor
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.geometry = NotchGeometry.current(for: screen)
        self.calendarModel = CalendarModel(database: monitor.database)

        let model = self.model
        self.host = NSHostingView(rootView: ExpandedView(
            model: model, panel: panelState, calendarModel: calendarModel,
            calendarService: calendarService, topInset: geometry.contentTopInset,
            onExport: {}, onRevealData: {}, onQuit: {}))
        self.container = HoverHostView(frame: NSRect(origin: .zero, size: geometry.collapsed.size))
        self.panel = NSPanel(contentRect: geometry.collapsed,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        configurePanel()
        wire()
    }

    private func configurePanel() {
        // Order matters: the isFloatingPanel setter forces level back to .floating (3),
        // which sits BELOW the menu bar (24). Setting the level afterwards puts the panel
        // at .statusBar (25), verified on-screen to render above the menu bar.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = container

        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.isHidden = true            // collapsed state draws nothing at all
        container.addSubview(host)
    }

    private func wire() {
        host.rootView = makeRootView()

        container.onEnter = { [weak self] in self?.hover.cursorEnteredCollapsedArea() }
        container.onExit = { [weak self] in self?.hover.cursorLeftCollapsedArea() }
        container.onSwipe = { [weak self] direction in
            guard let self, self.hover.isOpen else { return }
            self.panelState.advance(by: direction)
        }
        pageObserver = panelState.$page
            .removeDuplicates()
            .sink { [weak self] page in
                Task { @MainActor in self?.pageChanged(to: page) }
            }
        hover.onOpen = { [weak self] in self?.expand() }
        hover.onClose = { [weak self] in self?.collapse() }

        monitor.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                guard !snapshot.isGap else { return }
                self.model.apply(snapshot)
            }
        }
        monitor.onError = { [weak self] message in
            Task { @MainActor in self?.model.warning = message }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenParametersChanged() }
            }
    }

    private func makeRootView() -> ExpandedView {
        ExpandedView(
            model: model, panel: panelState, calendarModel: calendarModel,
            calendarService: calendarService, topInset: geometry.contentTopInset,
            onExport: { [weak self] in self?.export() },
            onRevealData: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.root.path)
            },
            onQuit: { NSApp.terminate(nil) })
    }

    public func show() {
        panel.setFrame(geometry.collapsed, display: false)
        hover.activeFrame = geometry.collapsed
        panel.orderFrontRegardless()
    }

    // MARK: - expand / collapse

    /// Resize to the page's own height, and do the calendar's lazy setup the first time
    /// page 2 is shown — which is the only moment NotchLog ever asks macOS for anything.
    private func pageChanged(to page: Int) {
        if page == 1 {
            calendarService.requestAccessIfNeeded()
            calendarModel.reloadMonth(eventDays: calendarService.daysWithEvents(in: calendarModel.month))
            calendarModel.reloadSelectedDay()
        }
        guard hover.isOpen else { return }
        let target = geometry.expanded(forPage: page)
        hover.activeFrame = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func expand() {
        let target = geometry.expanded(forPage: panelState.page)
        hover.activeFrame = target
        model.databaseBytes = monitor.database.fileSizeBytes
        monitor.setFastMode(true)
        host.isHidden = false
        if let snapshot = monitor.latest, !snapshot.isGap { model.apply(snapshot) }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func collapse() {
        monitor.setFastMode(false)
        // Always reopen on the live page; the calendar is something you go to.
        panelState.page = 0
        model.exportStatus = nil
        let target = geometry.collapsed
        hover.activeFrame = target
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.host.isHidden = true }
        })
    }

    /// Displays can be attached, detached or rescaled at any time, and an external
    /// monitor may have no notch at all — so the geometry is recomputed rather than
    /// cached for the lifetime of the process.
    private func screenParametersChanged() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        geometry = NotchGeometry.current(for: screen)
        host.rootView = makeRootView()
        let frame = hover.isOpen ? geometry.expanded(forPage: panelState.page) : geometry.collapsed
        hover.activeFrame = frame
        panel.setFrame(frame, display: true)
    }

    // MARK: - export

    private func export() {
        guard !model.isExporting else { return }
        model.isExporting = true
        model.exportStatus = nil
        let monitor = self.monitor
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try monitor.export(hours: 24) }
            Task { @MainActor in
                self.model.isExporting = false
                switch result {
                case .success(let url):
                    self.model.exportStatus = "Saved \(url.lastPathComponent)"
                    // Written into NotchLog's own directory, so no TCC prompt; revealing
                    // it in Finder lets the user move it wherever they like.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    self.model.exportStatus = "Export failed: \(error)"
                }
            }
        }
    }
}
