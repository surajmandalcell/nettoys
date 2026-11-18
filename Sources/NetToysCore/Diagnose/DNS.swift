import Darwin
import Foundation

public nonisolated enum NetToysDNSRecordType: UInt16, CaseIterable, Codable, Identifiable, Sendable {
    case a = 1, ns = 2, cname = 5, soa = 6, ptr = 12, mx = 15, txt = 16, aaaa = 28

    public var id: UInt16 { rawValue }
    public var name: String {
        switch self {
        case .a: "A"
        case .ns: "NS"
        case .cname: "CNAME"
        case .soa: "SOA"
        case .ptr: "PTR"
        case .mx: "MX"
        case .txt: "TXT"
        case .aaaa: "AAAA"
        }
    }
}

public nonisolated struct NetToysDNSRecord: Equatable, Sendable {
    public let name: String
    public let type: UInt16
    public let ttl: UInt32
    /// Presentation text: "10 mail.example.com" for MX, the joined strings for TXT, dig order for SOA.
    public let value: String

    public var typeName: String { NetToysDNSRecordType(rawValue: type)?.name ?? "TYPE\(type)" }
}

public nonisolated struct NetToysDNSAnswer: Equatable, Sendable {
    public let resolver: String
    public let milliseconds: Double
    /// NOERROR, NXDOMAIN, SERVFAIL, REFUSED, or RCODE n.
    public let status: String
    /// The reply did not fit in one UDP datagram; the record list may be short.
    public let truncated: Bool
    public let records: [NetToysDNSRecord]
    /// The authority section, such as the zone SOA of an NXDOMAIN reply.
    public let authority: [NetToysDNSRecord]
}

/// A tiny DNS client: one recursive query over UDP 53 with an EDNS0 size of 1232 bytes.
package nonisolated enum DNSMessage {
    package struct Reply: Equatable, Sendable {
        package let rcode: Int
        package let truncated: Bool
        package let answers: [NetToysDNSRecord]
        package let authority: [NetToysDNSRecord]
    }

    /// Nil when a label is empty or longer than 63 bytes, or the name is longer than 253.
    package static func query(name: String, type: UInt16, id: UInt16) -> [UInt8]? {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard trimmed.utf8.count <= 253 else { return nil }
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                guard (1...63).contains(label.utf8.count) else { return nil }
                packet.append(UInt8(label.utf8.count))
                packet.append(contentsOf: label.utf8)
            }
        }
        packet += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        // OPT pseudo-record: root name, type 41, UDP size 1232, no flags, no data.
        packet += [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0]
        return packet
    }

    /// Nil unless the message is a reply to `id` that parses to the end of its answer and authority sections.
    package static func parse(_ message: [UInt8], id: UInt16) -> Reply? {
        guard message.count >= 12, UInt16(message[0]) << 8 | UInt16(message[1]) == id, message[2] & 0x80 != 0
        else { return nil }
        let count = { (index: Int) in Int(message[index]) << 8 | Int(message[index + 1]) }
        var offset = 12
        for _ in 0..<count(4) {
            guard let (_, end) = name(in: message, at: offset), end + 4 <= message.count else { return nil }
            offset = end + 4
        }
        func records(_ total: Int) -> [NetToysDNSRecord]? {
            var result: [NetToysDNSRecord] = []
            for _ in 0..<total {
                guard let (owner, end) = name(in: message, at: offset), end + 10 <= message.count else { return nil }
                let type = UInt16(count(end))
                let ttl = message[(end + 4)..<(end + 8)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let start = end + 10
                let stop = start + count(end + 8)
                guard stop <= message.count else { return nil }
                offset = stop
                guard type != 41 else { continue }
                guard let value = rdata(type: type, in: message, range: start..<stop) else { return nil }
                result.append(NetToysDNSRecord(name: owner, type: type, ttl: ttl, value: value))
            }
            return result
        }
        guard let answers = records(count(6)), let authority = records(count(8)) else { return nil }
        return Reply(rcode: Int(message[3] & 0x0F), truncated: message[2] & 0x02 != 0,
                     answers: answers, authority: authority)
    }

    package static func status(_ rcode: Int) -> String {
        switch rcode {
        case 0: "NOERROR"
        case 1: "FORMERR"
        case 2: "SERVFAIL"
        case 3: "NXDOMAIN"
        case 4: "NOTIMP"
        case 5: "REFUSED"
        default: "RCODE \(rcode)"
        }
    }

    private static func rdata(type: UInt16, in message: [UInt8], range: Range<Int>) -> String? {
        let bytes = Array(message[range])
        let word = { (index: Int) in UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]) }
        switch type {
        case 1:
            return bytes.count == 4 ? bytes.map(String.init).joined(separator: ".") : nil
        case 28:
            guard bytes.count == 16 else { return nil }
            return ipv6Text(bytes)
        case 2, 5, 12:
            return name(in: message, at: range.lowerBound).map(\.0)
        case 15:
            guard bytes.count >= 3, let (exchange, _) = name(in: message, at: range.lowerBound + 2) else { return nil }
            return "\(Int(bytes[0]) << 8 | Int(bytes[1])) \(exchange)"
        case 16:
            var text = ""
            var index = 0
            while index < bytes.count {
                let length = Int(bytes[index])
                guard index + 1 + length <= bytes.count else { return nil }
                text += String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self)
                index += 1 + length
            }
            return text
        case 6:
            guard let (primary, afterPrimary) = name(in: message, at: range.lowerBound),
                  let (mailbox, afterMailbox) = name(in: message, at: afterPrimary),
                  afterMailbox + 20 == range.upperBound else { return nil }
            let numbers = (0..<5).map { String(word(afterMailbox - range.lowerBound + $0 * 4)) }
            return ([primary, mailbox] + numbers).joined(separator: " ")
        default:
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The name at `start` (following compression pointers) and the offset just after it in place.
    package static func name(in message: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        while offset < message.count {
            let length = Int(message[offset])
            if length == 0 {
                return (labels.isEmpty ? "." : labels.joined(separator: "."), end ?? offset + 1)
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < message.count, jumps < 16 else { return nil }
                if end == nil { end = offset + 2 }
                jumps += 1
                offset = (length & 0x3F) << 8 | Int(message[offset + 1])
                continue
            }
            guard length <= 63, offset + 1 + length <= message.count else { return nil }
            labels.append(String(decoding: message[(offset + 1)...(offset + length)], as: UTF8.self))
            offset += 1 + length
        }
        return nil
    }

    package static func ipv6Text(_ bytes: [UInt8]) -> String? {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "1.2.3.4" becomes "4.3.2.1.in-addr.arpa", an IPv6 address its nibble form under ip6.arpa; else nil.
    package static func reverseName(_ address: String) -> String? {
        if let v4 = IPv4Address(address) {
            return v4.description.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let nibbles = withUnsafeBytes(of: &v6) { bytes in
            bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 0x0F, radix: 16)] }
        }
        return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
    }
}

public nonisolated enum NetToysDNSLookup {
    /// The first IPv4 nameserver in /etc/resolv.conf, the one macOS asks first.
    // shortcut: an IPv6-only or scoped (VPN split) resolver is not used, add a dnssd path when one matters.
    public static var systemResolver: String? {
        (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)).flatMap(DNSProbe.resolver)?.description
    }

    /// One query. A PTR lookup accepts a plain IPv4 or IPv6 address. `resolver` nil means the system resolver.
    public static func lookup(
        _ name: String,
        type: NetToysDNSRecordType,
        resolver: String? = nil,
        timeoutMilliseconds: Int32 = 2_000
    ) async throws -> NetToysDNSAnswer {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryName = type == .ptr ? DNSMessage.reverseName(name) ?? name : name
        guard let server = (resolver ?? systemResolver).flatMap({ IPv4Address($0) }) else {
            throw NetToysDiagnoseError.invalidInput("The resolver must be an IPv4 address.")
        }
        let id = UInt16.random(in: 1...UInt16.max)
        guard !queryName.isEmpty, let query = DNSMessage.query(name: queryName, type: type.rawValue, id: id) else {
            throw NetToysDiagnoseError.invalidInput("\(name) is not a valid DNS name.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            guard let bytes = HostResolver.exchange(query, server: server, timeoutMilliseconds: timeoutMilliseconds)
            else { throw NetToysDiagnoseError.timedOut }
            let elapsed = DiagnoseHost.milliseconds(since: started)
            guard let reply = DNSMessage.parse(bytes, id: id) else {
                throw NetToysDiagnoseError.server("The resolver sent a reply that could not be read.")
            }
            return NetToysDNSAnswer(
                resolver: server.description,
                milliseconds: elapsed,
                status: DNSMessage.status(reply.rcode), truncated: reply.truncated,
                records: reply.answers, authority: reply.authority
            )
        }.value
    }
}

public nonisolated struct NetToysPublicResolver: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { address }
    public let name: String
    /// ISO country of the operator; the address itself is anycast and answers from a nearby site.
    public let country: String
    public let address: String
}

public nonisolated struct NetToysPropagationResult: Equatable, Sendable {
    public let resolver: NetToysPublicResolver
    public let answer: NetToysDNSAnswer?
    public let error: String?

    /// Sorted record values, so two resolvers agree when their lists are equal.
    public var values: [String] { (answer?.records ?? []).map(\.value).sorted() }
}

public nonisolated enum NetToysDNSPropagation {
    public static let resolvers: [NetToysPublicResolver] = [
        .init(name: "Cloudflare", country: "US", address: "1.1.1.1"),
        .init(name: "Google", country: "US", address: "8.8.8.8"),
        .init(name: "Quad9", country: "CH", address: "9.9.9.9"),
        .init(name: "OpenDNS", country: "US", address: "208.67.222.222"),
        .init(name: "Level3", country: "US", address: "4.2.2.1"),
        .init(name: "Hurricane Electric", country: "US", address: "74.82.42.42"),
        .init(name: "CleanBrowsing", country: "US", address: "185.228.168.9"),
        .init(name: "Control D", country: "CA", address: "76.76.2.0"),
        .init(name: "CIRA Canadian Shield", country: "CA", address: "149.112.121.10"),
        .init(name: "AdGuard", country: "CY", address: "94.140.14.14"),
        .init(name: "DNS.Watch", country: "DE", address: "84.200.69.80"),
        .init(name: "UncensoredDNS", country: "DK", address: "91.239.100.100"),
        .init(name: "Gcore", country: "LU", address: "95.85.95.85"),
        .init(name: "Yandex", country: "RU", address: "77.88.8.8"),
        .init(name: "AliDNS", country: "CN", address: "223.5.5.5"),
        .init(name: "Quad101", country: "TW", address: "101.101.101.101"),
    ]

    /// Asks every resolver at once; results arrive in the order they answer.
    public static func check(_ name: String, type: NetToysDNSRecordType) -> AsyncStream<NetToysPropagationResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: NetToysPropagationResult.self) { group in
                    for resolver in resolvers {
                        group.addTask {
                            do {
                                let answer = try await NetToysDNSLookup.lookup(name, type: type, resolver: resolver.address)
                                return NetToysPropagationResult(resolver: resolver, answer: answer, error: nil)
                            } catch {
                                return NetToysPropagationResult(resolver: resolver, answer: nil,
                                                                error: error.localizedDescription)
                            }
                        }
                    }
                    for await result in group { continuation.yield(result) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
