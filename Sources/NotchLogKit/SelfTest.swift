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

        return c.report
    }
}
