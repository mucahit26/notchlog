import Foundation

/// Renders a window of collected data as a plain-text report.
///
/// Written into NotchLog's own directory rather than `~/Downloads`: writing to
/// Downloads, Desktop or Documents from a non-sandboxed app triggers a TCC prompt,
/// and this app is meant to ask for nothing. The UI reveals the file in Finder, and
/// offers a Save As… that uses NSSavePanel, whose user-chosen path carries its own
/// consent and so also raises no prompt.
public enum Exporter {
    public static func write(db: Database,
                             hours: Double = 24,
                             now: Date = Date(),
                             directory: URL = Paths.exportsDir) throws -> URL {
        try Paths.ensureRoot()
        let text = try render(db: db, hours: hours, now: now)
        let url = directory.appendingPathComponent("notchlog-\(Format.fileStamp(now)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func render(db: Database, hours: Double = 24, now: Date = Date()) throws -> String {
        let since = now.addingTimeInterval(-hours * 3600)
        let stats = try db.stats(since: since, until: now)
        let hourly = try db.hourlyLeaders(since: since, until: now)

        var out = ""
        func line(_ s: String = "") { out += s + "\n" }
        func rule() { line(String(repeating: "-", count: 78)) }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let windowSeconds = Int(hours * 3600)
        let pct = windowSeconds > 0 ? Double(stats.sampledSeconds) / Double(windowSeconds) * 100 : 0

        line("NotchLog activity report")
        rule()
        line("Generated   : \(Format.timestamp(now))")
        line("Window      : \(Format.timestamp(since))  ->  \(Format.timestamp(now))  (\(Int(hours)) hours)")
        var coverage = "\(Format.duration(Double(stats.sampledSeconds))) of the window "
            + "(\(String(format: "%.1f", pct))%)"
        if let f = stats.firstSample, let l = stats.lastSample {
            coverage += ", from \(Format.timestamp(f)) to \(Format.timestamp(l))"
        }
        line("Sampled     : \(coverage)")
        if stats.gapSeconds > 0 {
            line("Gaps        : \(Format.duration(Double(stats.gapSeconds))) " +
                 "(startup baselines, sleep, or a stalled sample)")
        }
        line("System      : macOS \(os.majorVersion).\(os.minorVersion), " +
             "\(ProcessInfo.processInfo.activeProcessorCount) cores")
        line("Database    : \(Format.bytes(UInt64(max(0, db.fileSizeBytes))))")
        line()
        line("Notes on accuracy — please read before drawing conclusions:")
        line("  * CPU is a percentage of ONE core, so a multi-threaded app can exceed 100%.")
        line("  * Network totals are a LOWER BOUND. Counters are read per open socket, so")
        line("    bytes moved between the last sample and a socket closing are not counted.")
        line("  * Memory sums helper processes into their parent app, which double-counts")
        line("    shared framework pages. Activity Monitor has the same artefact.")
        line("  * Disk I/O covers YOUR OWN processes only. macOS does not expose per-process")
        line("    disk activity for root-owned system daemons without elevated privileges,")
        line("    so those rows are blank rather than zero.")
        line()

        guard !stats.rows.isEmpty else {
            line("No samples in this window yet.")
            return out
        }

        func section(_ title: String,
                     _ header: String,
                     _ sorted: [AggregateRow],
                     _ row: (Int, AggregateRow) -> String) {
            line(title)
            rule()
            line(header)
            if sorted.isEmpty { line("  (nothing recorded)") }
            for (i, r) in sorted.prefix(15).enumerated() { line(row(i + 1, r)) }
            line()
        }

        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
        }
        func lpad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
        }

        section("TOP CPU  (by total CPU time consumed)",
                "   #  Application                     CPU time      Avg %    Peak %",
                stats.rows.filter { $0.cpuMS > 0 }.sorted { $0.cpuMS > $1.cpuMS }) { i, r in
            "  " + lpad("\(i)", 2) + "  " + pad(r.name, 30) + "  "
                + lpad(Format.duration(Double(r.cpuMS) / 1000), 10) + "  "
                + lpad(Format.percent(r.avgCPUPercent), 8) + "  "
                + lpad(Format.percent(r.peakCPUPercent), 8)
        }

        section("TOP MEMORY  (by peak resident size)",
                "   #  Application                     Peak RSS      Avg RSS",
                stats.rows.sorted { $0.rssMaxKB > $1.rssMaxKB }) { i, r in
            "  " + lpad("\(i)", 2) + "  " + pad(r.name, 30) + "  "
                + lpad(Format.kilobytes(Int(r.rssMaxKB)), 10) + "  "
                + lpad(Format.kilobytes(Int(r.rssAvgKB)), 11)
        }

        section("TOP NETWORK  (lower bound, see notes)",
                "   #  Application                     Download          Upload           Total",
                stats.rows.filter { $0.netTotal > 0 }.sorted { $0.netTotal > $1.netTotal }) { i, r in
            "  " + lpad("\(i)", 2) + "  " + pad(r.name, 30) + "  "
                + lpad(Format.bytes(UInt64(r.netIn)), 10) + "  "
                + lpad(Format.bytes(UInt64(r.netOut)), 14) + "  "
                + lpad(Format.bytes(UInt64(r.netTotal)), 14)
        }

        section("TOP DISK I/O  (your own processes only, see notes)",
                "   #  Application                         Read           Written",
                stats.rows.filter { $0.diskTotal > 0 }.sorted { $0.diskTotal > $1.diskTotal }) { i, r in
            "  " + lpad("\(i)", 2) + "  " + pad(r.name, 30) + "  "
                + lpad(Format.bytes(UInt64(r.diskRead ?? 0)), 10) + "  "
                + lpad(Format.bytes(UInt64(r.diskWritten ?? 0)), 16)
        }

        // --- hourly timeline ---
        line("HOURLY TIMELINE  (busiest app on each axis)")
        rule()
        line("  Hour   CPU                       Memory                    Network")
        let hf = DateFormatter(); hf.dateFormat = "MM-dd HH:00"
        for h in hourly {
            line("  " + pad(hf.string(from: h.hour), 12) + " " + pad(h.cpu ?? "-", 25) + " "
                 + pad(h.ram ?? "-", 25) + " " + (h.net ?? "-"))
        }
        line()

        // --- app events ---
        line("APPLICATION LAUNCH / QUIT  (\(stats.events.count) events)")
        rule()
        if stats.events.isEmpty {
            line("  (none recorded)")
        } else {
            let ef = DateFormatter(); ef.dateFormat = "MM-dd HH:mm:ss"
            for e in stats.events.suffix(200) {
                line("  " + pad(ef.string(from: e.date), 16) + (e.launched ? "launched  " : "quit      ") + e.name)
            }
            if stats.events.count > 200 {
                line("  ... \(stats.events.count - 200) earlier events omitted")
            }
        }
        line()
        line("Generated by NotchLog — https://github.com/mucahit26/notchlog")
        line("This file was produced entirely from local system counters. NotchLog has no")
        line("network code and makes no outbound connections.")
        return out
    }
}
