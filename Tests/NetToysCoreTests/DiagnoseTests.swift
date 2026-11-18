@testable import NetToysCore
import XCTest

final class DiagnoseTests: XCTestCase {
    private func labels(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    func testDNSQueryCarriesNameTypeAndEDNS() throws {
        let query = try XCTUnwrap(DNSMessage.query(name: "example.com.", type: 15, id: 0x1234))
        XCTAssertEqual(Array(query.prefix(12)), [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(Array(query[12..<29]), labels("example.com") + [0, 15, 0, 1])
        XCTAssertEqual(Array(query.suffix(11)), [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(DNSMessage.query(name: String(repeating: "a", count: 64) + ".com", type: 1, id: 1))
        XCTAssertNil(DNSMessage.query(name: "a..com", type: 1, id: 1))
    }

    func testDNSReplyParsesRecordsWithCompression() throws {
        let owner: [UInt8] = [0xC0, 0x0C]
        func record(_ type: UInt8, ttl: UInt8, _ data: [UInt8]) -> [UInt8] {
            owner + [0, type, 0, 1, 0, 0, 0, ttl, 0, UInt8(data.count)] + data
        }
        var reply: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 4, 0, 1, 0, 0] + labels("example.com") + [0, 1, 0, 1]
        reply += record(1, ttl: 200, [93, 184, 216, 34])
        reply += record(15, ttl: 60, [0, 10, 4] + Array("mail".utf8) + owner)
        reply += record(16, ttl: 60, [5] + Array("hello".utf8) + [5] + Array("world".utf8))
        reply += record(28, ttl: 60, [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1])
        let numbers: [UInt8] = [0, 0, 0, 1, 0, 0, 0x1C, 0x20, 0, 0, 0x0E, 0x10, 0, 0x12, 0x75, 0, 0, 0, 1, 0x2C]
        reply += record(6, ttl: 90, [3] + Array("ns1".utf8) + owner + [5] + Array("admin".utf8) + owner + numbers)

        let parsed = try XCTUnwrap(DNSMessage.parse(reply, id: 0x1234))
        XCTAssertEqual(parsed.rcode, 0)
        XCTAssertFalse(parsed.truncated)
        XCTAssertEqual(parsed.answers.map(\.value),
                       ["93.184.216.34", "10 mail.example.com", "helloworld", "2001:db8::1"])
        XCTAssertEqual(parsed.answers.map(\.typeName), ["A", "MX", "TXT", "AAAA"])
        XCTAssertEqual(parsed.answers.first?.name, "example.com")
        XCTAssertEqual(parsed.answers.first?.ttl, 200)
        XCTAssertEqual(parsed.authority.first?.value, "ns1.example.com admin.example.com 1 7200 3600 1209600 300")

        XCTAssertNil(DNSMessage.parse(reply, id: 0x1235), "another query's reply")
        XCTAssertNil(DNSMessage.parse(Array(reply.dropLast(3)), id: 0x1234), "cut short")
        var looping = Array(reply.prefix(12)) + [0xC0, 0x0C]
        looping[5] = 1
        XCTAssertNil(DNSMessage.parse(looping, id: 0x1234), "a pointer to itself")
    }

    func testReverseNames() {
        XCTAssertEqual(DNSMessage.reverseName("1.2.3.4"), "4.3.2.1.in-addr.arpa")
        XCTAssertEqual(DNSMessage.reverseName("2001:db8::1"),
                       "1." + String(repeating: "0.", count: 23) + "8.b.d.0.1.0.0.2.ip6.arpa")
        XCTAssertNil(DNSMessage.reverseName("example.com"))
    }

    func testWhoisReferralAndFields() {
        let iana = """
        % IANA WHOIS server
        % for more information on IANA, visit http://www.iana.org

        refer:        whois.verisign-grs.com

        domain:       COM
        whois:        whois.verisign-grs.com
        """
        XCTAssertEqual(NetToysWhois.referral(in: iana), "whois.verisign-grs.com")
        XCTAssertEqual(NetToysWhois.referral(in: "ReferralServer:  whois://whois.ripe.net:43"), "whois.ripe.net")
        XCTAssertNil(NetToysWhois.referral(in: "% refer: whois.example.net\ndomain: COM"))

        let registry = """
           Domain Name: EXAMPLE.COM
           Registrar WHOIS Server: whois.iana.org
           Registrar: RESERVED-Internet Assigned Numbers Authority
           Creation Date: 1995-08-14T04:00:00Z
           Registry Expiry Date: 2026-08-13T04:00:00Z
           Name Server: A.IANA-SERVERS.NET
           Name Server: B.IANA-SERVERS.NET
           Name Server: a.iana-servers.net
        """
        let fields = NetToysWhois.fields(in: registry)
        XCTAssertNil(NetToysWhois.referral(in: registry), "a registrar server line is not followed")
        XCTAssertEqual(fields.registrar, "RESERVED-Internet Assigned Numbers Authority")
        XCTAssertEqual(fields.created, "1995-08-14T04:00:00Z")
        XCTAssertEqual(fields.expires, "2026-08-13T04:00:00Z")
        XCTAssertEqual(fields.nameServers, ["a.iana-servers.net", "b.iana-servers.net"])

        let ripe = "inetnum: 193.0.0.0 - 193.0.7.255\norg-name: RIPE NCC\ncreated: 2003-03-17T12:15:57Z\n"
        XCTAssertEqual(NetToysWhois.fields(in: ripe).registrar, "RIPE NCC")
        XCTAssertEqual(NetToysWhois.fields(in: ripe).created, "2003-03-17T12:15:57Z")
    }

    func testIPv4SubnetMath() throws {
        let lan = try XCTUnwrap(NetToysSubnet.calculate("192.168.1.10/24"))
        XCTAssertEqual([lan.network, lan.broadcast, lan.mask, lan.wildcard, lan.firstHost, lan.lastHost],
                       ["192.168.1.0", "192.168.1.255", "255.255.255.0", "0.0.0.255", "192.168.1.1", "192.168.1.254"])
        XCTAssertEqual([lan.addressCount, lan.hostCount], ["256", "254"])
        let link = try XCTUnwrap(NetToysSubnet.calculate("10.0.0.7/31"))
        XCTAssertEqual([link.firstHost, link.lastHost, link.hostCount], ["10.0.0.6", "10.0.0.7", "2"])
        XCTAssertEqual(NetToysSubnet.calculate("10.0.0.7")?.hostCount, "1")
        XCTAssertEqual(NetToysSubnet.calculate("10.1.2.3/0")?.addressCount, "4294967296")
        XCTAssertEqual(NetToysSubnet.calculate("172.20.5.9/20")?.network, "172.20.0.0")
        XCTAssertNil(NetToysSubnet.calculate("1.2.3.4/33"))
        XCTAssertNil(NetToysSubnet.calculate("1.2.3/24"))
        XCTAssertNil(NetToysSubnet.calculate("1.2.3.4/"))
    }

    func testIPv6SubnetMath() throws {
        let block = try XCTUnwrap(NetToysSubnet.calculate("2001:db8::1/48"))
        XCTAssertEqual(block.network, "2001:db8::")
        XCTAssertEqual(block.lastHost, "2001:db8:0:ffff:ffff:ffff:ffff:ffff")
        XCTAssertEqual(block.mask, "ffff:ffff:ffff::")
        XCTAssertNil(block.broadcast)
        XCTAssertEqual(block.addressCount, "1208925819614629174706176")
        XCTAssertEqual(NetToysSubnet.calculate("::/0")?.addressCount, "340282366920938463463374607431768211456")
        XCTAssertEqual(NetToysSubnet.calculate("fe80::1")?.addressCount, "1")
        XCTAssertNil(NetToysSubnet.calculate("2001:db8::/129"))
    }

    func testLatencyStatsForMTR() throws {
        var stats = NetToysLatencyStats()
        XCTAssertNil(stats.average)
        for sample in [10, nil, 20, 15] as [Double?] { stats.record(sample) }
        XCTAssertEqual(stats.sent, 4)
        XCTAssertEqual(stats.received, 3)
        XCTAssertEqual(stats.lossPercent, 25)
        XCTAssertEqual(stats.last, 15)
        XCTAssertEqual(stats.best, 10)
        XCTAssertEqual(stats.worst, 20)
        XCTAssertEqual(try XCTUnwrap(stats.average), 15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(stats.jitter), 7.5, accuracy: 1e-9)
    }

    /// macOS loops 127.0.0.2 back but does not own it, so a connect there waits for the timeout without
    /// leaving the Mac. 200 such probes at 300 ms finish in about one timeout only when they all wait at once,
    /// not one per cooperative thread.
    func testPortProbesWaitInParallelWithoutBlockingThreads() async {
        let started = ContinuousClock.now
        let states = await withTaskGroup(of: TCPPortState.self) { group in
            for index in 0..<200 {
                group.addTask {
                    await TCPPortProbe.check(host: "127.0.0.2", port: UInt16(20_000 + index), timeoutMilliseconds: 300).state
                }
            }
            return await group.reduce(into: [TCPPortState]()) { $0.append($1) }
        }
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThan(states.filter { $0 == .unreachable }.count, 150, "most probes waited for the timeout")
        XCTAssertLessThan(elapsed, .milliseconds(1_500), "200 waits overlapped")
    }

    func testTimeExceededMatchesTheQuotedRequest() throws {
        let router: [UInt8] = [10, 0, 0, 1]
        let target: UInt32 = 0x0101_0101
        let outer: [UInt8] = [0x45, 0, 0, 56, 0, 0, 0, 0, 64, 1, 0, 0] + router + [192, 168, 0, 2]
        let inner: [UInt8] = [0x45, 0, 0, 36, 0, 0, 0, 0, 1, 1, 0, 0, 192, 168, 0, 2, 1, 1, 1, 1]
        var icmp: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0] + inner
            + ICMPEcho.encodeRequest(identifier: 0x1234, sequence: 7).prefix(8)
        let sum = ICMPEcho.checksum(icmp)
        icmp[2] = UInt8(sum >> 8)
        icmp[3] = UInt8(sum & 0xFF)
        // Darwin hands the quoted ip_len over in host order, which breaks the checksum.
        icmp.swapAt(10, 11)

        let packet = try XCTUnwrap(ICMPEcho.decode(outer + icmp))
        XCTAssertEqual(packet.type, 11)
        XCTAssertEqual(packet.source, 0x0A00_0001)
        XCTAssertEqual(packet.quotedDestination, target)
        XCTAssertTrue(ICMPEcho.matches(packet, identifier: 0x1234, sequence: 7, address: target))
        XCTAssertFalse(ICMPEcho.matches(packet, identifier: 0x1234, sequence: 7, address: 0x0808_0808))
        XCTAssertFalse(ICMPEcho.matches(packet, identifier: 0x1234, sequence: 8, address: target))
    }
}
