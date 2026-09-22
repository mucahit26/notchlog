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

/// A `.nonactivatingPanel` never becomes key, so a text field inside it receives no
/// keystrokes. Overriding `canBecomeKey` allows it — at the cost of activating the app,
/// which is why the controller only makes it key on the page where typing is the point.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class NotchController {
    private let panel: KeyPanel
    private let host: NSHostingView<ExpandedView>
    private let container: HoverHostView
    private let model = LiveModel()
    private let panelState = PanelState()
    private let calendarModel: CalendarModel
    private let calendarService = CalendarService()
    private let taskModel: TaskModel
    private let hover = HoverTracker()
    /// Whatever was frontmost before we took focus, so it can be handed back.
    private var previousFrontApp: NSRunningApplication?
    private var reminderDismissTimer: Timer?
    private var visibilityWatchdog: Timer?
    private var reminderCursorOrigin: NSPoint?
    private let monitor: Monitor
    private var geometry: NotchGeometry
    private var pageObserver: AnyCancellable?
    private var editingObserver: AnyCancellable?

    public init(monitor: Monitor) {
        self.monitor = monitor
        self.geometry = NotchGeometry.current()
        self.calendarModel = CalendarModel(database: monitor.database,
                                           service: calendarService)
        self.taskModel = TaskModel(database: monitor.database)

        let model = self.model
        self.host = NSHostingView(rootView: ExpandedView(
            model: model, panel: panelState, calendarModel: calendarModel,
            calendarService: calendarService, taskModel: taskModel,
            topInset: geometry.contentTopInset,
            onExport: {}, onRevealData: {}, onQuit: {}))
        self.container = HoverHostView(frame: NSRect(origin: .zero, size: geometry.collapsed.size))
        self.panel = KeyPanel(contentRect: geometry.collapsed,
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
        editingObserver = taskModel.$isEditing
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateKeyboardOwnership() }
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
        monitor.onAppLaunched = { [weak self] bundleID, name in
            Task { @MainActor in self?.appLaunched(bundleID: bundleID, name: name) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenParametersChanged() }
            }

        // If anything hides the app, the notch panel goes with it and the app looks
        // like it quit while still running — with no way for the user to get it back.
        // An earlier bug did exactly that, so recovery is now automatic rather than
        // depending on never making that mistake again.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    NSApp.unhide(nil)
                    self?.panel.orderFrontRegardless()
                }
            }

        let watchdog = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensurePanelVisible() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        visibilityWatchdog = watchdog
    }

    /// Cheap assertion that the panel is still where it belongs.
    private func ensurePanelVisible() {
        guard !panel.isVisible || NSApp.isHidden else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        panel.setFrame(hover.isOpen ? geometry.expanded(forPage: panelState.page)
                                    : geometry.collapsed, display: false)
        panel.orderFrontRegardless()
    }

    private func makeRootView() -> ExpandedView {
        ExpandedView(
            model: model, panel: panelState, calendarModel: calendarModel,
            calendarService: calendarService, taskModel: taskModel,
            topInset: geometry.contentTopInset,
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
        switch panelState.current {
        case .calendar:
            calendarService.requestAccessIfNeeded()
            calendarModel.reloadAll()
        case .newTask:
            taskModel.loadInstalledApps()
        case .tasks:
            taskModel.reload()
        case .live:
            break
        }
        monitor.setFastMode(hover.isOpen && panelState.current.needsFastSampling)
        updateKeyboardOwnership()
        guard hover.isOpen else { return }
        let target = geometry.expanded(forPage: page)
        hover.activeFrame = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Typing requires the panel to be key, which activates the whole app and takes
    /// focus from whatever the user was doing. That is acceptable on the page whose
    /// purpose is writing, and unacceptable everywhere else — so key status is acquired
    /// and given back as the page changes. The hover tracker is locked at the same time,
    /// because a draft must not be destroyed by the pointer drifting off the panel.
    private func updateKeyboardOwnership() {
        let wantsKeyboard = hover.isOpen && panelState.current.needsKeyboard
        // Pinned only while something is actually being typed into, not for the whole
        // page — see TaskModel.isEditing.
        hover.setLocked(wantsKeyboard && taskModel.isEditing)
        if wantsKeyboard {
            if !panel.isKeyWindow {
                // Remember who had the foreground so it can be given back, rather than
                // leaving the user stranded in an app they did not choose.
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previousFrontApp = front
                }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        } else {
            releaseKeyboard()
        }
    }

    /// Gives back key status and the foreground.
    ///
    /// This must never call `NSApp.hide(_:)`. For an accessory app that hides *every*
    /// window it owns, including the notch panel, and nothing brings it back — the panel
    /// simply vanishes and the app looks like it quit while still running.
    private func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        previousFrontApp?.activate()
        previousFrontApp = nil
        // Defensive: the panel must stay on screen no matter what the activation
        // dance did to window ordering.
        panel.orderFrontRegardless()
    }

    private func expand() {
        let target = geometry.expanded(forPage: panelState.page)
        hover.activeFrame = target
        model.databaseBytes = monitor.database.fileSizeBytes
        monitor.setFastMode(panelState.current.needsFastSampling)
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
        hover.setLocked(false)
        releaseKeyboard()
        reminderDismissTimer?.invalidate(); reminderDismissTimer = nil
        taskModel.reminderContext = nil
        // Always reopen on the live page; the other pages are somewhere you go.
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
        geometry = NotchGeometry.current()
        host.rootView = makeRootView()
        let frame = hover.isOpen ? geometry.expanded(forPage: panelState.page) : geometry.collapsed
        hover.activeFrame = frame
        panel.setFrame(frame, display: true)
    }

    // MARK: - launch reminders

    /// An application the user tied a task to has just started.
    ///
    /// The panel opens by itself to show what was waiting, then closes again. It
    /// deliberately does NOT take key status: the user was in the middle of launching
    /// something, and stealing the keyboard at that moment would be hostile.
    private func appLaunched(bundleID: String?, name: String?) {
        let db = monitor.database
        Task.detached(priority: .utility) {
            guard let tasks = try? db.openTasks(forBundleID: bundleID, name: name),
                  !tasks.isEmpty else { return }
            // Remind once per app per day, so relaunching all morning is not a nag.
            let key = bundleID ?? name ?? ""
            let due = tasks.filter { (try? db.shouldRemind(taskID: $0.id, bundleID: key)) ?? false }
            guard !due.isEmpty else { return }

            // Mark as reminded only if it was actually shown. Marking first meant that
            // a launch arriving while the panel was already open consumed the reminder
            // without displaying it, and the task then stayed silent for the rest of
            // the day.
            let shown = await MainActor.run { self.presentReminder(appName: name ?? key) }
            guard shown else { return }
            for task in due { try? db.markReminded(taskID: task.id, bundleID: key) }
        }
    }

    /// Returns whether the reminder was actually put on screen.
    @discardableResult
    private func presentReminder(appName: String) -> Bool {
        // Never interrupt someone already using the panel.
        guard !hover.isOpen else { return false }
        taskModel.reminderContext = appName
        taskModel.reload()
        panelState.page = PanelState.Page.tasks.rawValue

        let target = geometry.expanded(forPage: panelState.page)
        hover.activeFrame = target
        host.isHidden = false
        panel.orderFrontRegardless()          // visible, but not key: no focus stolen
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }

        reminderCursorOrigin = NSEvent.mouseLocation
        reminderDismissTimer?.invalidate()
        reminderDismissTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissReminder() }
        }
        return true
    }

    private func dismissReminder() {
        reminderDismissTimer?.invalidate(); reminderDismissTimer = nil

        // The panel opens over wherever the pointer happens to be, so the tracking area
        // fires and the hover tracker adopts it — and it would then stay open until the
        // pointer moved, which can be a long time. Treat it as a real hover only if the
        // pointer actually moved onto it; a stationary pointer did not choose anything.
        let origin = reminderCursorOrigin
        reminderCursorOrigin = nil
        let moved = origin.map { hypot(NSEvent.mouseLocation.x - $0.x,
                                       NSEvent.mouseLocation.y - $0.y) > 8 } ?? true
        if hover.isOpen && moved { return }
        hover.forceClose()
        taskModel.reminderContext = nil
        panelState.page = 0
        let target = geometry.collapsed
        hover.activeFrame = target
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.host.isHidden = true }
        })
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
