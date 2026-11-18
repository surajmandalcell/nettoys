import Darwin
import Foundation

// MARK: - ARP Table

public nonisolated struct NetToysARPEntry: Equatable, Identifiable, Sendable {
    public var id: String { "\(interfaceName)|\(address)" }
    public let address: String
    public let mac: String
    public let interfaceName: String
    public let vendor: String?
}

public nonisolated enum NetToysARPTable {
    /// Every neighbor macOS knows, from `/usr/sbin/arp -an`, sorted by interface and address.
    public static func load() async -> [NetToysARPEntry] {
        guard let result = try? await SSHProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/sbin/arp"),
                                                           arguments: ["-an"], maximumOutputBytes: 4_194_304,
                                                           timeout: 10) else { return [] }
        return entries(from: result.standardOutput)
    }

    static func entries(from output: String) -> [NetToysARPEntry] {
        let names = Set(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let words = line.split(separator: " ")
            return words.count >= 6 && words[4] == "on" ? String(words[5]) : nil
        })
        return names.flatMap { name in
            ARPTable.parse(output, interfaceName: name).map {
                NetToysARPEntry(address: $0.key, mac: $0.value, interfaceName: name,
                                vendor: MACVendorDatabase.bundled.vendor(for: $0.value))
            }
        }.sorted { ($0.interfaceName, IPv4Address($0.address) ?? IPv4Address(rawValue: 0))
            < ($1.interfaceName, IPv4Address($1.address) ?? IPv4Address(rawValue: 0)) }
    }
}

// MARK: - MAC Vendor

public nonisolated enum NetToysMACVendor {
    /// The IEEE owner of a MAC address or prefix ("3C:22:FB", "3c22fb123456"). "Private address" for a
    /// randomized address; nil when unknown or not hex.
    public static func lookup(_ text: String) -> String? {
        let hex = AnchorMatcher.normalizedMAC(text)
        guard (6...12).contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        return MACVendorDatabase.bundled.vendor(for: hex.padding(toLength: 12, withPad: "0", startingAt: 0))
    }
}

// MARK: - My Connection

public nonisolated struct NetToysInterfaceInfo: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case wifi, ethernet, vpn, bridge, other }
    public var id: String { name }
    public let name: String
    public let kind: Kind
    public let ipv4: [String]
    public let ipv6: [String]
    public let mac: String?
    public let mtu: Int
}

public nonisolated struct NetToysConnectionInfo: Equatable, Sendable {
    public let publicIPv4: String?
    public let publicIPv6: String?
    public let isp: String?
    public let interfaces: [NetToysInterfaceInfo]
    public let router: String?
    public let routerInterface: String?
    public let dnsServers: [String]
    /// Nil without Location permission or when not on Wi-Fi.
    public let wifiName: String?
}

public nonisolated enum NetToysMyConnection {
    /// Public addresses come from api4/api6.ipify.org and the ISP from ipinfo.io (no keys).
    public static func load() async -> NetToysConnectionInfo {
        async let ipv4 = ToolHTTP.text("https://api4.ipify.org")
        async let ipv6 = ToolHTTP.text("https://api6.ipify.org")
        async let owner = ToolHTTP.ispName()
        async let route = DefaultRoute.load()
        let list = interfaces()
        let router = await route
        let wifi = list.first { $0.kind == .wifi }.flatMap { NetworkSSID.current(interfaceName: $0.name) }
        return await NetToysConnectionInfo(publicIPv4: ipv4, publicIPv6: ipv6, isp: owner.isp, interfaces: list,
                                           router: router?.gateway, routerInterface: router?.interfaceName,
                                           dnsServers: dnsServers(), wifiName: wifi)
    }

    /// Interfaces that are up and have an address, without loopback and Apple's peer-to-peer links.
    public static func interfaces() -> [NetToysInterfaceInfo] {
        InterfaceAddresses.all().compactMap { name, entry -> NetToysInterfaceInfo? in
            guard entry.isUp, name != "lo0", !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !entry.ipv4.isEmpty || !entry.ipv6.isEmpty else { return nil }
            let kind: NetToysInterfaceInfo.Kind =
                if ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: name.hasPrefix) { .vpn }
                else if name.hasPrefix("bridge") { .bridge }
                else if name.hasPrefix("en") { NetworkSSID.isWiFi(interfaceName: name) ? .wifi : .ethernet }
                else { .other }
            return NetToysInterfaceInfo(name: name, kind: kind, ipv4: entry.ipv4, ipv6: entry.ipv6, mac: entry.mac,
                                        mtu: entry.mtu)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func dnsServers(resolvConf: String? = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) -> [String] {
        (resolvConf ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "nameserver" ? String(words[1]) : nil
        }
    }
}

// MARK: - IPv6 Check

public nonisolated struct NetToysIPv6Check: Equatable, Sendable {
    public static let testHost = "2606:4700:4700::1111"
    public static let testName = "apple.com"

    /// The first global (2000::/3) address on any interface.
    public let globalAddress: String?
    /// TCP connect time to Cloudflare's 2606:4700:4700::1111 port 443.
    public let reachMilliseconds: Double?
    public let reachFailure: String?
    /// AAAA answers for apple.com from the network's DNS server.
    public let aaaaAddresses: [String]

    public var isWorking: Bool { globalAddress != nil && reachMilliseconds != nil && !aaaaAddresses.isEmpty }
}

public nonisolated enum NetToysIPv6 {
    public static func check() async -> NetToysIPv6Check {
        let global = InterfaceAddresses.all(withMAC: false).values.flatMap(\.ipv6).first(where: InterfaceAddresses.isGlobalIPv6)
        async let reach = TCPConnectProbe.connect(host: NetToysIPv6Check.testHost, port: 443, timeout: 4)
        async let aaaa = Task.detached(priority: .utility) { lookupAAAA(NetToysIPv6Check.testName) }.value
        let result = await reach
        return await NetToysIPv6Check(globalAddress: global, reachMilliseconds: try? result.get(),
                                      reachFailure: result.failureDescription, aaaaAddresses: aaaa)
    }

    /// Asks the first resolver in /etc/resolv.conf directly over UDP: the system resolver skips AAAA
    /// queries on a network without IPv6, which would hide whether DNS can answer them.
    private static func lookupAAAA(_ name: String) -> [String] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8),
              let server = DNSProbe.resolver(resolvConf: text) else { return [] }
        let id = UInt16.random(in: 1...UInt16.max)
        guard let reply = HostResolver.exchange(HostResolver.query(name: name, type: 28, id: id), server: server,
                                                timeoutMilliseconds: 3_000) else { return [] }
        return aaaaAnswers(in: reply, id: id)
    }

    /// The IPv6 addresses in the answer section of a DNS reply to `id`.
    static func aaaaAnswers(in message: [UInt8], id: UInt16) -> [String] {
        guard message.count >= 12, UInt16(message[0]) << 8 | UInt16(message[1]) == id, message[3] & 0x0F == 0
        else { return [] }
        let questions = Int(message[4]) << 8 | Int(message[5]), answers = Int(message[6]) << 8 | Int(message[7])
        var offset = 12
        func skipName() -> Bool {
            while offset < message.count {
                let length = message[offset]
                if length & 0xC0 == 0xC0 { offset += 2; return offset <= message.count }
                offset += 1 + Int(length)
                if length == 0 { return offset <= message.count }
            }
            return false
        }
        for _ in 0..<questions { guard skipName() else { return [] }; offset += 4 }
        var result: [String] = []
        for _ in 0..<answers {
            guard skipName(), offset + 10 <= message.count else { break }
            let type = Int(message[offset]) << 8 | Int(message[offset + 1])
            let length = Int(message[offset + 8]) << 8 | Int(message[offset + 9])
            offset += 10
            guard offset + length <= message.count else { break }
            if type == 28, length == 16 {
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: message[offset..<(offset + 16)]) }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil { result.append(String(cString: buffer)) }
            }
            offset += length
        }
        return result
    }
}

extension Result where Failure == ToolProbeError {
    var failureDescription: String? { if case .failure(let error) = self { error.description } else { nil } }
}

// MARK: - Clock Check (SNTP)

public nonisolated struct NetToysClockCheck: Equatable, Sendable {
    public let server: String
    /// Positive when this Mac's clock is behind the server.
    public let offsetSeconds: Double
    /// Round trip to the server, without the server's own processing time.
    public let delaySeconds: Double
    public let stratum: Int
}

public nonisolated enum NetToysClock {
    public enum ClockError: LocalizedError, Equatable {
        case noAddress, noReply, badReply

        public var errorDescription: String? {
            switch self {
            case .noAddress: "The time server name did not resolve."
            case .noReply: "The time server did not answer in time."
            case .badReply: "The time server sent a reply that is not valid."
            }
        }
    }

    static let unixToNTP: Double = 2_208_988_800

    /// One SNTP query over UDP port 123.
    public static func check(server: String = "time.apple.com", timeoutMilliseconds: Int32 = 3_000) async throws -> NetToysClockCheck {
        try await Task.detached(priority: .utility) {
            guard let address = await HostResolver.forward(server).first else { throw ClockError.noAddress }
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { throw ClockError.noReply }
            defer { close(descriptor) }
            var wait = timeval(tv_sec: Int(timeoutMilliseconds / 1_000), tv_usec: (timeoutMilliseconds % 1_000) * 1_000)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(123).bigEndian
            destination.sin_addr.s_addr = address.rawValue.bigEndian
            let sentAt = Date().timeIntervalSince1970
            let packet = request(transmit: sentAt)
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { throw ClockError.noReply }
            var reply = [UInt8](repeating: 0, count: 256)
            let count = recv(descriptor, &reply, reply.count, 0)
            let receivedAt = Date().timeIntervalSince1970
            guard count >= 48 else { throw ClockError.noReply }
            guard let parsed = parse(Array(reply.prefix(count)), request: packet, sentAt: sentAt, receivedAt: receivedAt)
            else { throw ClockError.badReply }
            return NetToysClockCheck(server: server, offsetSeconds: parsed.offset, delaySeconds: parsed.delay,
                                     stratum: parsed.stratum)
        }.value
    }

    /// A 48-byte client request (version 4, mode 3) carrying the send time as its transmit stamp.
    static func request(transmit: TimeInterval) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x23
        packet.replaceSubrange(40..<48, with: stamp(transmit))
        return packet
    }

    /// Offset ((T2 - T1) + (T3 - T4)) / 2 and delay (T4 - T1) - (T3 - T2), per RFC 4330. The reply must be
    /// a server reply (mode 4) from a synchronized server that echoes our transmit stamp.
    static func parse(_ reply: [UInt8], request: [UInt8], sentAt t1: TimeInterval,
                      receivedAt t4: TimeInterval) -> (offset: Double, delay: Double, stratum: Int)? {
        guard reply.count >= 48, reply[0] & 0x07 == 4, reply[0] >> 6 != 3,
              (1...15).contains(reply[1]), Array(reply[24..<32]) == Array(request[40..<48]) else { return nil }
        let t2 = time(reply[32..<40]), t3 = time(reply[40..<48])
        return (((t2 - t1) + (t3 - t4)) / 2, (t4 - t1) - (t3 - t2), Int(reply[1]))
    }

    static func stamp(_ unix: TimeInterval) -> [UInt8] {
        let ntp = unix + unixToNTP
        let seconds = UInt32(truncatingIfNeeded: UInt64(ntp))
        let fraction = UInt32(truncatingIfNeeded: UInt64((ntp - ntp.rounded(.down)) * 4_294_967_296))
        return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: seconds >> $0) }
            + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: fraction >> $0) }
    }

    static func time(_ bytes: ArraySlice<UInt8>) -> TimeInterval {
        let value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Double(value >> 32) + Double(value & 0xFFFF_FFFF) / 4_294_967_296 - unixToNTP
    }
}
