import AppKit
import SwiftUI

/// What the expanded panel shows. Updated from the sampler on the main queue.
@MainActor
public final class LiveModel: ObservableObject {
    @Published public var topCPU: [AppUsage] = []
    @Published public var topRAM: [AppUsage] = []
    @Published public var topNet: [AppUsage] = []
    @Published public var topDisk: [AppUsage] = []
    @Published public var interval: TimeInterval = 10
    @Published public var databaseBytes: Int64 = 0
    @Published public var warning: String?
    @Published public var exportStatus: String?
    @Published public var isExporting = false

    public init() {}

    private var iconCache: [String: NSImage] = [:]

    public func icon(for app: AppUsage) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = iconCache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        iconCache[path] = image
        return image
    }

    public func apply(_ snapshot: Snapshot) {
        interval = snapshot.interval
        let apps = snapshot.apps
        topCPU = Array(apps.filter { $0.cpuMS > 0 }.sorted { $0.cpuMS > $1.cpuMS }.prefix(5))
        topRAM = Array(apps.sorted { $0.rssKB > $1.rssKB }.prefix(5))
        topNet = Array(apps.filter { $0.netTotal > 0 }.sorted { $0.netTotal > $1.netTotal }.prefix(5))
        topDisk = Array(apps.filter { $0.diskTotal > 0 }.sorted { $0.diskTotal > $1.diskTotal }.prefix(5))
    }
}
