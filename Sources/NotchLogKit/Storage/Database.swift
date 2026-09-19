import Foundation
import SQLite3

/// `sqlite3_bind_text` needs to know whether it may keep the pointer. Our Swift strings
/// do not outlive the call, so every bind is TRANSIENT (SQLite copies the bytes).
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error {
    case open(String)
    case exec(String)
    case prepare(String)
}

/// SQLite-backed store for the sampled metrics.
///
/// Storage is tiered on purpose: the last 24 hours are kept at full 10-second
/// resolution because that is exactly the window the .txt export covers, while older
/// days are rolled down to one-minute rows. That holds a detailed week at roughly
/// 80-150 MB instead of the ~500 MB a flat 7-day-at-10-seconds table would need.
/// `@unchecked Sendable` is accurate rather than a shortcut: the connection is opened
/// once in `init` and never reassigned, and every subsequent read, write and cache
/// mutation happens inside `queue`. The connection itself is opened `FULLMUTEX`, so
/// SQLite serialises internally as well.
public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.mucahit26.notchlog.db")

    public init(url: URL = Paths.databaseURL) throws {
        try Paths.ensureRoot()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle

        // auto_vacuum is a FILE FORMAT property: it must be set before the first table
        // is created, and cannot be changed later without a full rewrite. Getting the
        // order wrong here is silent and permanent, so it runs first.
        try exec("PRAGMA auto_vacuum = INCREMENTAL;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try migrate()
        Paths.tightenDatabasePermissions()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: - schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS app (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL UNIQUE,
            bundle_path TEXT
        );

        -- Last 24 h at full 10 s resolution.
        CREATE TABLE IF NOT EXISTS sample_fine (
            ts      INTEGER NOT NULL,
            app_id  INTEGER NOT NULL REFERENCES app(id),
            cpu_ms  INTEGER NOT NULL,
            rss_kb  INTEGER NOT NULL,
            net_in  INTEGER NOT NULL,
            net_out INTEGER NOT NULL,
            disk_r  INTEGER,            -- NULL: process was root-owned, not readable
            disk_w  INTEGER,
            PRIMARY KEY (ts, app_id)
        ) WITHOUT ROWID;

        -- Days 2-7, rolled down to one row per minute.
        CREATE TABLE IF NOT EXISTS sample_minute (
            ts         INTEGER NOT NULL,
            app_id     INTEGER NOT NULL REFERENCES app(id),
            cpu_ms     INTEGER NOT NULL,
            rss_kb_avg INTEGER NOT NULL,
            rss_kb_max INTEGER NOT NULL,
            net_in     INTEGER NOT NULL,
            net_out    INTEGER NOT NULL,
            disk_r     INTEGER,
            disk_w     INTEGER,
            PRIMARY KEY (ts, app_id)
        ) WITHOUT ROWID;

        CREATE TABLE IF NOT EXISTS app_event (
            ts     INTEGER NOT NULL,
            app_id INTEGER NOT NULL REFERENCES app(id),
            kind   INTEGER NOT NULL          -- 0 = launched, 1 = quit
        );
        CREATE INDEX IF NOT EXISTS idx_app_event_ts ON app_event(ts);

        -- Periods with no coverage (sleep, a wedged sample), so the export can say
        -- how complete its window actually is instead of implying full coverage.
        CREATE TABLE IF NOT EXISTS gap (
            ts      INTEGER PRIMARY KEY,
            seconds INTEGER NOT NULL,
            reason  TEXT
        );

        CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
        """)
    }

    // MARK: - primitives

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.exec(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    public func sync<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute: body) }

    // MARK: - app interning

    private var appIDCache: [String: Int64] = [:]

    private func appID(name: String, bundlePath: String?) throws -> Int64 {
        if let id = appIDCache[name] { return id }
        let ins = try prepare("INSERT OR IGNORE INTO app(name, bundle_path) VALUES(?, ?);")
        defer { sqlite3_finalize(ins) }
        sqlite3_bind_text(ins, 1, name, -1, SQLITE_TRANSIENT)
        if let bundlePath { sqlite3_bind_text(ins, 2, bundlePath, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(ins, 2) }
        sqlite3_step(ins)

        let sel = try prepare("SELECT id FROM app WHERE name = ?;")
        defer { sqlite3_finalize(sel) }
        sqlite3_bind_text(sel, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(sel) == SQLITE_ROW else {
            throw DatabaseError.exec("could not intern app \(name)")
        }
        let id = sqlite3_column_int64(sel, 0)
        appIDCache[name] = id
        return id
    }

    // MARK: - writes

    /// Rows that are simultaneously idle on every axis are not worth a row each.
    /// Anything that used CPU, moved a byte, touched the disk, or holds a meaningful
    /// amount of memory is kept; so are the top memory holders, so the leaderboard is
    /// never missing an entry it should show.
    public struct WritePolicy: Sendable {
        public var minCPUMS = 10          // 0.1% of one core over a 10 s tick
        public var minRSSKB = 50 * 1024   // 50 MB
        public var alwaysKeepTopRSS = 20
        public init() {}
    }

    public func insert(snapshot: Snapshot, policy: WritePolicy = WritePolicy()) throws {
        try queue.sync {
            guard !snapshot.isGap else {
                try recordGapLocked(at: snapshot.date, seconds: Int(snapshot.interval),
                                    reason: "baseline or wake")
                return
            }
            let ts = Int64(snapshot.date.timeIntervalSince1970.rounded())
            let topRSS = Set(snapshot.apps.sorted { $0.rssKB > $1.rssKB }
                                          .prefix(policy.alwaysKeepTopRSS).map(\.name))

            try exec("BEGIN IMMEDIATE;")
            do {
                let stmt = try prepare("""
                INSERT OR REPLACE INTO sample_fine
                    (ts, app_id, cpu_ms, rss_kb, net_in, net_out, disk_r, disk_w)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(stmt) }

                for app in snapshot.apps {
                    let interesting = app.cpuMS >= policy.minCPUMS
                        || app.netTotal > 0
                        || app.diskTotal > 0
                        || app.rssKB >= policy.minRSSKB
                        || topRSS.contains(app.name)
                    guard interesting else { continue }

                    let id = try appID(name: app.name, bundlePath: app.bundlePath)
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, ts)
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_bind_int64(stmt, 3, Int64(app.cpuMS))
                    sqlite3_bind_int64(stmt, 4, Int64(app.rssKB))
                    sqlite3_bind_int64(stmt, 5, Int64(bitPattern: app.netIn))
                    sqlite3_bind_int64(stmt, 6, Int64(bitPattern: app.netOut))
                    if let r = app.diskRead { sqlite3_bind_int64(stmt, 7, Int64(bitPattern: r)) }
                    else { sqlite3_bind_null(stmt, 7) }
                    if let w = app.diskWritten { sqlite3_bind_int64(stmt, 8, Int64(bitPattern: w)) }
                    else { sqlite3_bind_null(stmt, 8) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DatabaseError.exec(String(cString: sqlite3_errmsg(db)))
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func recordEvent(name: String, bundlePath: String?, launched: Bool, at date: Date) throws {
        try queue.sync {
            let id = try appID(name: name, bundlePath: bundlePath)
            let stmt = try prepare("INSERT INTO app_event(ts, app_id, kind) VALUES(?, ?, ?);")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970.rounded()))
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_bind_int(stmt, 3, launched ? 0 : 1)
            sqlite3_step(stmt)
        }
    }

    public func recordGap(at date: Date, seconds: Int, reason: String) throws {
        try queue.sync { try recordGapLocked(at: date, seconds: seconds, reason: reason) }
    }

    private func recordGapLocked(at date: Date, seconds: Int, reason: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO gap(ts, seconds, reason) VALUES(?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970.rounded()))
        sqlite3_bind_int64(stmt, 2, Int64(seconds))
        sqlite3_bind_text(stmt, 3, reason, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - maintenance (see Retention.swift for the policy that calls these)

    func execRaw(_ sql: String) throws { try exec(sql) }
    func prepareRaw(_ sql: String) throws -> OpaquePointer { try prepare(sql) }
    var handle: OpaquePointer? { db }
    func clearAppCache() { appIDCache.removeAll() }

    /// Row count for a table, used by the self-test to verify retention actually
    /// moved and deleted what it claimed.
    public func count(_ table: String) throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM \(table);")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public var fileSizeBytes: Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let p = Paths.databaseURL.path + suffix
            if let a = try? FileManager.default.attributesOfItem(atPath: p),
               let n = a[.size] as? Int64 { total += n }
        }
        return total
    }
}
