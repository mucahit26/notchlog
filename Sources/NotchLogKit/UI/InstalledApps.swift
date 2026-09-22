import AppKit
import Foundation

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public var id: String { path }

    public var taskApp: TaskApp { TaskApp(name: name, bundleID: bundleID) }
}

/// Lists the applications installed on this Mac, for the task page's picker.
///
/// A plain directory scan of the standard locations. It needs no permission — these
/// directories are world-readable — and deliberately avoids LaunchServices, whose
/// database includes every app the machine has ever seen, including ones inside disk
/// images and Trash.
public enum InstalledApps {
    static let searchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]

    /// Reading ~90 `Info.plist` files takes long enough to be worth keeping off the
    /// main thread and caching for the session.
    public static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let fm = FileManager.default

        for directory in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                let bundle = Bundle(path: path)
                let bundleID = bundle?.bundleIdentifier
                // A bundle id is the stable identity; fall back to the folder name for
                // the rare app that has none.
                let key = bundleID ?? path
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let display = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(entry.dropLast(4))
                apps.append(InstalledApp(name: display, bundleID: bundleID, path: path))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func icon(forPath path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
