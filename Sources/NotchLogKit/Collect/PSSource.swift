import Foundation

public struct ProcRow: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let rssKB: Int
    /// Cumulative CPU time consumed by the process since it started.
    public let cpuSeconds: Double
    /// Full executable path — `ps` `comm` without `-c` gives the whole path,
    /// which is what makes helper-to-app attribution possible.
    public let execPath: String
}

public enum PSSource {
    public static let arguments = ["-Aeo", "pid,ppid,rss,time,comm", "-r"]

    public static func sample() throws -> [ProcRow] {
        parse(try ProcessRunner.run(ProcessRunner.ps, arguments))
    }

    public static func parse(_ text: String) -> [ProcRow] {
        var rows: [ProcRow] = []
        rows.reserveCapacity(700)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // The path contains spaces, so take exactly four leading fields and
            // treat the entire remainder as the executable path.
            var fields: [Substring] = []
            var rest = line[line.startIndex...]
            for _ in 0..<4 {
                while let f = rest.first, f == " " { rest = rest.dropFirst() }
                guard let sp = rest.firstIndex(of: " ") else { rest = ""; break }
                fields.append(rest[rest.startIndex..<sp])
                rest = rest[sp...]
            }
            while let f = rest.first, f == " " { rest = rest.dropFirst() }
            guard fields.count == 4,
                  let pid = Int32(fields[0]),          // header line fails here, as intended
                  let ppid = Int32(fields[1]),
                  let rss = Int(fields[2]),
                  let cpu = parseCPUTime(fields[3]),
                  !rest.isEmpty else { continue }
            rows.append(ProcRow(pid: pid, ppid: ppid, rssKB: rss,
                                cpuSeconds: cpu, execPath: String(rest)))
        }
        return rows
    }

    /// `ps` TIME is `[DD-][HH:]MM:SS.ss`, and the minutes field is **not** capped at 60 —
    /// a long-lived WindowServer legitimately reads `256:48.19`.
    public static func parseCPUTime<S: StringProtocol>(_ s: S) -> Double? {
        var body = s[s.startIndex...]
        var days = 0.0
        if let dash = body.firstIndex(of: "-") {
            guard let d = Double(body[body.startIndex..<dash]) else { return nil }
            days = d
            body = body[body.index(after: dash)...]
        }
        let parts = body.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        // Fold the colon-separated groups first, THEN add the days. Folding days into
        // the accumulator before the loop would multiply them by 60 per group.
        var total = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return days * 86_400 + total
    }
}
