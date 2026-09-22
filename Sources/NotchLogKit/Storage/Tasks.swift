import Foundation
import SQLite3

public struct TaskApp: Sendable, Equatable, Hashable {
    public let name: String
    public let bundleID: String?
    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct TaskItem: Identifiable, Sendable, Equatable {
    public let id: Int64
    public var title: String
    public var notes: String
    public var createdAt: Date
    public var completedAt: Date?
    public var apps: [TaskApp]

    public var isOpen: Bool { completedAt == nil }
}

public extension Database {
    // MARK: - writing

    @discardableResult
    func createTask(title: String, notes: String, apps: [TaskApp],
                    now: Date = Date()) throws -> Int64 {
        try sync {
            try execRaw("BEGIN IMMEDIATE;")
            do {
                let stmt = try prepareRaw(
                    "INSERT INTO task(title, notes, created_at) VALUES(?, ?, ?);")
                sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, notes, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, Int64(now.timeIntervalSince1970.rounded()))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_finalize(stmt)
                    throw DatabaseError.exec(String(cString: sqlite3_errmsg(handle)))
                }
                sqlite3_finalize(stmt)
                let id = sqlite3_last_insert_rowid(handle)

                let link = try prepareRaw(
                    "INSERT OR IGNORE INTO task_app(task_id, app_name, bundle_id) VALUES(?, ?, ?);")
                defer { sqlite3_finalize(link) }
                for app in apps {
                    sqlite3_reset(link)
                    sqlite3_clear_bindings(link)
                    sqlite3_bind_int64(link, 1, id)
                    sqlite3_bind_text(link, 2, app.name, -1, SQLITE_TRANSIENT)
                    if let bundle = app.bundleID {
                        sqlite3_bind_text(link, 3, bundle, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(link, 3)
                    }
                    sqlite3_step(link)
                }
                try execRaw("COMMIT;")
                return id
            } catch {
                try? execRaw("ROLLBACK;")
                throw error
            }
        }
    }

    func setTaskCompleted(id: Int64, completed: Bool, now: Date = Date()) throws {
        try sync {
            let stmt = try prepareRaw("UPDATE task SET completed_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            if completed {
                sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970.rounded()))
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func deleteTask(id: Int64) throws {
        try sync {
            let stmt = try prepareRaw("DELETE FROM task WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - reading

    /// Open tasks, newest first. `completedTasks` is the archive, most recently
    /// finished first.
    func openTasks(limit: Int = 200) throws -> [TaskItem] {
        try loadTasks(where: "completed_at IS NULL",
                      order: "created_at DESC", limit: limit)
    }

    func completedTasks(limit: Int = 100) throws -> [TaskItem] {
        try loadTasks(where: "completed_at IS NOT NULL",
                      order: "completed_at DESC", limit: limit)
    }

    /// Open tasks associated with a launched application.
    ///
    /// Matches on bundle id when both sides have one — names change with localisation
    /// and updates, bundle ids do not — and falls back to the display name otherwise.
    func openTasks(forBundleID bundleID: String?, name: String?) throws -> [TaskItem] {
        guard bundleID != nil || name != nil else { return [] }
        return try sync {
            let stmt = try prepareRaw("""
                SELECT DISTINCT t.id FROM task t
                  JOIN task_app a ON a.task_id = t.id
                 WHERE t.completed_at IS NULL
                   AND ((? IS NOT NULL AND a.bundle_id = ?) OR (? IS NOT NULL AND a.app_name = ?));
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, bundleID); bind(stmt, 2, bundleID)
            bind(stmt, 3, name); bind(stmt, 4, name)
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
            guard !ids.isEmpty else { return [] }
            let list = ids.map(String.init).joined(separator: ",")
            return try loadTasksLocked(where: "id IN (\(list))",
                                       order: "created_at DESC", limit: ids.count)
        }
    }

    func taskCounts() throws -> (open: Int, done: Int) {
        try sync {
            let stmt = try prepareRaw("""
                SELECT SUM(completed_at IS NULL), SUM(completed_at IS NOT NULL) FROM task;
                """)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    // MARK: - reminders

    /// True when this task has not yet been surfaced for this application today.
    func shouldRemind(taskID: Int64, bundleID: String, now: Date = Date()) throws -> Bool {
        try sync {
            let stmt = try prepareRaw(
                "SELECT shown_at FROM task_reminder WHERE task_id = ? AND bundle_id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, taskID)
            sqlite3_bind_text(stmt, 2, bundleID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
            let last = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0)))
            return Retention.dayKey(for: last) != Retention.dayKey(for: now)
        }
    }

    func markReminded(taskID: Int64, bundleID: String, now: Date = Date()) throws {
        try sync {
            let stmt = try prepareRaw("""
                INSERT INTO task_reminder(task_id, bundle_id, shown_at) VALUES(?, ?, ?)
                ON CONFLICT(task_id, bundle_id) DO UPDATE SET shown_at = excluded.shown_at;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, taskID)
            sqlite3_bind_text(stmt, 2, bundleID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(now.timeIntervalSince1970.rounded()))
            sqlite3_step(stmt)
        }
    }

    // MARK: - internals

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func loadTasks(where clause: String, order: String, limit: Int) throws -> [TaskItem] {
        try sync { try loadTasksLocked(where: clause, order: order, limit: limit) }
    }

    /// Caller already holds the database queue.
    private func loadTasksLocked(where clause: String, order: String,
                                 limit: Int) throws -> [TaskItem] {
        let stmt = try prepareRaw("""
            SELECT id, title, notes, created_at, completed_at
              FROM task WHERE \(clause) ORDER BY \(order) LIMIT \(limit);
            """)
        defer { sqlite3_finalize(stmt) }

        var rows: [TaskItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let completedRaw = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(TaskItem(
                id: sqlite3_column_int64(stmt, 0),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                notes: String(cString: sqlite3_column_text(stmt, 2)),
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3))),
                completedAt: completedRaw.map { Date(timeIntervalSince1970: Double($0)) },
                apps: []))
        }

        guard !rows.isEmpty else { return [] }
        let ids = rows.map { String($0.id) }.joined(separator: ",")
        let link = try prepareRaw("""
            SELECT task_id, app_name, bundle_id FROM task_app
             WHERE task_id IN (\(ids)) ORDER BY app_name;
            """)
        defer { sqlite3_finalize(link) }
        var byTask: [Int64: [TaskApp]] = [:]
        while sqlite3_step(link) == SQLITE_ROW {
            let taskID = sqlite3_column_int64(link, 0)
            let bundle = sqlite3_column_type(link, 2) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(link, 2))
            byTask[taskID, default: []].append(
                TaskApp(name: String(cString: sqlite3_column_text(link, 1)), bundleID: bundle))
        }
        for index in rows.indices { rows[index].apps = byTask[rows[index].id] ?? [] }
        return rows
    }
}
