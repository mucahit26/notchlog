import Foundation

/// One open socket's cumulative byte counters.
public struct ConnRow: Equatable, Sendable {
    public let pid: Int32
    /// Stable-enough identity for a socket: "<pid>|<proto local<->remote>".
    public let key: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
}

public struct NettopFrame: Equatable, Sendable {
    /// Truncated process names keyed by pid, used only as a fallback when `ps`
    /// did not return that pid (a process that exited between the two calls).
    public let names: [Int32: String]
    public let connections: [ConnRow]
}

public enum NettopSource {
    /// `-n` is **mandatory**: without it nettop performs reverse-DNS on every remote
    /// address, which would make this monitoring tool generate its own outbound DNS
    /// traffic. In a tool whose entire premise is "no network", that is a real hole.
    /// CI asserts `-n` is present.
    public static let arguments = ["-x", "-n", "-l", "1",
                                   "-J", "bytes_in,bytes_out", "-t", "external"]

    public static func sample() throws -> NettopFrame {
        parse(try ProcessRunner.run(ProcessRunner.nettop, arguments))
    }

    public static func parse(_ text: String) -> NettopFrame {
        var names: [Int32: String] = [:]
        // Distinct sockets can share an identical descriptor — mDNSResponder routinely
        // holds several `udp4 *:*<->*:*` entries that the output cannot tell apart.
        // Summing them under one key is the honest treatment: the group's total is the
        // only quantity the data actually supports, and it keeps keys unique so the
        // delta tracker cannot silently drop or double-count a socket.
        var byKey: [String: (pid: Int32, inB: UInt64, outB: UInt64)] = [:]
        var order: [String] = []
        var currentPID: Int32?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Parse from the RIGHT: the last two tokens are the counters, and
            // everything before them is a name that may itself contain spaces
            // ("Google Chrome H.23649") or dots ("com.apple.Drive.751").
            guard let (head, inB, outB) = splitTrailingCounters(line) else { continue }
            let indented = line.first == " "

            if indented {
                guard let pid = currentPID else { continue }
                let key = "\(pid)|\(head)"
                if let existing = byKey[key] {
                    byKey[key] = (pid, existing.inB &+ inB, existing.outB &+ outB)
                } else {
                    byKey[key] = (pid, inB, outB)
                    order.append(key)
                }
            } else {
                guard let (name, pid) = splitNameAndPID(head) else { continue }
                currentPID = pid
                names[pid] = name
            }
        }
        let conns = order.compactMap { key -> ConnRow? in
            guard let v = byKey[key] else { return nil }
            return ConnRow(pid: v.pid, key: key, bytesIn: v.inB, bytesOut: v.outB)
        }
        return NettopFrame(names: names, connections: conns)
    }

    /// Returns (everything-before-the-counters, bytes_in, bytes_out).
    /// The header row has non-numeric trailing tokens and is rejected here.
    static func splitTrailingCounters(_ line: Substring) -> (String, UInt64, UInt64)? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 3,
              let outB = UInt64(tokens[tokens.count - 1]),
              let inB = UInt64(tokens[tokens.count - 2]) else { return nil }
        let head = tokens[0..<(tokens.count - 2)].joined(separator: " ")
        guard !head.isEmpty else { return nil }
        return (head, inB, outB)
    }

    /// nettop writes "<name>.<pid>", and names contain dots, so split on the LAST dot.
    static func splitNameAndPID(_ token: String) -> (String, Int32)? {
        guard let dot = token.lastIndex(of: "."),
              let pid = Int32(token[token.index(after: dot)...]) else { return nil }
        return (String(token[token.startIndex..<dot]), pid)
    }
}
