import Foundation
import SQLite3

public struct AggregateRow: Sendable {
    public var name: String
    public var cpuMS: Int64
    public var rssAvgKB: Double
    public var rssMaxKB: Int64
    public var netIn: Int64
    public var netOut: Int64
    public var diskRead: Int64?
    public var diskWritten: Int64?
    /// Seconds of sampled coverage contributing to this row.
    public var coveredSeconds: Int64
    /// Highest single-sample CPU, as a percentage of one core.
    public var peakCPUPercent: Double

    public var netTotal: Int64 { netIn + netOut }
    public var diskTotal: Int64 { (diskRead ?? 0) + (diskWritten ?? 0) }
    public var avgCPUPercent: Double {
        coveredSeconds <= 0 ? 0 : Double(cpuMS) / (Double(coveredSeconds) * 1000) * 100
    }
}

public struct AppEventRow: Sendable {
    public var date: Date
    public var name: String
    public var launched: Bool
}

public struct WindowStats: Sendable {
    public var rows: [AggregateRow]
    public var events: [AppEventRow]
    public var gapSeconds: Int
    /// Seconds in the window that actually carry samples. This is measured from the
    /// stored rows, not inferred from the window length minus gaps — on a fresh
    /// install the window is mostly "before NotchLog existed", which is not a gap.
    public var sampledSeconds: Int
    public var firstSample: Date?
    public var lastSample: Date?
}

public extension Database {
    /// Aggregates a time window across both resolutions.
    ///
    /// `sample_fine` rows represent 10 seconds each and `sample_minute` rows 60, so the
    /// per-row span is carried through the union and used to weight averages and to
    /// compute a true peak. Without it, a rolled-up minute would be treated as if it
    /// were a 10-second sample and CPU percentages would read 6x too high.
    func stats(since: Date, until: Date = Date(), fineSpan: Int = 10) throws -> WindowStats {
        try sync {
            let lo = Int64(since.timeIntervalSince1970)
            let hi = Int64(until.timeIntervalSince1970)

            let sql = """
            WITH s AS (
                SELECT ts, app_id, cpu_ms, rss_kb AS rss_avg, rss_kb AS rss_max,
                       net_in, net_out, disk_r, disk_w, \(fineSpan) AS span
                  FROM sample_fine  WHERE ts >= ? AND ts <= ?
                UNION ALL
                SELECT ts, app_id, cpu_ms, rss_kb_avg, rss_kb_max,
                       net_in, net_out, disk_r, disk_w, 60 AS span
                  FROM sample_minute WHERE ts >= ? AND ts <= ?
            )
            SELECT app.name,
                   SUM(s.cpu_ms),
                   SUM(s.rss_avg * s.span) / CAST(SUM(s.span) AS REAL),
                   MAX(s.rss_max),
                   SUM(s.net_in), SUM(s.net_out),
                   SUM(s.disk_r), SUM(s.disk_w),
                   SUM(s.span),
                   MAX(s.cpu_ms * 100.0 / (s.span * 1000.0))
              FROM s JOIN app ON app.id = s.app_id
             GROUP BY s.app_id;
            """
            let stmt = try prepareRaw(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, lo); sqlite3_bind_int64(stmt, 2, hi)
            sqlite3_bind_int64(stmt, 3, lo); sqlite3_bind_int64(stmt, 4, hi)

            var rows: [AggregateRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(AggregateRow(
                    name: String(cString: sqlite3_column_text(stmt, 0)),
                    cpuMS: sqlite3_column_int64(stmt, 1),
                    rssAvgKB: sqlite3_column_double(stmt, 2),
                    rssMaxKB: sqlite3_column_int64(stmt, 3),
                    netIn: sqlite3_column_int64(stmt, 4),
                    netOut: sqlite3_column_int64(stmt, 5),
                    diskRead: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6),
                    diskWritten: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7),
                    coveredSeconds: sqlite3_column_int64(stmt, 8),
                    peakCPUPercent: sqlite3_column_double(stmt, 9)))
            }

            // --- events ---
            var events: [AppEventRow] = []
            let ev = try prepareRaw("""
                SELECT app_event.ts, app.name, app_event.kind
                  FROM app_event JOIN app ON app.id = app_event.app_id
                 WHERE app_event.ts >= ? AND app_event.ts <= ?
                 ORDER BY app_event.ts;
                """)
            defer { sqlite3_finalize(ev) }
            sqlite3_bind_int64(ev, 1, lo); sqlite3_bind_int64(ev, 2, hi)
            while sqlite3_step(ev) == SQLITE_ROW {
                events.append(AppEventRow(
                    date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(ev, 0))),
                    name: String(cString: sqlite3_column_text(ev, 1)),
                    launched: sqlite3_column_int(ev, 2) == 0))
            }

            // --- coverage ---
            var gapSeconds = 0
            let g = try prepareRaw("SELECT COALESCE(SUM(seconds), 0) FROM gap WHERE ts >= ? AND ts <= ?;")
            defer { sqlite3_finalize(g) }
            sqlite3_bind_int64(g, 1, lo); sqlite3_bind_int64(g, 2, hi)
            if sqlite3_step(g) == SQLITE_ROW { gapSeconds = Int(sqlite3_column_int64(g, 0)) }

            // Distinct timestamps, weighted by each table's resolution.
            var sampled = 0
            let cov = try prepareRaw("""
                SELECT (SELECT COUNT(DISTINCT ts) FROM sample_fine   WHERE ts >= ? AND ts <= ?) * ?
                     + (SELECT COUNT(DISTINCT ts) FROM sample_minute WHERE ts >= ? AND ts <= ?) * 60;
                """)
            defer { sqlite3_finalize(cov) }
            sqlite3_bind_int64(cov, 1, lo); sqlite3_bind_int64(cov, 2, hi)
            sqlite3_bind_int64(cov, 3, Int64(fineSpan))
            sqlite3_bind_int64(cov, 4, lo); sqlite3_bind_int64(cov, 5, hi)
            if sqlite3_step(cov) == SQLITE_ROW { sampled = Int(sqlite3_column_int64(cov, 0)) }

            var first: Date?, last: Date?
            let b = try prepareRaw("""
                SELECT MIN(ts), MAX(ts) FROM (
                    SELECT ts FROM sample_fine   WHERE ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT ts FROM sample_minute WHERE ts >= ? AND ts <= ?);
                """)
            defer { sqlite3_finalize(b) }
            sqlite3_bind_int64(b, 1, lo); sqlite3_bind_int64(b, 2, hi)
            sqlite3_bind_int64(b, 3, lo); sqlite3_bind_int64(b, 4, hi)
            if sqlite3_step(b) == SQLITE_ROW, sqlite3_column_type(b, 0) != SQLITE_NULL {
                first = Date(timeIntervalSince1970: Double(sqlite3_column_int64(b, 0)))
                last = Date(timeIntervalSince1970: Double(sqlite3_column_int64(b, 1)))
            }

            return WindowStats(rows: rows, events: events, gapSeconds: gapSeconds,
                               sampledSeconds: sampled, firstSample: first, lastSample: last)
        }
    }

    /// Per-hour busiest app on each axis, for the export's timeline section.
    func hourlyLeaders(since: Date, until: Date = Date()) throws -> [(hour: Date, cpu: String?, ram: String?, net: String?)] {
        try sync {
            let stmt = try prepareRaw("""
            WITH s AS (
                SELECT ts, app_id, cpu_ms, rss_kb AS rss, net_in + net_out AS net FROM sample_fine WHERE ts >= ? AND ts <= ?
                UNION ALL
                SELECT ts, app_id, cpu_ms, rss_kb_max, net_in + net_out FROM sample_minute WHERE ts >= ? AND ts <= ?
            ), agg AS (
                SELECT (ts / 3600) * 3600 AS hour, app_id,
                       SUM(cpu_ms) AS cpu, MAX(rss) AS rss, SUM(net) AS net
                  FROM s GROUP BY hour, app_id
            )
            SELECT hour,
                   (SELECT app.name FROM agg a2 JOIN app ON app.id = a2.app_id
                     WHERE a2.hour = agg.hour ORDER BY a2.cpu DESC LIMIT 1),
                   (SELECT app.name FROM agg a2 JOIN app ON app.id = a2.app_id
                     WHERE a2.hour = agg.hour ORDER BY a2.rss DESC LIMIT 1),
                   (SELECT app.name FROM agg a2 JOIN app ON app.id = a2.app_id
                     WHERE a2.hour = agg.hour AND a2.net > 0 ORDER BY a2.net DESC LIMIT 1)
              FROM agg GROUP BY hour ORDER BY hour;
            """)
            defer { sqlite3_finalize(stmt) }
            let lo = Int64(since.timeIntervalSince1970), hi = Int64(until.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 1, lo); sqlite3_bind_int64(stmt, 2, hi)
            sqlite3_bind_int64(stmt, 3, lo); sqlite3_bind_int64(stmt, 4, hi)

            var out: [(Date, String?, String?, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String? {
                    sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil
                        : String(cString: sqlite3_column_text(stmt, i))
                }
                out.append((Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                            text(1), text(2), text(3)))
            }
            return out
        }
    }
}

// MARK: - calendar

/// One local calendar day's totals, for the heat map.
public struct DayActivity: Sendable, Equatable {
    public var day: Int              // YYYYMMDD, local
    public var cpuMS: Int64
    public var netBytes: Int64
    public var sampledSeconds: Int64
}

public struct DayApp: Sendable, Equatable, Identifiable {
    public var name: String
    public var cpuMS: Int64
    public var netBytes: Int64
    public var rssMaxKB: Int64
    public var id: String { name }
}

public extension Database {
    /// Daily totals across a date range, keyed by `YYYYMMDD`.
    ///
    /// Reads `sample_fine` and `sample_day` only. It must NOT also read
    /// `sample_minute`: rows older than 24 h are written into *both* the minute table
    /// and the daily table by the same retention pass, so including all three would
    /// double-count every day but today. `sample_fine` (< 24 h) and `sample_day`
    /// (>= 24 h) are disjoint by construction.
    func dailyActivity(from: Int, to: Int) throws -> [Int: DayActivity] {
        try sync {
            let stmt = try prepareRaw("""
            WITH merged AS (
                SELECT CAST(strftime('%Y%m%d', ts, 'unixepoch', 'localtime') AS INTEGER) AS day,
                       cpu_ms AS cpu, net_in + net_out AS net, 10 AS secs
                  FROM sample_fine
                UNION ALL
                SELECT day, cpu_ms, net_in + net_out, sampled_s FROM sample_day
            )
            SELECT day, SUM(cpu), SUM(net), SUM(secs)
              FROM merged WHERE day >= ? AND day <= ?
             GROUP BY day;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(from))
            sqlite3_bind_int64(stmt, 2, Int64(to))

            var out: [Int: DayActivity] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let day = Int(sqlite3_column_int64(stmt, 0))
                out[day] = DayActivity(day: day,
                                       cpuMS: sqlite3_column_int64(stmt, 1),
                                       netBytes: sqlite3_column_int64(stmt, 2),
                                       sampledSeconds: sqlite3_column_int64(stmt, 3))
            }
            return out
        }
    }

    /// Busiest apps on one local day. Same disjointness argument as `dailyActivity`.
    func apps(onDay day: Int, limit: Int = 6) throws -> [DayApp] {
        try sync {
            let stmt = try prepareRaw("""
            WITH merged AS (
                SELECT CAST(strftime('%Y%m%d', ts, 'unixepoch', 'localtime') AS INTEGER) AS day,
                       app_id, cpu_ms AS cpu, net_in + net_out AS net, rss_kb AS rss
                  FROM sample_fine
                UNION ALL
                SELECT day, app_id, cpu_ms, net_in + net_out, rss_kb_max FROM sample_day
            )
            SELECT app.name, SUM(m.cpu), SUM(m.net), MAX(m.rss)
              FROM merged m JOIN app ON app.id = m.app_id
             WHERE m.day = ?
             GROUP BY m.app_id
             ORDER BY SUM(m.cpu) DESC
             LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(day))
            sqlite3_bind_int64(stmt, 2, Int64(limit))

            var out: [DayApp] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DayApp(name: String(cString: sqlite3_column_text(stmt, 0)),
                                  cpuMS: sqlite3_column_int64(stmt, 1),
                                  netBytes: sqlite3_column_int64(stmt, 2),
                                  rssMaxKB: sqlite3_column_int64(stmt, 3)))
            }
            return out
        }
    }
}
