import Darwin
import Foundation

/// Per-process disk I/O via `proc_pid_rusage`.
///
/// **Known, unavoidable limitation:** this succeeds only for processes owned by the
/// current user. Root-owned daemons return EPERM, and there is no unprivileged way
/// around it — `iotop`, `fs_usage` and DTrace all require root, and `/bin/ps` gets its
/// figures by being setuid. Measured on a real system: 411 of 595 processes readable.
/// The UI and the export both label disk I/O as user-processes-only so the numbers are
/// never mistaken for system-wide totals.
public enum DiskIOSource {
    public struct IO: Equatable, Sendable {
        public let read: UInt64
        public let written: UInt64
    }

    public static func sample(pid: Int32) -> IO? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }
        return IO(read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten)
    }

    public static func sample(pids: [Int32]) -> [Int32: IO] {
        var out: [Int32: IO] = [:]
        out.reserveCapacity(pids.count)
        for pid in pids { if let io = sample(pid: pid) { out[pid] = io } }
        return out
    }
}
