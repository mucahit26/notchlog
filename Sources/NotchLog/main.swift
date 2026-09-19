import AppKit
import Foundation
import NotchLogKit

/// Swift 6 will not let a @Sendable closure mutate captured state; this is the
/// smallest thing that satisfies it for a debug counter.
final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "selftest":
    print("notchlog \(NotchLog.version) — self test")
    let report = SelfTest.run()
    print("")
    if report.ok {
        print("PASS — \(report.passed) checks")
        exit(0)
    } else {
        print("FAIL — \(report.passed) passed, \(report.failures.count) failed:")
        for f in report.failures { print("  ✗ \(f)") }
        exit(1)
    }
case "sample":
    // Debug aid: run a few ticks and print the leaderboards, so the collection
    // pipeline can be verified without the UI.
    let sampler = Sampler()
    let ticks = Int(args.dropFirst().first ?? "3") ?? 3
    for i in 0..<ticks {
        let t0 = Date()
        let snap = try sampler.tick()
        let cost = Date().timeIntervalSince(t0)
        let iv = String(format: "%.1f", snap.interval)
        let cs = String(format: "%.3f", cost)
        let note = snap.isGap ? "  (baseline tick, deltas discarded)" : ""
        print("\n--- tick \(i + 1)/\(ticks)  interval=\(iv)s  cost=\(cs)s  apps=\(snap.apps.count)\(note)")
        if !snap.isGap {
            func top(_ label: String, _ by: (AppUsage, AppUsage) -> Bool,
                     _ fmt: (AppUsage) -> String, _ keep: (AppUsage) -> Bool) {
                let rows = snap.apps.filter(keep).sorted(by: by).prefix(5)
                guard !rows.isEmpty else { return }
                print("  \(label): " + rows.map { "\($0.name) \(fmt($0))" }.joined(separator: ", "))
            }
            top("CPU", { $0.cpuMS > $1.cpuMS },
                { Format.percent($0.cpuPercent(interval: snap.interval)) }, { $0.cpuMS > 0 })
            top("RAM", { $0.rssKB > $1.rssKB }, { Format.kilobytes($0.rssKB) }, { _ in true })
            top("NET", { $0.netTotal > $1.netTotal },
                { "↓\(Format.bytes($0.netIn)) ↑\(Format.bytes($0.netOut))" },
                { $0.netTotal > 0 })
            top("DISK", { $0.diskTotal > $1.diskTotal },
                { "r\(Format.bytes($0.diskRead ?? 0)) w\(Format.bytes($0.diskWritten ?? 0))" },
                { $0.diskTotal > 0 })
        }
        if i < ticks - 1 { Thread.sleep(forTimeInterval: 10) }
    }

case "collect":
    // Headless collection, for verifying the storage pipeline without the UI.
    let seconds = Double(args.dropFirst().first ?? "60") ?? 60
    var cfg = Monitor.Config()
    cfg.logInterval = 10
    let monitor = try Monitor(config: cfg)
    monitor.onError = { print("  error: \($0)") }
    let ticks = Counter()
    monitor.onSnapshot = { snap in
        let tag = snap.isGap ? " (baseline)" : ""
        print("  tick \(ticks.next()): \(snap.apps.count) apps\(tag)")
    }
    monitor.start()
    print("collecting for \(Int(seconds))s into \(Paths.databaseURL.path)")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    monitor.stop()
    print("database size: \(Format.bytes(UInt64(max(0, monitor.database.fileSizeBytes))))")
    let url = try monitor.export(hours: 24)
    print("exported: \(url.path)")

case "export":
    let hours = Double(args.dropFirst().first ?? "24") ?? 24
    let db = try Database()
    let url = try Exporter.write(db: db, hours: hours)
    print(url.path)

case "retention":
    let db = try Database()
    let r = try Retention().run(on: db)
    print("rolled up \(r.rolledUp), purged \(r.purgedFine) fine + \(r.purgedMinute) minute rows")
    print("size \(Format.bytes(UInt64(max(0, r.bytesBefore)))) -> \(Format.bytes(UInt64(max(0, r.bytesAfter))))")

case "preview":
    // Development aid: render the panel to a PNG so the layout can be reviewed
    // without putting anything on screen.
    let out = args.dropFirst().first ?? "panel.png"
    let dark = !args.contains("--light")
    let page = args.contains("--calendar") ? 1 : 0
    MainActor.assumeIsolated {
        _ = NSApplication.shared          // SwiftUI rendering needs an app instance
        NSApp.setActivationPolicy(.prohibited)
        if !dark { NSApp.appearance = NSAppearance(named: .aqua) }
        else { NSApp.appearance = NSAppearance(named: .darkAqua) }
        do {
            try PanelPreview.render(to: URL(fileURLWithPath: out), dark: dark, page: page)
            print(out)
        } catch {
            FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
            exit(1)
        }
    }

case "version", "--version", "-v":
    print(NotchLog.version)
case "help", "--help", "-h":
    print("""
    notchlog \(NotchLog.version)

      notchlog             run the monitor (normally started by launchd)
      notchlog selftest    verify the parsers against your own system
      notchlog export [h]  write a report for the last h hours (default 24)
      notchlog sample [n]  print n live samples to the terminal
      notchlog retention   force a rollup and purge now
      notchlog preview <f> render the panel to a PNG (--light, --calendar)
      notchlog version
    """)
case nil, "run":
    runApp()

default:
    FileHandle.standardError.write(Data("unknown command: \(args[0])\n".utf8))
    exit(2)
}

func runApp() {
    // Top-level code is not main-actor isolated, but everything below runs before the
    // run loop starts and is on the main thread by construction.
    MainActor.assumeIsolated { startApp() }
}

@MainActor
private func startApp() {
    let app = NSApplication.shared
    // .accessory: no Dock icon, no app switcher entry, no menu of its own. This is what
    // makes it a background resident rather than an app the user launches and switches to.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    _ = delegate
}
