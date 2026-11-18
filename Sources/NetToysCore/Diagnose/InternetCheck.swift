import Foundation

public nonisolated struct NetToysInternetStep: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case router = "Router"
        case dns = "DNS"
        case https = "HTTPS"
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let passed: Bool
    public let milliseconds: Double?
    /// What was asked and what came back, such as "192.168.0.1, 0% loss" or "Captive portal".
    public let detail: String
}

/// Router ping, DNS resolve, then HTTPS to captive.apple.com; each step streams as it finishes.
public nonisolated enum NetToysInternetCheck {
    public static func run() -> AsyncStream<NetToysInternetStep> {
        AsyncStream { continuation in
            let task = Task {
                for kind in NetToysInternetStep.Kind.allCases {
                    guard !Task.isCancelled else { break }
                    continuation.yield(await step(kind))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func step(_ kind: NetToysInternetStep.Kind) async -> NetToysInternetStep {
        switch kind {
        case .router:
            guard let route = await DefaultRoute.load(), let gateway = IPv4Address(route.gateway) else {
                return .init(kind: kind, passed: false, milliseconds: nil, detail: "No default route")
            }
            guard let ping = await PingProbe.check(address: gateway, count: 3, timeoutMilliseconds: 1_000) else {
                return .init(kind: kind, passed: false, milliseconds: nil, detail: "The ICMP socket could not open")
            }
            let loss = Int((ping.packetLossPercent ?? 100).rounded())
            return .init(kind: kind, passed: ping.averageMilliseconds != nil, milliseconds: ping.averageMilliseconds,
                         detail: "\(gateway), \(loss)% loss")
        case .dns:
            guard let check = await DNSProbe.check() else {
                return .init(kind: kind, passed: false, milliseconds: nil, detail: "No IPv4 resolver")
            }
            return .init(kind: kind, passed: check.milliseconds != nil, milliseconds: check.milliseconds,
                         detail: "\(DNSProbe.name) via \(check.resolver)" + (check.milliseconds == nil ? ", no answer" : ""))
        case .https:
            let started = ContinuousClock.now
            var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!,
                                     timeoutInterval: 5)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let elapsed = DiagnoseHost.milliseconds(since: started)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Apple's page says "Success"; a hotel or airport login page answers with anything else.
                let open = status == 200 && String(decoding: data, as: UTF8.self).contains("Success")
                return .init(kind: kind, passed: open, milliseconds: elapsed,
                             detail: open ? "captive.apple.com, HTTP 200" : "Captive portal (HTTP \(status))")
            } catch {
                return .init(kind: kind, passed: false, milliseconds: nil, detail: error.localizedDescription)
            }
        }
    }
}
