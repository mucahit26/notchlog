import Foundation
import SQLite3

/// Keeps the database small without losing the detail the export depends on.
///
/// Two jobs, both idempotent and both safe to run at launch as a catch-up:
///
/// * **Rollup** — fine 10-second rows older than 24 h become one row per minute.
///   The cutoff is aligned down to a minute boundary so a minute is never split
///   across two rollups, which would otherwise double-count it.
/// * **Purge** — anything older than the retention window is deleted, then
///   `incremental_vacuum` hands the freed pages back to the filesystem.
///
/// The purge is deliberately *rolling* rather than a once-a-week wipe: it holds the
/// file at a steady size instead of sawtoothing up to a weekly peak.
public struct Retention: Sendable {
    public var fineWindow: TimeInterval = 24 * 3600
    public var totalWindow: TimeInterval = 7 * 24 * 3600
    /// Daily summaries are tiny — a few dozen rows per day — so they are kept far
    /// longer, which is what makes a calendar heat map worth having.
    public var dailyWindowDays: Int = 365
    public init() {}

    public struct Result: Sendable {
        public var rolledUp: Int = 0
        public var purgedFine: Int = 0
        public var purgedMinute: Int = 0
        public var purgedEvents: Int = 0
        public var bytesBefore: Int64 = 0
        public var bytesAfter: Int64 = 0
    }

    @discardableResult
    public func run(on db: Database, now: Date = Date()) throws -> Result {
        try db.sync {
            var result = Result()
            result.bytesBefore = db.fileSizeBytes

            // Align down to a whole minute so rollup never splits a bucket.
            let rawFine = now.timeIntervalSince1970 - fineWindow
            let fineCutoff = Int64((rawFine / 60).rounded(.down) * 60)
            let hardCutoff = Int64(now.timeIntervalSince1970 - totalWindow)

            try db.execRaw("BEGIN IMMEDIATE;")
            do {
                // --- daily summary --------------------------------------------------
                // Accumulated BEFORE the fine rows are deleted, in the same transaction,
                // so each fine row contributes exactly once. ON CONFLICT adds rather than
                // replaces, because a single day is rolled up across many runs.
                try db.execRaw("""
                INSERT INTO sample_day
                    (day, app_id, cpu_ms, rss_kb_max, net_in, net_out, disk_r, disk_w, sampled_s)
                SELECT CAST(strftime('%Y%m%d', ts, 'unixepoch', 'localtime') AS INTEGER) AS d,
                       app_id, SUM(cpu_ms), MAX(rss_kb), SUM(net_in), SUM(net_out),
                       SUM(disk_r), SUM(disk_w), COUNT(*) * 10
                FROM sample_fine
                WHERE ts < \(fineCutoff)
                GROUP BY d, app_id
                ON CONFLICT(day, app_id) DO UPDATE SET
                    cpu_ms     = cpu_ms + excluded.cpu_ms,
                    rss_kb_max = MAX(rss_kb_max, excluded.rss_kb_max),
                    net_in     = net_in + excluded.net_in,
                    net_out    = net_out + excluded.net_out,
                    disk_r     = COALESCE(disk_r, 0) + COALESCE(excluded.disk_r, 0),
                    disk_w     = COALESCE(disk_w, 0) + COALESCE(excluded.disk_w, 0),
                    sampled_s  = sampled_s + excluded.sampled_s;
                """)

                // --- rollup ---------------------------------------------------------
                // SUM over disk columns yields NULL only when every contributing row is
                // NULL, which is exactly the semantics we want: "nothing was readable".
                try db.execRaw("""
                INSERT OR REPLACE INTO sample_minute
                    (ts, app_id, cpu_ms, rss_kb_avg, rss_kb_max, net_in, net_out, disk_r, disk_w)
                SELECT (ts / 60) * 60 AS bucket,
                       app_id,
                       SUM(cpu_ms),
                       CAST(AVG(rss_kb) AS INTEGER),
                       MAX(rss_kb),
                       SUM(net_in),
                       SUM(net_out),
                       SUM(disk_r),
                       SUM(disk_w)
                FROM sample_fine
                WHERE ts < \(fineCutoff)
                GROUP BY bucket, app_id;
                """)
                result.rolledUp = db.changes

                try db.execRaw("DELETE FROM sample_fine WHERE ts < \(fineCutoff);")
                result.purgedFine = db.changes

                // --- purge ----------------------------------------------------------
                try db.execRaw("DELETE FROM sample_minute WHERE ts < \(hardCutoff);")
                result.purgedMinute = db.changes
                try db.execRaw("DELETE FROM app_event WHERE ts < \(hardCutoff);")
                result.purgedEvents = db.changes
                try db.execRaw("DELETE FROM gap WHERE ts < \(hardCutoff);")

                let dayCutoff = Self.dayKey(for: now.addingTimeInterval(
                    -Double(dailyWindowDays) * 86_400))
                try db.execRaw("DELETE FROM sample_day WHERE day < \(dayCutoff);")

                // Drop apps nothing references any more, so the name table cannot grow
                // without bound as short-lived processes come and go.
                try db.execRaw("""
                DELETE FROM app WHERE id NOT IN (SELECT app_id FROM sample_fine)
                                 AND id NOT IN (SELECT app_id FROM sample_minute)
                                 AND id NOT IN (SELECT app_id FROM sample_day)
                                 AND id NOT IN (SELECT app_id FROM app_event);
                """)
                try db.execRaw("COMMIT;")
            } catch {
                try? db.execRaw("ROLLBACK;")
                throw error
            }
            db.clearAppCache()   // ids may have been deleted; don't hand out stale ones

            // incremental_vacuum, not VACUUM: a full VACUUM rewrites the whole database
            // and needs roughly twice its size in temporary space — the wrong behaviour
            // for a background daemon, and worse on a disk-constrained machine.
            try db.execRaw("PRAGMA incremental_vacuum;")
            try db.execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
            Paths.tightenDatabasePermissions()

            result.bytesAfter = db.fileSizeBytes
            return result
        }
    }
}

public extension Retention {
    /// The `YYYYMMDD` key used by `sample_day`, computed with the user's own calendar
    /// so it matches what the month grid displays.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}

extension Database {
    var changes: Int { Int(sqlite3_changes(handle)) }
}
