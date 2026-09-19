import Foundation

/// Every file NotchLog owns lives under one directory, created 0700, with the
/// database at 0600. Nothing is ever written to Downloads/Desktop/Documents
/// without an explicit NSSavePanel, because doing so triggers a TCC prompt.
public enum Paths {
    public static let bundleID = "com.mucahit26.notchlog"

    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchLog", isDirectory: true)
    }

    public static var databaseURL: URL { root.appendingPathComponent("notchlog.sqlite") }
    public static var exportsDir: URL { root.appendingPathComponent("exports", isDirectory: true) }

    /// Creates the directory tree with restrictive permissions. Safe to call repeatedly.
    @discardableResult
    public static func ensureRoot() throws -> URL {
        let fm = FileManager.default
        for dir in [root, exportsDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        }
        return root
    }

    /// SQLite creates `-wal` and `-shm` siblings using the process umask, so they can
    /// land at 0644 even when the main database is 0600. Clamp all three.
    public static func tightenDatabasePermissions() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let p = databaseURL.path + suffix
            if fm.fileExists(atPath: p) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            }
        }
    }
}
