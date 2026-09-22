import AppKit
import Foundation

/// Owns the sampling loop, the database, retention, and app launch/quit observation.
///
/// One sampler, one timer. While the panel is expanded the timer speeds up to 2 s so the
/// live view feels responsive, but samples are *accumulated* and still persisted on the
/// configured logging interval. That keeps the stored resolution honest — a 2 s delta
/// written into a 10 s row would under-report by 5x — without paying for a second sampler.
/// `@unchecked Sendable`: every piece of mutable state below is confined to `queue`
/// (timers, the accumulator, the fast-mode flag) or held in an atomic box (the latest
/// snapshot and the callbacks). `start`/`stop`/`setFastMode` may be called from the main
/// thread, so they hop onto `queue` rather than touching the timers directly.
public final class Monitor: @unchecked Sendable {
    public struct Config: Sendable {
        public var logInterval: TimeInterval = 10
        public var fastInterval: TimeInterval = 2
        public var retentionCheckInterval: TimeInterval = 6 * 3600
        public init() {}
    }

    private let latestBox = Atomic<Snapshot?>(nil)
    /// Most recent sample, safe to read from any thread.
    public var latest: Snapshot? { latestBox.get() }

    /// Fires when an application is launched from cold, carrying (bundle id, name).
    /// Used to surface tasks the user associated with that app.
    private let launchHandler = Atomic<(@Sendable (String?, String?) -> Void)?>(nil)
    public var onAppLaunched: (@Sendable (String?, String?) -> Void)? {
        get { launchHandler.get() }
        set { launchHandler.set(newValue) }
    }

    private let snapshotHandler = Atomic<(@Sendable (Snapshot) -> Void)?>(nil)
    private let errorHandler = Atomic<(@Sendable (String) -> Void)?>(nil)

    /// Called on the main queue after every sample, including fast ones.
    public var onSnapshot: (@Sendable (Snapshot) -> Void)? {
        get { snapshotHandler.get() }
        set { snapshotHandler.set(newValue) }
    }
    /// Errors are surfaced as text: `Error` is not `Sendable`, and a message is all
    /// the UI needs in order to show a warning badge.
    public var onError: (@Sendable (String) -> Void)? {
        get { errorHandler.get() }
        set { errorHandler.set(newValue) }
    }

    private let sampler: Sampler
    private let db: Database
    private var config: Config
    private let retention = Retention()

    private var timer: DispatchSourceTimer?
    private var retentionTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mucahit26.notchlog.monitor", qos: .utility)
    private var fast = false

    // Accumulator bridging fast UI samples up to one logging-interval row.
    private var pending: [String: AppUsage] = [:]
    private var pendingSeconds: TimeInterval = 0

    public init(config: Config = Config(), database: Database? = nil) throws {
        self.config = config
        self.db = try database ?? Database()
        var sc = Sampler.Config()
        sc.interval = config.logInterval
        self.sampler = Sampler(config: sc)
    }

    public var database: Database { db }

    // MARK: - lifecycle

    public func start() {
        observeWorkspace()
        let interval = config.logInterval
        let retentionInterval = config.retentionCheckInterval
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleSamplingLocked(interval: interval)

            // Catch-up run: if the machine was off for days, the first launch should tidy
            // up immediately rather than waiting for the first periodic check.
            self.runRetention()
            let rt = DispatchSource.makeTimerSource(queue: self.queue)
            rt.schedule(deadline: .now() + retentionInterval, repeating: retentionInterval)
            rt.setEventHandler { [weak self] in self?.runRetention() }
            rt.resume()
            self.retentionTimer = rt
        }
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        queue.sync {
            timer?.cancel(); timer = nil
            retentionTimer?.cancel(); retentionTimer = nil
        }
    }

    /// Switch to the fast cadence while the panel is open.
    public func setFastMode(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.fast != enabled else { return }
            self.fast = enabled
            self.scheduleSamplingLocked(
                interval: enabled ? self.config.fastInterval : self.config.logInterval)
        }
    }

    /// Must be called on `queue`.
    private func scheduleSamplingLocked(interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A generous leeway lets the OS coalesce our wakeups with other timers, which
        // matters more than millisecond punctuality for a process that runs all day.
        t.schedule(deadline: .now() + 0.1, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - sampling

    private func tick() {
        do {
            let snap = try sampler.tick()
            latestBox.set(snap)
            if let cb = snapshotHandler.get() { DispatchQueue.main.async { cb(snap) } }
            guard !snap.isGap else {
                pending.removeAll(); pendingSeconds = 0
                try? db.recordGap(at: snap.date, seconds: Int(snap.interval),
                                  reason: "baseline, wake or stall")
                return
            }
            accumulate(snap)
            if pendingSeconds >= config.logInterval - 0.5 { try flush(at: snap.date) }
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        guard let cb = errorHandler.get() else { return }
        let message = String(describing: error)
        DispatchQueue.main.async { cb(message) }
    }

    /// CPU-milliseconds and byte counts are additive across sub-intervals; RSS is a level,
    /// so the most recent reading wins and the peak is what the export reports.
    private func accumulate(_ snap: Snapshot) {
        for app in snap.apps {
            if var acc = pending[app.name] {
                acc.cpuMS += app.cpuMS
                acc.rssKB = app.rssKB
                acc.netIn &+= app.netIn
                acc.netOut &+= app.netOut
                if let r = app.diskRead { acc.diskRead = (acc.diskRead ?? 0) &+ r }
                if let w = app.diskWritten { acc.diskWritten = (acc.diskWritten ?? 0) &+ w }
                acc.processCount = app.processCount
                pending[app.name] = acc
            } else {
                pending[app.name] = app
            }
        }
        pendingSeconds += snap.interval
    }

    private func flush(at date: Date) throws {
        guard !pending.isEmpty else { return }
        let snap = Snapshot(date: date, interval: pendingSeconds,
                            apps: Array(pending.values), isGap: false)
        pending.removeAll()
        pendingSeconds = 0
        try db.insert(snapshot: snap)
    }

    private func runRetention() {
        do { _ = try retention.run(on: db) }
        catch { report(error) }
    }

    // MARK: - app launch / quit + sleep / wake

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] n in
            self?.record(n, launched: true)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] n in
            self?.record(n, launched: false)
        }
        // A delta spanning a sleep would otherwise report hours of CPU as if it had
        // happened in one interval, so baselines are dropped on wake.
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.sampler.resetBaselines()
                self.pending.removeAll()
                self.pendingSeconds = 0
            }
        }
    }

    private func record(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let bundlePath = app.bundleURL?.path
        let name = bundlePath.map { AppIdentity.identify(execPath: $0 + "/Contents/MacOS/x").name }
            ?? app.localizedName ?? "unknown"
        if launched, let cb = launchHandler.get() {
            let bundleID = app.bundleIdentifier
            let display = app.localizedName ?? name
            DispatchQueue.main.async { cb(bundleID, display) }
        }
        queue.async { [weak self] in
            try? self?.db.recordEvent(name: name, bundlePath: bundlePath,
                                      launched: launched, at: Date())
        }
    }

    // MARK: - export

    public func export(hours: Double = 24) throws -> URL {
        try Exporter.write(db: db, hours: hours)
    }
}
