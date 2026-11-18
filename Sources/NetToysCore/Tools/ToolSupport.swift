import Darwin
import Foundation
import Network
import os

// Shared parts of the Monitor, Local Network, and Wi-Fi tools.

extension NetToysRuntimePaths {
    public var uptimeChecks: URL { data.appendingPathComponent("uptime-checks.json") }
    public var uptimeResults: URL { data.appendingPathComponent("uptime-results.json") }
    public var speedHistory: URL { data.appendingPathComponent("speed-history.json") }
    public var speedSchedule: URL { data.appendingPathComponent("speed-schedule.json") }
}

nonisolated enum ToolFiles {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        try? NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            try NetToysStoreFiles.decodeOrSetAside(type, from: url)
        } ?? nil
    }

    /// Reads, changes, and writes `url` under the store lock; the file is owner-only.
    static func update<Value: Codable>(_ type: Value.Type, at url: URL, empty: Value,
                                       _ change: (inout Value) throws -> Data) throws -> Value {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            var value = try NetToysStoreFiles.decodeOrSetAside(type, from: url) ?? empty
            try change(&value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return value
        }
    }

    /// Drops the oldest items until the encoded array fits `maximumBytes`.
    static func trimmed<Item: Encodable>(_ items: [Item], maximumBytes: Int) throws -> (items: [Item], data: Data) {
        var items = items
        var data = try JSONEncoder().encode(items)
        while data.count > maximumBytes, !items.isEmpty {
            let keep = Int(Double(items.count) * Double(maximumBytes) / Double(data.count) * 0.95)
            items = Array(items.suffix(min(keep, items.count - 1)))
            data = try JSONEncoder().encode(items)
        }
        return (items, data)
    }
}

/// Small HTTPS reads for public IP and ISP names. Each call uses its own ephemeral session.
nonisolated enum ToolHTTP {
    static func text(_ url: String, timeout: TimeInterval = 5) async -> String? {
        guard let url = URL(string: url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65_536 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Public IP and network owner from Cloudflare's speed test meta endpoint (no key).
    static func ispName() async -> (ip: String?, isp: String?) {
        guard let text = await text("https://speed.cloudflare.com/meta"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return (nil, nil) }
        return (object["clientIp"] as? String, object["asOrganization"] as? String)
    }
}

/// One TCP connect with a deadline; the time to a ready connection is the latency.
nonisolated enum TCPConnectProbe {
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Result<Double, ToolProbeError> {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failure(ToolProbeError("Bad port")) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "nettoys.tcp-probe")
        let finished = OSAllocatedUnfairLock(initialState: false)
        let started = ProcessInfo.processInfo.systemUptime
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Double, ToolProbeError>, Never>) in
                let finish: @Sendable (Result<Double, ToolProbeError>) -> Void = { result in
                    guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                    connection.cancel()
                    continuation.resume(returning: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success((ProcessInfo.processInfo.systemUptime - started) * 1_000))
                    case .failed(let error), .waiting(let error): finish(.failure(ToolProbeError(error)))
                    case .cancelled: finish(.failure(ToolProbeError("Cancelled")))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(ToolProbeError("Timed out"))) }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

public nonisolated struct ToolProbeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String

    init(_ text: String) { description = text }

    init(_ error: NWError) {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: description = "Connection refused"
        case .posix(let code) where code == .ETIMEDOUT: description = "Timed out"
        case .posix(let code) where code == .ENETUNREACH || code == .EHOSTUNREACH: description = "No route to host"
        case .dns: description = "Name not found"
        default: description = error.localizedDescription
        }
    }
}

/// Interface addresses and counters from getifaddrs, grouped by interface name.
nonisolated struct InterfaceAddresses {
    var ipv4: [String] = []
    var ipv6: [String] = []
    var mac: String?
    var mtu = 0
    var bytesIn: UInt32 = 0
    var bytesOut: UInt32 = 0
    var isUp = false

    static func all(withMAC: Bool = true) -> [String: InterfaceAddresses] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [:] }
        defer { freeifaddrs(pointer) }
        var result: [String: InterfaceAddresses] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            guard let address = item.pointee.ifa_addr else { continue }
            var entry = result[name] ?? InterfaceAddresses()
            entry.isUp = Int32(item.pointee.ifa_flags) & IFF_UP != 0
            switch Int32(address.pointee.sa_family) {
            case AF_INET, AF_INET6:
                if let text = numericHost(address) {
                    if address.pointee.sa_family == UInt8(AF_INET) { entry.ipv4.append(text) } else { entry.ipv6.append(text) }
                }
            case AF_LINK:
                if withMAC { entry.mac = ARPTable.interfaceMAC(named: name) }
                if let data = item.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    entry.mtu = Int(data.ifi_mtu)
                    entry.bytesIn = data.ifi_ibytes
                    entry.bytesOut = data.ifi_obytes
                }
            default: break
            }
            result[name] = entry
        }
        return result
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
                          NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// A global unicast IPv6 address sits in 2000::/3.
    static func isGlobalIPv6(_ text: String) -> Bool {
        guard !text.contains("%"), let first = text.split(separator: ":").first, first.count == 4,
              let value = UInt16(first, radix: 16) else { return false }
        return value & 0xE000 == 0x2000
    }
}
