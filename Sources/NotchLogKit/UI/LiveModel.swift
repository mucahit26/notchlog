import AppKit
import SwiftUI

/// What the expanded panel shows. Updated from the sampler on the main queue.
@MainActor
public final class LiveModel: ObservableObject {
    @Published public var topCPU: [AppUsage] = []
    @Published public var topRAM: [AppUsage] = []
    @Published public var topNet: [AppUsage] = []
    @Published public var topDisk: [AppUsage] = []
    /// Column maxima, so each bar is drawn relative to the busiest app in its own
    /// column. Comparing across columns would be meaningless — percent, bytes and
    /// bytes-per-interval share no scale.
    @Published public var cpuMax: Double = 0
    @Published public var ramMax: Int = 0
    @Published public var netMax: UInt64 = 0

    /// Whole-system totals for the header strip.
    @Published public var totalCPUPercent: Double = 0
    @Published public var totalRSSKB: Int = 0
    @Published public var totalNetIn: UInt64 = 0
    @Published public var totalNetOut: UInt64 = 0

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
        topDisk = Array(apps.filter { $0.diskTotal > 0 }.sorted { $0.diskTotal > $1.diskTotal }.prefix(3))

        cpuMax = topCPU.first.map { $0.cpuPercent(interval: snapshot.interval) } ?? 0
        ramMax = topRAM.first?.rssKB ?? 0
        netMax = topNet.first?.netTotal ?? 0

        totalCPUPercent = apps.reduce(0) { $0 + $1.cpuPercent(interval: snapshot.interval) }
        totalRSSKB = apps.reduce(0) { $0 + $1.rssKB }
        totalNetIn = apps.reduce(UInt64(0)) { $0 &+ $1.netIn }
        totalNetOut = apps.reduce(UInt64(0)) { $0 &+ $1.netOut }
    }

    /// Per-process figures are a share of ONE core, so their sum can reach 800% on an
    /// 8-core machine. The header instead shows the share of the whole machine, which is
    /// the convention Activity Monitor uses for system CPU — the two units are different
    /// on purpose and both are labelled.
    public var systemCPUPercent: Double {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return cores > 0 ? min(totalCPUPercent / cores, 100) : 0
    }

    /// Bytes per second, which is more meaningful than "bytes in the last sample"
    /// when the sample interval changes between 10 s and 2 s.
    public var netInRate: UInt64 { interval > 0 ? UInt64(Double(totalNetIn) / interval) : 0 }
    public var netOutRate: UInt64 { interval > 0 ? UInt64(Double(totalNetOut) / interval) : 0 }
}
