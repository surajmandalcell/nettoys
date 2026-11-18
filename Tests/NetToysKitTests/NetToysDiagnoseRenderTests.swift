import AppKit
@testable import NetToysCore
import SwiftUI
import XCTest
@testable import NetToysKit

/// Offscreen renders of the ten Diagnose tool pages with synthetic data. Runs only with NETTOYS_RENDER_DIR set.
@MainActor
final class NetToysDiagnoseRenderTests: XCTestCase {
    func testRenderDiagnosePages() throws {
        guard let out = ProcessInfo.processInfo.environment["NETTOYS_RENDER_DIR"] else { throw XCTSkip("render only") }
        func tool(_ id: String) -> NetToysTool { NetToysTool.tool(id)! }
        let day: TimeInterval = 86_400
        let now = Date()

        let dns = NetToysDNSAnswer(resolver: "192.168.50.1", milliseconds: 12.4, status: "NOERROR", truncated: false,
                                   records: [
                                       .init(name: "example.com", type: 1, ttl: 300, value: "93.184.215.14"),
                                       .init(name: "example.com", type: 1, ttl: 300, value: "93.184.215.15"),
                                   ],
                                   authority: [.init(name: "example.com", type: 2, ttl: 86_400, value: "ns1.example.com")])

        let resolvers = NetToysDNSPropagation.resolvers
        let propagation = resolvers.prefix(13).enumerated().map { index, resolver in
            NetToysPropagationResult(
                resolver: resolver,
                answer: index == 14 ? nil : .init(resolver: resolver.address, milliseconds: 8 + Double(index) * 6.3, status: "NOERROR",
                                                  truncated: false,
                                                  records: [.init(name: "example.com", type: 1, ttl: 300,
                                                                  value: index == 9 ? "93.184.215.99" : "93.184.215.14")],
                                                  authority: []),
                error: nil)
        }

        let whois = NetToysWhoisResult(query: "example.com", servers: ["whois.iana.org", "whois.verisign-grs.com"],
                                       raw: (1...40).map { "Line \($0): Domain Name: EXAMPLE.COM  Registrar WHOIS Server: whois.example-registrar.com" }
                                           .joined(separator: "\n"),
                                       registrar: "Example Registrar, Inc.", created: "1995-08-14T04:00:00Z",
                                       expires: "2027-08-13T04:00:00Z", nameServers: ["a.iana-servers.net", "b.iana-servers.net"])

        let ports: [NetToysPortResult] = NetToysPortScan.commonPorts.prefix(31).map { port in
            .init(port: port, state: [22, 80, 443, 445, 548].contains(port) ? .open : (port % 3 == 0 ? .closed : .filtered),
                  milliseconds: Double(port % 17) + 1.3)
        }

        let ssl = NetToysSSLResult(host: "example.com", port: 443, tlsVersion: "TLS 1.3", trusted: true, trustError: nil, chain: [
            .init(subject: "example.com", issuer: "Example Issuing CA R3", subjectAlternativeNames: ["example.com", "www.example.com", "files.example.com"],
                  notBefore: now - 30 * day, notAfter: now + 60 * day, daysToExpiry: 60, key: "EC 256",
                  signatureAlgorithm: "ECDSA SHA-384", sha256: "3F:A1:9C:22:7B:0E:44:D1:8A:6C:5E:91:0B:3D:7F:2A"),
            .init(subject: "Example Issuing CA R3", issuer: "Example Root CA", subjectAlternativeNames: [],
                  notBefore: now - 900 * day, notAfter: now + 700 * day, daysToExpiry: 700, key: "RSA 2048",
                  signatureAlgorithm: "RSA SHA-256", sha256: "9B:04:E2:61:AF:13:7C:58:0D:93:4E:B6:21:8F:C0:55"),
            .init(subject: "Example Root CA", issuer: "Example Root CA", subjectAlternativeNames: [],
                  notBefore: now - 4_000 * day, notAfter: now + 3_000 * day, daysToExpiry: 3_000, key: "RSA 4096",
                  signatureAlgorithm: "RSA SHA-256", sha256: "C7:7E:12:9A:40:B3:6D:E8:51:2F:0A:94:D6:3B:88:1C"),
        ], milliseconds: 84)

        let http = NetToysHTTPResult(url: "https://www.example.com/", status: 200,
                                     headers: [("Cache-Control", "max-age=604800"), ("Content-Type", "text/html; charset=UTF-8"),
                                               ("Date", "Wed, 18 Nov 2026 10:00:00 GMT"), ("Server", "ECAcc (nyd/D184)"),
                                               ("Strict-Transport-Security", "max-age=31536000")],
                                     redirects: [.init(url: "http://example.com/", status: 301, location: "https://www.example.com/")],
                                     timing: .init(dns: 14.2, connect: 22.8, tls: 31.5, firstByte: 64.0, total: 168),
                                     httpVersion: "h2", remoteAddress: "93.184.215.14", bodyBytes: 1_256)

        let geo = NetToysGeoIPResult(ip: "93.184.215.14", country: "United States", countryCode: "US", region: "Massachusetts",
                                     city: "Norwell", latitude: 42.1508, longitude: -70.8228, timeZone: "America/New_York",
                                     asn: 15133, organization: "Example Edge Network", isp: "Example Transit")

        let mtu = NetToysPathMTUResult(target: "93.184.215.14", mtu: 1492, probes: 12)

        let steps: [NetToysInternetStep] = [
            .init(kind: .router, passed: true, milliseconds: 2.1, detail: "192.168.50.1, 0% loss"),
            .init(kind: .dns, passed: true, milliseconds: 18.4, detail: "apple.com → 17.253.144.10"),
        ]

        let pages: [(String, AnyView)] = [
            ("dns-lookup", AnyView(NetToysDNSLookupView(tool: tool("dns-lookup"), input: .constant("example.com"),
                                                        run: .init(nil, showing: dns)))),
            ("dns-propagation", AnyView(NetToysDNSPropagationView(tool: tool("dns-propagation"), input: .constant("example.com"),
                                                                  run: .init([], showing: Array(propagation), running: true)))),
            ("whois", AnyView(NetToysWhoisView(tool: tool("whois"), input: .constant("example.com"),
                                               run: .init(nil, showing: whois), showRaw: true))),
            ("port-scan", AnyView(NetToysPortScanView(tool: tool("port-scan"), input: .constant("192.168.50.4"),
                                                      run: .init([], showing: ports, running: true)))),
            ("ssl-certificate", AnyView(NetToysSSLView(tool: tool("ssl-certificate"), input: .constant("example.com"),
                                                       run: .init(nil, showing: ssl)))),
            ("http-check", AnyView(NetToysHTTPCheckView(tool: tool("http-check"), input: .constant("example.com"),
                                                        run: .init(nil, showing: http)))),
            ("geoip", AnyView(NetToysGeoIPView(tool: tool("geoip"), input: .constant("93.184.215.14"), run: .init(nil, showing: geo)))),
            ("path-mtu", AnyView(NetToysPathMTUView(tool: tool("path-mtu"), input: .constant("example.com"), run: .init(nil, showing: mtu)))),
            ("internet-check", AnyView(NetToysInternetCheckView(tool: tool("internet-check"), input: .constant(""),
                                                                run: .init([], showing: steps, running: true)))),
            ("subnet-calculator", AnyView(NetToysSubnetView(tool: tool("subnet-calculator"), input: .constant("192.168.50.0/24")))),
            // States: idle, error, invalid input.
            ("state-idle", AnyView(NetToysWhoisView(tool: tool("whois"), input: .constant("")))),
            ("state-error", AnyView(NetToysSSLView(tool: tool("ssl-certificate"), input: .constant("expired.example.com"),
                                                   run: .init(nil, showing: nil, error: "expired.example.com did not answer.")))),
            ("state-invalid", AnyView(NetToysSubnetView(tool: tool("subnet-calculator"), input: .constant("192.168.50.0/40")))),
        ]
        let light: Set = ["dns-propagation", "ssl-certificate", "http-check"]
        for (name, page) in pages {
            for dark in [true, false] where dark || light.contains(name) {
                let view = page.frame(width: 1000, height: 640).background(Dense.content)
                try render(view, dark: dark, to: "\(out)/\(name)-\(dark ? "dark" : "light").png")
            }
        }
    }

    private func render(_ view: some View, dark: Bool, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
