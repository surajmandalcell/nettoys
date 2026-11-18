import Darwin
import Foundation

public nonisolated struct NetToysSubnet: Equatable, Sendable {
    public let version: Int
    public let address: String
    public let prefix: Int
    public let network: String
    /// IPv4 only; IPv6 has no broadcast address.
    public let broadcast: String?
    public let mask: String
    public let wildcard: String
    public let firstHost: String
    public let lastHost: String
    /// Decimal text, because a /0 IPv6 block holds 2^128 addresses.
    public let addressCount: String
    /// Usable hosts: IPv4 drops the network and broadcast addresses except in /31 and /32.
    public let hostCount: String

    /// "192.168.1.10/24", "2001:db8::1/48", or a bare address (taken as /32 or /128). Nil when invalid.
    public static func calculate(_ text: String) -> NetToysSubnet? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let address = String(parts[0])
        if let v4 = IPv4Address(address) {
            guard let prefix = parts.count == 2 ? Int(parts[1]) : 32, (0...32).contains(prefix) else { return nil }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            let network = v4.rawValue & mask
            let broadcast = network | ~mask
            let size = UInt64(1) << (32 - prefix)
            let edges = prefix >= 31 ? (network, broadcast) : (network + 1, broadcast - 1)
            let text = { (value: UInt32) in IPv4Address(rawValue: value).description }
            return NetToysSubnet(version: 4, address: v4.description, prefix: prefix, network: text(network),
                                 broadcast: text(broadcast), mask: text(mask), wildcard: text(~mask),
                                 firstHost: text(edges.0), lastHost: text(edges.1), addressCount: String(size),
                                 hostCount: String(prefix >= 31 ? size : size - 2))
        }
        var raw = in6_addr()
        guard inet_pton(AF_INET6, address, &raw) == 1,
              let prefix = parts.count == 2 ? Int(parts[1]) : 128, (0...128).contains(prefix) else { return nil }
        let value = withUnsafeBytes(of: &raw) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
        let mask: UInt128 = prefix == 0 ? 0 : ~UInt128(0) << (128 - prefix)
        let network = value & mask
        let last = network | ~mask
        let count = prefix == 0 ? "340282366920938463463374607431768211456" : String(UInt128(1) << (128 - prefix))
        return NetToysSubnet(version: 6, address: ipv6(value), prefix: prefix, network: ipv6(network), broadcast: nil,
                             mask: ipv6(mask), wildcard: ipv6(~mask), firstHost: ipv6(network), lastHost: ipv6(last),
                             addressCount: count, hostCount: count)
    }

    private static func ipv6(_ value: UInt128) -> String {
        DNSMessage.ipv6Text((0..<16).map { UInt8(truncatingIfNeeded: value >> UInt128(8 * (15 - $0))) }) ?? ""
    }
}
