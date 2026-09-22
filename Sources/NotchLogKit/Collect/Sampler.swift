import Foundation

/// One application's resource use during a single sampling interval.
public struct AppUsage: Sendable, Equatable {
    public var name: String
    public var bundlePath: String?
    /// CPU consumed during the interval, in milliseconds. Additive and exact,
    /// which is why this — not a percentage — is what gets persisted.
    public var cpuMS: Int
    public var rssKB: Int
    public var netIn: UInt64
    public var netOut: UInt64
    /// nil when no process in this group was readable (i.e. all root-owned).
    public var diskRead: UInt64?
    public var diskWritten: UInt64?
    public var processCount: Int

    /// Percentage of ONE core, so it can exceed 100% for a multi-threaded app.
    public func cpuPercent(interval: TimeInterval) -> Double {
        interval <= 0 ? 0 : Double(cpuMS) / (interval * 1000) * 100
    }

    public var netTotal: UInt64 { netIn &+ netOut }
    public var diskTotal: UInt64 { (diskRead ?? 0) &+ (diskWritten ?? 0) }
}

public struct Snapshot: Sendable {
    public var date: Date
    public var interval: TimeInterval
    public var apps: [AppUsage]
    /// True when this tick follows a gap (sleep, wedged sample) and deltas were
    /// discarded rather than reported as a huge spike.
    public var isGap: Bool
}

/// Turns cumulative system counters into per-interval deltas.
///
/// Everything here is single-shot polling. Continuous `nettop` was measured burning
/// ~145% CPU regardless of its interval, while a single-shot poll costs 0.01 CPU-seconds;
/// at a 10 s tick the whole sampler is roughly 0.2% of one core.
public final class Sampler {
    public struct Config: Sendable {
        public var interval: TimeInterval = 10
        /// A wall-clock jump beyond this multiple of `interval` means sleep or a stall,
        /// so baselines are reset instead of emitting a nonsense delta.
        public var gapFactor: Double = 3
        public init() {}
    }

    private var prevCPU: [Int32: Double] = [:]
    private var prevConn: [String: (inB: UInt64, outB: UInt64)] = [:]
    private var prevDisk: [Int32: DiskIOSource.IO] = [:]
    private var prevDate: Date?
    private let cores: Double
    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
        self.cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Discards accumulated baselines. Call on wake, so the first post-sleep tick
    /// does not report hours of CPU time as if it happened in ten seconds.
    public func resetBaselines() {
        prevCPU.removeAll(); prevConn.removeAll(); prevDisk.removeAll(); prevDate = nil
    }

    public func tick(now: Date = Date()) throws -> Snapshot {
        let procs = try PSSource.sample()
        let net = try NettopSource.sample()

        let elapsed = prevDate.map { now.timeIntervalSince($0) } ?? config.interval
        let isGap = prevDate == nil || elapsed > config.interval * config.gapFactor || elapsed <= 0
        let effective = isGap ? config.interval : elapsed

        // --- CPU: delta of cumulative CPU time -------------------------------------
        // `ps` %CPU is a kernel decayed average and is badly wrong on bursts (one
        // process reported 76.3% while actually using 9.4%), so it is never used.
        var cpuByPID: [Int32: Double] = [:]
        var nextCPU: [Int32: Double] = [:]
        nextCPU.reserveCapacity(procs.count)
        let ceiling = effective * cores            // a process cannot exceed all cores
        for p in procs {
            nextCPU[p.pid] = p.cpuSeconds
            guard !isGap else { continue }
            if let before = prevCPU[p.pid] {
                cpuByPID[p.pid] = max(0, p.cpuSeconds - before)
            } else {
                // Newly observed: it may genuinely have just started and burned CPU,
                // but it may also be a pid we simply hadn't seen. Cap at what is
                // physically possible in the interval rather than trusting lifetime total.
                cpuByPID[p.pid] = min(p.cpuSeconds, ceiling)
            }
        }
        prevCPU = nextCPU

        // Sampled for every process on purpose. Restricting this to "processes that
        // look busy" was tried and reverted: `prevDisk` then holds only that subset, so
        // a process moving in and out of the filter loses its baseline and reports a
        // delta of zero. It cost the disk column its data and saved no measurable CPU.
        let disk = DiskIOSource.sample(pids: procs.map(\.pid))

        // --- Network: per-socket deltas ---------------------------------------------
        // Counters are cumulative per open socket. A closed socket simply stops
        // appearing, so bytes moved between the last poll and the close are lost —
        // totals are a lower bound, and the export says so.
        var netByPID: [Int32: (UInt64, UInt64)] = [:]
        var nextConn: [String: (inB: UInt64, outB: UInt64)] = [:]
        nextConn.reserveCapacity(net.connections.count)
        for c in net.connections {
            nextConn[c.key] = (c.bytesIn, c.bytesOut)
            guard !isGap else { continue }
            let (dIn, dOut): (UInt64, UInt64)
            if let before = prevConn[c.key] {
                // Clamp: a counter can legitimately reset if a pid is reused.
                dIn = c.bytesIn > before.inB ? c.bytesIn - before.inB : 0
                dOut = c.bytesOut > before.outB ? c.bytesOut - before.outB : 0
            } else {
                dIn = c.bytesIn; dOut = c.bytesOut    // brand new socket
            }
            let acc = netByPID[c.pid] ?? (0, 0)
            netByPID[c.pid] = (acc.0 &+ dIn, acc.1 &+ dOut)
        }
        prevConn = nextConn

        // --- Disk: own-user processes only ------------------------------------------
        var diskByPID: [Int32: (UInt64, UInt64)] = [:]
        for (pid, io) in disk where !isGap {
            if let before = prevDisk[pid] {
                diskByPID[pid] = (io.read > before.read ? io.read - before.read : 0,
                                  io.written > before.written ? io.written - before.written : 0)
            } else {
                diskByPID[pid] = (0, 0)   // no baseline yet; don't attribute lifetime totals
            }
        }
        prevDisk = disk

        // --- Group per-process figures into applications ------------------------------
        var groups: [String: AppUsage] = [:]
        for p in procs {
            let id = AppIdentity.identify(execPath: p.execPath)
            let cpuMS = Int(((cpuByPID[p.pid] ?? 0) * 1000).rounded())
            let (nIn, nOut) = netByPID[p.pid] ?? (0, 0)
            let dio = diskByPID[p.pid]

            if var g = groups[id.name] {
                g.cpuMS += cpuMS
                // Summing RSS across helpers double-counts shared framework pages.
                // Activity Monitor has the same artefact; the README says so.
                g.rssKB += p.rssKB
                g.netIn &+= nIn
                g.netOut &+= nOut
                if let d = dio {
                    g.diskRead = (g.diskRead ?? 0) &+ d.0
                    g.diskWritten = (g.diskWritten ?? 0) &+ d.1
                }
                g.processCount += 1
                groups[id.name] = g
            } else {
                groups[id.name] = AppUsage(
                    name: id.name, bundlePath: id.bundlePath, cpuMS: cpuMS, rssKB: p.rssKB,
                    netIn: nIn, netOut: nOut,
                    diskRead: dio?.0, diskWritten: dio?.1, processCount: 1)
            }
        }

        // Network attributed to a pid that `ps` no longer lists (it exited between the
        // two polls). Keep the bytes rather than silently dropping them.
        let seen = Set(procs.map(\.pid))
        for (pid, bytes) in netByPID where !seen.contains(pid) {
            let name = net.names[pid] ?? "pid \(pid)"
            var g = groups[name] ?? AppUsage(name: name, bundlePath: nil, cpuMS: 0, rssKB: 0,
                                             netIn: 0, netOut: 0, diskRead: nil,
                                             diskWritten: nil, processCount: 0)
            g.netIn &+= bytes.0
            g.netOut &+= bytes.1
            groups[name] = g
        }

        prevDate = now
        return Snapshot(date: now, interval: effective,
                        apps: Array(groups.values), isGap: isGap)
    }
}
