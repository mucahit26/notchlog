import Foundation

/// The test suite, as a subcommand rather than a test target.
///
/// Neither XCTest nor swift-testing ships with the Command Line Tools, so `swift test`
/// cannot run on a machine without Xcode — and building without Xcode is precisely what
/// this package promises. Running the checks from the shipped binary works everywhere,
/// and doubles as a way for a user to verify the parsers against their own system.
public enum SelfTest {
    public struct Report: Sendable {
        public var passed = 0
        public var failures: [String] = []
        public var ok: Bool { failures.isEmpty }
    }

    private struct Ctx {
        var report = Report()
        mutating func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { report.passed += 1 } else { report.failures.append(name) }
        }
        mutating func equal<T: Equatable>(_ name: String, _ a: T, _ b: T) {
            if a == b { report.passed += 1 }
            else { report.failures.append("\(name): expected \(b), got \(a)") }
        }
    }

    public static func run(log: (String) -> Void = { print($0) }) -> Report {
        var c = Ctx()

        // --- ps: cumulative CPU time -------------------------------------------------
        // The minutes field is NOT capped at 60; a long-lived WindowServer reads "256:48.19".
        let m256: Double = 15_408.19        // 256 min 48.19 s
        let m18: Double = 1_099.11          // 18 min 19.11 s
        let hms: Double = 7_384             // 02:03:04
        let dhms: Double = 93_784           // 1 day + 02:03:04
        c.equal("cpuTime minutes>60", PSSource.parseCPUTime("256:48.19"), m256)
        c.equal("cpuTime mm:ss", PSSource.parseCPUTime("18:19.11"), m18)
        c.equal("cpuTime zero", PSSource.parseCPUTime("0:00.00"), Double(0))
        c.equal("cpuTime hh:mm:ss", PSSource.parseCPUTime("02:03:04"), hms)
        c.equal("cpuTime dd-hh:mm:ss", PSSource.parseCPUTime("1-02:03:04"), dhms)
        c.check("cpuTime rejects header", PSSource.parseCPUTime("TIME") == nil)
        c.check("cpuTime rejects empty", PSSource.parseCPUTime("") == nil)
        c.check("cpuTime rejects garbage", PSSource.parseCPUTime("a:b") == nil)

        // --- ps: paths containing spaces ---------------------------------------------
        let psLine = "29090 29072 549664  15:33.78 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
        let parsed = PSSource.parse("  PID  PPID    RSS      TIME COMM\n" + psLine)
        c.equal("ps drops header row", parsed.count, 1)
        c.equal("ps pid", parsed.first?.pid, 29090)
        c.equal("ps rss", parsed.first?.rssKB, 549_664)
        c.check("ps keeps spaced path",
                parsed.first?.execPath.hasSuffix("MacOS/Claude Helper (Renderer)") == true)

        // --- nettop: names with spaces, names with dots -------------------------------
        let frame = NettopSource.parse("""
                                                         bytes_in       bytes_out
        Google Chrome H.23649                             3091824         2053789
           tcp4 192.168.1.39:52480<->17.242.218.132:5223  3091824         2053789
        com.apple.Drive.751                                    12              34
        """)
        c.equal("nettop truncated name with space", frame.names[23649], "Google Chrome H")
        c.equal("nettop name containing dots", frame.names[751], "com.apple.Drive")
        c.check("nettop rejects header row", !frame.names.values.contains { $0.contains("bytes_in") })
        c.equal("nettop connection count", frame.connections.count, 1)
        c.equal("nettop connection pid", frame.connections.first?.pid, 23649)
        c.equal("nettop connection bytes_in", frame.connections.first?.bytesIn, 3_091_824)
        c.equal("nettop connection bytes_out", frame.connections.first?.bytesOut, 2_053_789)

        // --- helper rollup -------------------------------------------------------------
        let chromeRenderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153.0.8010.48/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        c.equal("chrome helper rolls up", AppIdentity.identify(execPath: chromeRenderer).name, "Google Chrome")
        c.equal("chrome bundle path", AppIdentity.identify(execPath: chromeRenderer).bundlePath, "/Applications/Google Chrome.app")
        c.equal("claude helper rolls up",
                AppIdentity.identify(execPath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper").name,
                "Claude")
        c.equal("daemon keeps basename",
                AppIdentity.identify(execPath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer").name,
                "WindowServer")
        c.check("daemon has no bundle",
                AppIdentity.identify(execPath: "/usr/sbin/mDNSResponder").bundlePath == nil)

        // --- subprocess allowlist ------------------------------------------------------
        for forbidden in ["/bin/sh", "/usr/bin/curl", "/usr/bin/env", "/bin/ps.fake"] {
            var refused = false
            do { _ = try ProcessRunner.run(forbidden, []) }
            catch ProcessRunnerError.notAllowed { refused = true }
            catch { }
            c.check("runner refuses \(forbidden)", refused)
        }
        c.check("nettop args always contain -n", NettopSource.arguments.contains("-n"))

        // --- live system checks --------------------------------------------------------
        do {
            let raw = try ProcessRunner.run(ProcessRunner.ps, PSSource.arguments)
            // Output sits right around the 64 KB pipe buffer (62-68 KB observed on the
            // same machine minutes apart), which is exactly why draining before waiting
            // is mandatory. Don't assert a hard size — the safety is structural, not
            // size-dependent — but do flag when a run lands in the danger zone.
            c.check("ps output is substantial", raw.utf8.count > 16 * 1024)
            if raw.utf8.count > 60 * 1024 {
                log("  live: ps emitted \(raw.utf8.count) bytes — at/over the 64 KB pipe buffer")
            }
            let rows = PSSource.parse(raw)
            c.check("ps parses a plausible number of live processes", rows.count > 50)
            c.check("no live row has an empty path", !rows.contains { $0.execPath.isEmpty })
            c.check("no live row has a bad pid", !rows.contains { $0.pid <= 0 })
            log("  live: parsed \(rows.count) processes from \(raw.utf8.count) bytes of ps output")
        } catch {
            c.report.failures.append("live ps sample failed: \(error)")
        }

        do {
            let live = try NettopSource.sample()
            c.check("nettop returns process rows", !live.names.isEmpty)
            for conn in live.connections {
                c.check("connection \(conn.key) has an owning process", live.names[conn.pid] != nil)
            }
            let keys = live.connections.map(\.key)
            c.equal("connection keys are unique", Set(keys).count, keys.count)
            log("  live: parsed \(live.names.count) networked processes, \(live.connections.count) sockets")
        } catch {
            c.report.failures.append("live nettop sample failed: \(error)")
        }

        let pids = (try? PSSource.sample().map(\.pid)) ?? []
        let io = DiskIOSource.sample(pids: pids)
        c.check("disk I/O readable for some processes", !io.isEmpty)
        if !pids.isEmpty {
            log("  live: disk I/O readable for \(io.count)/\(pids.count) processes " +
                "(root-owned processes return EPERM; this is expected)")
        }

        checkRetention(&c, log: log)
        checkTasks(&c, log: log)
        return c.report
    }

    /// Tasks are user-authored content living in the same database as sampled
    /// telemetry, so the things worth proving are that retention cannot eat them and
    /// that an app association survives the app disappearing from the metrics tables.
    private static func checkTasks(_ c: inout Ctx, log: (String) -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchlog-tasks-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }

        do {
            let db = try Database(url: tmp)
            let chrome = TaskApp(name: "Google Chrome", bundleID: "com.google.Chrome")
            let excel = TaskApp(name: "Microsoft Excel", bundleID: "com.microsoft.Excel")

            let id = try db.createTask(title: "Write the thing", notes: "with detail",
                                       apps: [chrome, excel])
            c.check("task: created with an id", id > 0)

            let open = try db.openTasks()
            c.equal("task: appears in the open list", open.count, 1)
            c.equal("task: title round-trips", open.first?.title, "Write the thing")
            c.equal("task: notes round-trip", open.first?.notes, "with detail")
            c.equal("task: both apps associated", open.first?.apps.count, 2)

            // Matching is by bundle id first, because names change with localisation.
            let byBundle = try db.openTasks(forBundleID: "com.google.Chrome", name: nil)
            c.equal("task: matched by bundle id", byBundle.count, 1)
            let byName = try db.openTasks(forBundleID: nil, name: "Microsoft Excel")
            c.equal("task: matched by display name", byName.count, 1)
            let noMatch = try db.openTasks(forBundleID: "com.apple.Safari", name: "Safari")
            c.equal("task: unrelated app does not match", noMatch.count, 0)

            // Reminders fire once per app per day.
            c.equal("task: first reminder is due",
                    try db.shouldRemind(taskID: id, bundleID: "com.google.Chrome"), true)
            try db.markReminded(taskID: id, bundleID: "com.google.Chrome")
            c.equal("task: second reminder same day is suppressed",
                    try db.shouldRemind(taskID: id, bundleID: "com.google.Chrome"), false)
            c.equal("task: reminder is due again tomorrow",
                    try db.shouldRemind(taskID: id, bundleID: "com.google.Chrome",
                                        now: Date().addingTimeInterval(26 * 3600)), true)

            // Completing moves it to the archive with a date, and it can come back.
            try db.setTaskCompleted(id: id, completed: true)
            c.equal("task: leaves the open list once done", try db.openTasks().count, 0)
            let archived = try db.completedTasks()
            c.equal("task: appears in the archive", archived.count, 1)
            c.check("task: completion date recorded", archived.first?.completedAt != nil)
            c.equal("task: apps survive completion", archived.first?.apps.count, 2)
            c.equal("task: a completed task is not reminded about",
                    try db.openTasks(forBundleID: "com.google.Chrome", name: nil).count, 0)
            try db.setTaskCompleted(id: id, completed: false)
            c.equal("task: reopening restores it", try db.openTasks().count, 1)

            // The important one: retention purges the metrics `app` table, so a task
            // associated with an app that has not been sampled recently must not lose
            // its link. That is why task_app stores names, not foreign keys.
            _ = try Retention().run(on: db)
            let afterPurge = try db.openTasks()
            c.equal("task: survives a retention pass", afterPurge.count, 1)
            c.equal("task: associations survive a retention pass", afterPurge.first?.apps.count, 2)
            c.equal("task: still matches its app after purge",
                    try db.openTasks(forBundleID: "com.google.Chrome", name: nil).count, 1)

            let counts = try db.taskCounts()
            c.equal("task: counts add up", counts.open, 1)

            try db.deleteTask(id: id)
            c.equal("task: delete removes it", try db.openTasks().count, 0)

            log("  tasks: create, match, remind, complete, reopen and purge-survival verified")
        } catch {
            c.report.failures.append("task check failed: \(error)")
        }
    }

    /// Exercises rollup and purge against a throwaway database.
    ///
    /// Worth doing on every run: these paths only fire on data older than 24 hours, so
    /// in normal operation a bug here would stay invisible for a day and then quietly
    /// destroy or duplicate a week of history.
    private static func checkRetention(_ c: inout Ctx, log: (String) -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchlog-selftest-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }

        do {
            let db = try Database(url: tmp)
            // Anchor to a minute boundary. Six samples ten seconds apart span fifty
            // seconds, which straddles a minute boundary for most start offsets and
            // would then legitimately roll into two buckets — making the assertion
            // below pass or fail depending on what time the test happened to run.
            let epoch = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
            let now = Date(timeIntervalSince1970: epoch)

            func snapshot(at offset: Double, cpuMS: Int, netIn: UInt64) -> Snapshot {
                Snapshot(date: Date(timeIntervalSince1970: epoch + offset), interval: 10,
                         apps: [AppUsage(name: "TestApp", bundlePath: nil, cpuMS: cpuMS,
                                         rssKB: 100_000, netIn: netIn, netOut: 0,
                                         diskRead: 5, diskWritten: 7, processCount: 1)],
                         isGap: false)
            }

            // Six samples within a single aligned minute, 30 hours ago: must collapse
            // to exactly ONE row.
            let oldBase = -30.0 * 3600
            for i in 0..<6 {
                try db.insert(snapshot: snapshot(at: oldBase + Double(i * 10),
                                                 cpuMS: 100, netIn: 1000))
            }
            // Recent sample: must survive at full resolution.
            try db.insert(snapshot: snapshot(at: -60, cpuMS: 500, netIn: 42))
            // Ancient sample, beyond the retention window: must disappear entirely.
            try db.insert(snapshot: snapshot(at: -9 * 24 * 3600, cpuMS: 900, netIn: 7))

            c.equal("retention: fine rows before", try db.count("sample_fine"), 8)

            let result = try Retention().run(on: db, now: now)

            c.equal("retention: recent row kept at full resolution", try db.count("sample_fine"), 1)
            c.check("retention: old fine rows removed", result.purgedFine == 7)
            // Six 10-second samples in the same minute collapse into a single bucket;
            // the 9-day-old one is purged rather than rolled.
            c.equal("retention: rolled into one minute bucket", try db.count("sample_minute"), 1)

            let rolled = try db.stats(since: now.addingTimeInterval(-31 * 3600),
                                      until: now.addingTimeInterval(-29 * 3600))
            c.equal("retention: rollup preserved total CPU", rolled.rows.first?.cpuMS, 600)
            c.equal("retention: rollup preserved total bytes", rolled.rows.first?.netIn, 6000)

            // Running twice must not duplicate or lose anything.
            _ = try Retention().run(on: db, now: now)
            c.equal("retention: idempotent on minute rows", try db.count("sample_minute"), 1)
            c.equal("retention: idempotent on fine rows", try db.count("sample_fine"), 1)

            // --- daily summary, which the calendar heat map reads ---------------------
            // The 30-hour-old samples must also have landed in sample_day, totals intact.
            let oldDay = Retention.dayKey(for: Date(timeIntervalSince1970: epoch + oldBase))
            let daily = try db.dailyActivity(from: oldDay, to: oldDay)
            c.equal("daily: bucket exists", daily[oldDay] != nil, true)
            c.equal("daily: CPU total preserved", daily[oldDay]?.cpuMS, 600)
            c.equal("daily: byte total preserved", daily[oldDay]?.netBytes, 6000)

            let dayApps = try db.apps(onDay: oldDay)
            c.equal("daily: app attribution preserved", dayApps.first?.name, "TestApp")

            // A second pass must not double the daily totals — the ON CONFLICT clause
            // adds rather than replaces, so this only holds because the fine rows that
            // fed it were deleted in the same transaction.
            _ = try Retention().run(on: db, now: now)
            let again = try db.dailyActivity(from: oldDay, to: oldDay)
            c.equal("daily: rollup is not double-counted", again[oldDay]?.cpuMS, 600)

            let todayKey = Retention.dayKey(for: now)
            let todayActivity = try db.dailyActivity(from: todayKey, to: todayKey)
            c.equal("daily: today comes from the fine table", todayActivity[todayKey]?.cpuMS, 500)

            log("  retention: 8 fine rows -> 1 recent + 1 rolled minute bucket, purge verified")
            log("  daily: rollup preserved totals and stayed idempotent across two passes")
        } catch {
            c.report.failures.append("retention check failed: \(error)")
        }
    }
}
