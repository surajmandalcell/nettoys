import Foundation

public nonisolated enum NetToysDiagnoseError: LocalizedError, Equatable {
    case unknownHost(String)
    case icmpUnavailable
    case unreachable(String)
    case timedOut
    case invalidInput(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unknownHost(let host): "No IPv4 address found for \(host)."
        case .icmpUnavailable: "The ICMP socket could not open."
        case .unreachable(let host): "\(host) did not answer."
        case .timedOut: "The request timed out."
        case .invalidInput(let text): text
        case .server(let text): text
        }
    }
}

nonisolated enum DiagnoseHost {
    /// An IPv4 literal as is, else the first IPv4 address of the name.
    // shortcut: IPv4 only (ICMPv6 and AAAA-only hosts are not probed), add an AF_INET6 path when a tool needs it.
    static func resolve(_ host: String) async throws -> IPv4Address {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw NetToysDiagnoseError.invalidInput("Enter a host name or address.") }
        if let address = IPv4Address(host) { return address }
        guard let address = await HostResolver.forward(host).first else { throw NetToysDiagnoseError.unknownHost(host) }
        return address
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}
