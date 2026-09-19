import Foundation

public enum Format {
    /// Base-10 byte units, matching what Activity Monitor and Finder show.
    public static func bytes(_ v: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(v), i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        if i == 0 { return "\(v) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    public static func kilobytes(_ kb: Int) -> String { bytes(UInt64(max(0, kb)) * 1024) }

    /// CPU is reported as a percentage of ONE core, so it can exceed 100%.
    public static func percent(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }

    public static func duration(_ seconds: Double) -> String {
        // Below ten seconds, whole-second rounding turns every light process into "0s",
        // which makes a CPU leaderboard useless at the bottom.
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    public static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    public static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: d)
    }
}
