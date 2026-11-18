import Foundation

public nonisolated struct NetToysPathMTUResult: Equatable, Sendable {
    public let target: String
    /// The biggest IPv4 packet, headers included, that reached the target and came back unfragmented.
    public let mtu: Int
    public let probes: Int
}

/// Binary search with don't-fragment echoes over the shared ICMP socket. A size fails when the send fails
/// (bigger than the local link), a router answers "fragmentation needed", or two tries get no reply.
public nonisolated enum NetToysPathMTU {
    static let headerBytes = 28 // IPv4 20 + ICMP 8

    public static func discover(host: String, maximum: Int = 1_500, timeoutMilliseconds: Int = 1_000) async throws
        -> NetToysPathMTUResult {
        guard ICMPEcho.isAvailable else { throw NetToysDiagnoseError.icmpUnavailable }
        let target = try await DiagnoseHost.resolve(host)
        var probes = 0
        func passes(_ size: Int) async -> Bool {
            for _ in 0..<2 {
                probes += 1
                let reply = await ICMPEcho.probe(to: target, timeoutMilliseconds: timeoutMilliseconds,
                                                 payloadSize: size - headerBytes, dontFragment: true)
                if reply?.type == 0 { return true }
                if reply?.type == 3 { return false }
            }
            return false
        }
        var low = 68 // the IPv4 minimum every link carries
        guard await passes(low) else { throw NetToysDiagnoseError.unreachable(target.description) }
        var high = max(maximum, low)
        if await passes(high) { return NetToysPathMTUResult(target: target.description, mtu: high, probes: probes) }
        // Invariant: `low` passes, `high` fails.
        while high - low > 1, !Task.isCancelled {
            let middle = (low + high) / 2
            if await passes(middle) { low = middle } else { high = middle }
        }
        try Task.checkCancellation()
        return NetToysPathMTUResult(target: target.description, mtu: low, probes: probes)
    }
}
