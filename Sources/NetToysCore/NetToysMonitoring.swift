import Darwin
import Foundation
import os
import UserNotifications

/// Durations as the product writes them: full hours, then min, then sec ("1 hour 52 min", "45 sec").
package nonisolated enum NetToysDuration {
    package static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60
        if hours > 0 {
            let unit = hours == 1 ? "hour" : "hours"
            return minutes > 0 ? "\(hours) \(unit) \(minutes) min" : "\(hours) \(unit)"
        }
        return minutes > 0 ? "\(minutes) min" : "\(total) sec"
    }
}

// MARK: - DNS check

/// The last DNS check of the background network check.
public nonisolated struct NetToysDNSCheck: Codable, Equatable, Sendable {
    public let resolver: String
    /// Nil when the resolver did not answer in time.
    public let milliseconds: Double?
    public let checkedAt: Date

    public init(resolver: String, milliseconds: Double?, checkedAt: Date) {
        self.resolver = resolver
        self.milliseconds = milliseconds
        self.checkedAt = checkedAt
    }
}

/// Asks the system's resolver for a fixed name over UDP, so the mDNSResponder cache never hides an outage.
nonisolated enum DNSProbe {
    static let name = "apple.com"

    static func resolver(resolvConf: String) -> IPv4Address? {
        resolvConf.split(whereSeparator: \.isNewline).lazy.compactMap { line -> IPv4Address? in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "nameserver" ? IPv4Address(String(words[1])) : nil
        }.first
    }

    static func check(timeoutMilliseconds: Int32 = 2_000) async -> NetToysDNSCheck? {
        await Task.detached(priority: .utility) {
            // shortcut: an IPv6-only resolver is not checked; add an AF_INET6 socket when one shows up.
            guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8),
                  let server = resolver(resolvConf: text) else { return nil }
            let id = UInt16.random(in: 1...UInt16.max)
            let started = ProcessInfo.processInfo.systemUptime
            let reply = HostResolver.exchange(HostResolver.query(name: name, type: 1, id: id), server: server,
                                              timeoutMilliseconds: timeoutMilliseconds)
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            // A reply to our id with no error or "no such name" counts; SERVFAIL means upstream DNS is down.
            let answered = reply.map { $0.count >= 12 && UInt16($0[0]) << 8 | UInt16($0[1]) == id
                && $0[2] & 0x80 != 0 && [0, 3].contains($0[3] & 0x0F) } ?? false
            return NetToysDNSCheck(resolver: server.description, milliseconds: answered ? elapsed : nil, checkedAt: Date())
        }.value
    }
}

// MARK: - Wake-on-LAN

public nonisolated enum NetToysWakeOnLAN {
    public enum WakeError: LocalizedError {
        case invalidMAC
        case held
        case sendFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidMAC: "This device has no usable MAC address."
            case .held: "Automatic actions are paused."
            case .sendFailed(let message): "The wake packet was not sent: \(message)"
            }
        }
    }

    /// Six 0xFF bytes, then the MAC address 16 times.
    static func magicPacket(mac: String) -> [UInt8]? {
        let hex = AnchorMatcher.normalizedMAC(mac)
        guard hex.count == 12 else { return nil }
        let octets = stride(from: 0, to: 12, by: 2).compactMap {
            UInt8(hex.dropFirst($0).prefix(2), radix: 16)
        }
        return Array(repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: octets, count: 16).joined())
    }

    /// Sends the packet to UDP port 9 on the subnet broadcast and 255.255.255.255, through the action log.
    /// Pause holds it; dry run logs it, sends nothing, and returns false.
    @discardableResult
    public static func wake(mac: String, deviceName: String, paths: NetToysRuntimePaths = .standard,
                            settings: NetToysConfiguration = NetToysConfigurationStore.load()) throws -> Bool {
        guard let packet = magicPacket(mac: mac) else { throw WakeError.invalidMAC }
        var gate = NetToysActionGate(log: NetToysActionLog(url: paths.actionLog))
        let summary = "Sent Wake-on-LAN to \(deviceName)"
        if NetToysActionGate.isHeld(settings) { throw WakeError.held }
        guard gate.allows(.wake, summary, settings: settings) else { return false }
        var targets = [IPv4Address(rawValue: .max)]
        if let network = LocalIPv4Network.active() {
            targets.insert(IPv4Address(rawValue: network.address.rawValue | ~network.netmask.rawValue), at: 0)
        }
        do {
            try send(packet, to: targets)
            _ = gate.finish(.wake, summary, error: nil, at: ProcessInfo.processInfo.systemUptime)
            return true
        } catch {
            _ = gate.finish(.wake, summary, error: error, at: ProcessInfo.processInfo.systemUptime)
            throw error
        }
    }

    private static func send(_ packet: [UInt8], to targets: [IPv4Address]) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw WakeError.sendFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sentOnce = false
        var lastError = ""
        for target in targets {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(9).bigEndian
            destination.sin_addr.s_addr = target.rawValue.bigEndian
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count { sentOnce = true } else { lastError = String(cString: strerror(errno)) }
        }
        guard sentOnce else { throw WakeError.sendFailed(lastError) }
    }
}

// MARK: - Latency history

public nonisolated struct NetToysLatencySample: Codable, Equatable, Sendable {
    public let date: Date
    /// Nil is a lost ping.
    public let milliseconds: Double?

    public init(date: Date, milliseconds: Double?) {
        self.date = date
        self.milliseconds = milliseconds
    }

    // Stored as [seconds, ms or null] to keep 24 hours of samples small.
    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        date = Date(timeIntervalSince1970: try values.decode(Double.self))
        milliseconds = try values.decodeNil() ? nil : try values.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(date.timeIntervalSince1970.rounded())
        if let milliseconds { try values.encode((milliseconds * 10).rounded() / 10) } else { try values.encodeNil() }
    }
}

/// Ping samples per device (keyed by IP address) and for the gateway, 24 hours at most, capped by size.
public nonisolated struct NetToysLatencyHistory: Codable, Equatable, Sendable {
    public static let gateway = "gateway"
    static let maximumAge: TimeInterval = 86_400
    static let maximumBytes = 512 * 1_024
    public var series: [String: [NetToysLatencySample]] = [:]

    public init(series: [String: [NetToysLatencySample]] = [:]) {
        self.series = series
    }

    /// Adds the samples, drops those older than 24 hours, then trims the longest series (oldest first) until it fits.
    mutating func append(_ samples: [String: [NetToysLatencySample]], now: Date) throws -> Data {
        for (key, values) in samples { series[key, default: []].append(contentsOf: values) }
        series = series.compactMapValues { values in
            let kept = values.filter { now.timeIntervalSince($0.date) < Self.maximumAge }
            return kept.isEmpty ? nil : kept
        }
        var data = try JSONEncoder().encode(self)
        while data.count > Self.maximumBytes {
            // The sample count that fits, with 5% room; then the largest per-series length whose total fits it.
            let counts = series.values.map(\.count)
            let budget = Int(Double(counts.reduce(0, +)) * Double(Self.maximumBytes) / Double(data.count) * 0.95)
            var low = 0, high = counts.max() ?? 0
            while low < high {
                let middle = (low + high + 1) / 2
                if counts.reduce(0, { $0 + min($1, middle) }) <= budget { low = middle } else { high = middle - 1 }
            }
            series = series.compactMapValues { low > 0 ? Array($0.suffix(low)) : nil }
            data = try JSONEncoder().encode(self)
        }
        return data
    }
}

public nonisolated enum NetToysLatencyStore {
    public static func load(from url: URL = NetToysRuntimePaths.standard.latency) -> NetToysLatencyHistory {
        (try? NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            try NetToysStoreFiles.decodeOrSetAside(NetToysLatencyHistory.self, from: url)
        }) ?? NetToysLatencyHistory()
    }

    static func append(_ samples: [String: [NetToysLatencySample]], to url: URL = NetToysRuntimePaths.standard.latency,
                       now: Date = Date()) throws {
        guard !samples.isEmpty else { return }
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            var history = try NetToysStoreFiles.decodeOrSetAside(NetToysLatencyHistory.self, from: url)
                ?? NetToysLatencyHistory()
            try history.append(samples, now: now).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Device watch: watched ports and alerts per device

public nonisolated struct NetToysDeviceWatch: Codable, Equatable, Sendable {
    public var ports: [UInt16] = []
    public var notifyOffline = false
    public var notifyOnline = false

    public init() {}

    var isEmpty: Bool { ports.isEmpty && !notifyOffline && !notifyOnline }
    public var hasAlerts: Bool { notifyOffline || notifyOnline || !ports.isEmpty }
}

public nonisolated enum NetToysDeviceWatchStore {
    /// Keyed by device ID (the IP address), like the scanner annotations.
    public static func load(from url: URL = NetToysRuntimePaths.standard.deviceWatch) -> [String: NetToysDeviceWatch] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: NetToysDeviceWatch].self, from: data)) ?? [:]
    }

    @discardableResult
    public static func update(_ id: String, at url: URL = NetToysRuntimePaths.standard.deviceWatch,
                              _ change: (inout NetToysDeviceWatch) -> Void) throws -> [String: NetToysDeviceWatch] {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            var all = try NetToysStoreFiles.decodeOrSetAside([String: NetToysDeviceWatch].self, from: url) ?? [:]
            var watch = all[id] ?? NetToysDeviceWatch()
            change(&watch)
            watch.ports = Array(Set(watch.ports)).sorted()
            all[id] = watch.isEmpty ? nil : watch
            try JSONEncoder().encode(all).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return all
        }
    }
}

// MARK: - New devices

nonisolated enum NetToysKnownDevices {
    static let limit = 4_096

    /// Results whose MAC address was never seen before. The first call only records what is there,
    /// so a fresh install does not announce every device on the network.
    static func newDevices(_ results: [NetToysScanResult], at url: URL) throws -> [NetToysScanResult] {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            let stored = try NetToysStoreFiles.decodeOrSetAside([String].self, from: url)
            var known = stored ?? []
            var seen = Set(known)
            var found: [NetToysScanResult] = []
            for result in results {
                guard let mac = result.macAddress.map(AnchorMatcher.normalizedMAC), mac.count == 12,
                      seen.insert(mac).inserted else { continue }
                known.append(mac)
                found.append(result)
            }
            guard !found.isEmpty || stored == nil else { return [] }
            try JSONEncoder().encode(Array(known.suffix(limit))).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return stored == nil ? [] : found
        }
    }

    /// One notification for every batch of new devices.
    static func alert(for found: [NetToysScanResult]) -> NetToysAlert? {
        guard let first = found.first else { return nil }
        let names = found.prefix(3).map(NetToysAlert.deviceName).joined(separator: ", ")
        return found.count == 1
            ? NetToysAlert(title: "New device on your network",
                           body: "\(NetToysAlert.deviceName(first)) joined at \(first.address).")
            : NetToysAlert(title: "\(found.count) new devices on your network",
                           body: names + (found.count > 3 ? ", and \(found.count - 3) more." : "."))
    }
}

// MARK: - Notifications

public nonisolated struct NetToysAlert: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    static func deviceName(_ result: NetToysScanResult) -> String {
        result.comment ?? result.hostname ?? result.netBIOSName ?? result.vendor.map { "A \($0) device" }
            ?? result.address.description
    }
}

public nonisolated enum NetToysNotifier {
    /// UNUserNotificationCenter needs an app bundle; test runners and bare binaries post nothing.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static func post(_ alert: NetToysAlert) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // Without permission macOS drops it; permission is asked only when the person turns an alert on.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }

    /// Asks once; later calls return the saved answer without a prompt.
    public static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// Up and down with a little patience: down needs two misses in a row, so one lost ping is not an outage.
nonisolated struct NetToysPresence: Sendable {
    enum Change: Equatable {
        case down
        case back(after: TimeInterval)
    }

    private var isUp: Bool?
    private var misses = 0
    private var downSince: Date?

    /// The first stable state is learned silently; only a change from a known state reports.
    mutating func observe(up: Bool, at date: Date, missesForDown: Int = 2) -> Change? {
        if up {
            misses = 0
            defer { isUp = true; downSince = nil }
            guard isUp == false, let downSince else { return nil }
            return .back(after: date.timeIntervalSince(downSince))
        }
        if misses == 0, isUp != false { downSince = date }
        misses += 1
        guard misses >= missesForDown, isUp != false else { return nil }
        defer { isUp = false }
        return isUp == true ? .down : nil
    }
}

// MARK: - Auto-join commands from the menu bar panel

/// Join Now and Stay, handed from the panel to the runtime through a small file (the runtime can live in
/// another app, such as MacPowerToys).
public nonisolated enum NetToysFailoverRequest: String, Codable, Sendable {
    case joinNow
    case stay

    private struct Stamped: Codable {
        let request: NetToysFailoverRequest
        let date: Date
    }

    public func send(to url: URL = NetToysRuntimePaths.standard.failoverRequest) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Stamped(request: self, date: Date())).write(to: url, options: .atomic)
    }

    /// Reads and removes the request. One older than a minute is stale and ignored.
    static func take(from url: URL, now: Date = Date()) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let stamped = try? JSONDecoder().decode(Stamped.self, from: data),
              abs(now.timeIntervalSince(stamped.date)) < 60 else { return nil }
        return stamped.request
    }
}

// MARK: - Scan memory

/// Caps a running scan's results by size: past the budget, silent addresses are dropped and
/// devices that answered are always kept.
nonisolated final class NetToysScanBudget: Sendable {
    static let maximumBytes = 16 * 1_048_576
    private let used = OSAllocatedUnfairLock(initialState: 0)
    private let limit: Int

    init(limit: Int = maximumBytes) {
        self.limit = limit
    }

    var isFull: Bool { used.withLock { $0 >= limit } }

    func admit(_ result: NetToysScanResult) -> Bool {
        let size = Self.estimatedBytes(result)
        return used.withLock { used in
            guard result.isReachable || used + size <= limit else { return false }
            used += size
            return true
        }
    }

    static func estimatedBytes(_ result: NetToysScanResult) -> Int {
        let text = [result.hostname, result.macAddress, result.vendor, result.httpServer, result.httpProxy,
                    result.netBIOSName, result.customText, result.comment]
        return MemoryLayout<NetToysScanResult>.stride + text.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            + 2 * (result.openPorts.count + (result.filteredPorts?.count ?? 0))
    }
}
