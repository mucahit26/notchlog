import Foundation

public enum ProcessRunnerError: Error, Equatable {
    case notAllowed(String)
    case timedOut
    case launchFailed(String)
}

/// Runs one of an explicit allowlist of system binaries and returns its stdout.
///
/// Two things here are load-bearing rather than stylistic:
///
/// 1. **Allowlist of absolute paths.** No PATH lookup, no shell, no interpolation of
///    anything into the argument vector. These are the only two executables NotchLog
///    will ever spawn, and CI asserts that no other path appears in the sources.
/// 2. **Drain the pipe before waiting.** `ps -Aeo ...` emits ~68 KB on a typical system,
///    which exceeds the 64 KB pipe buffer. Calling `waitUntilExit()` first deadlocks:
///    the child blocks writing, the parent blocks waiting. Read to EOF first, always.
public enum ProcessRunner {
    public static let ps = "/bin/ps"
    public static let nettop = "/usr/bin/nettop"
    static let allowed: Set<String> = [ps, nettop]

    public static func run(_ executable: String,
                           _ arguments: [String],
                           timeout: TimeInterval = 3.0) throws -> String {
        guard allowed.contains(executable) else {
            throw ProcessRunnerError.notAllowed(executable)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Watchdog: a wedged child must never stall the sampler.
        let timedOut = Atomic(false)
        let watchdog = DispatchWorkItem {
            if proc.isRunning { timedOut.set(true); proc.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()   // drain BEFORE wait
        proc.waitUntilExit()
        watchdog.cancel()

        if timedOut.get() { throw ProcessRunnerError.timedOut }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Minimal lock-protected box; avoids pulling in a concurrency dependency for one flag.
final class Atomic<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
