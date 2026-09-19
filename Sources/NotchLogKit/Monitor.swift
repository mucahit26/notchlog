import AppKit
import Foundation

/// Owns the sampling loop, the database, retention, and app launch/quit observation.
///
/// One sampler, one timer. While the panel is expanded the timer speeds up to 2 s so the
/// live view feels responsive, but samples are *accumulated* and still persisted on the
/// configured logging interval. That keeps the stored resolution honest — a 2 s delta
/// written into a 10 s row would under-report by 5x — without paying for a second sampler.
public final class Monitor {
    public struct Config: Sendable {
        public var logInterval: TimeInterval = 10
        public var fastInterval: TimeInterval = 2
        public var retentionCheckInterval: TimeInterval = 6 * 3600
        public init() {}
    }

    private let latestBox = Atomic<Snapshot?>(nil)
    /// Most recent sample, safe to read from any thread.
    public var latest: Snapshot? { latestBox.get() }

    /// Called on the main queue after every sample, including fast ones.
    public var onSnapshot: (@Sendable (Snapshot) -> Void)?
    /// Errors are surfaced as text: `Error` is not `Sendable`, and a message is all
    /// the UI needs in order to show a warning badge.
    public var onError: (@Sendable (String) -> Void)?

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
        scheduleSampling(interval: config.logInterval)

        // Catch-up run: if the machine was off for days, the first launch should tidy up
        // immediately rather than waiting for the first periodic check.
        queue.async { [weak self] in self?.runRetention() }
        let rt = DispatchSource.makeTimerSource(queue: queue)
        rt.schedule(deadline: .now() + config.retentionCheckInterval,
                    repeating: config.retentionCheckInterval)
        rt.setEventHandler { [weak self] in self?.runRetention() }
        rt.resume()
        retentionTimer = rt
    }

    public func stop() {
        timer?.cancel(); timer = nil
        retentionTimer?.cancel(); retentionTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Switch to the fast cadence while the panel is open.
    public func setFastMode(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.fast != enabled else { return }
            self.fast = enabled
            self.scheduleSampling(interval: enabled ? self.config.fastInterval : self.config.logInterval)
        }
    }

    private func scheduleSampling(interval: TimeInterval) {
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
            if let cb = onSnapshot { DispatchQueue.main.async { cb(snap) } }
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
        guard let cb = onError else { return }
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
