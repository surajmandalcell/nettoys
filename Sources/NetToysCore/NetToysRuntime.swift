import Darwin
import Foundation
@preconcurrency import CoreWLAN

public nonisolated enum SSHKeyAccessError: LocalizedError {
    case unsafeAlias
    case noPublicKey
    case invalidPublicKey
    case passwordRejected
    case connectionFailed(String)
    case installFailed(String)
    case verificationFailed
    case timeout
    case outputLimit
    case processLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeAlias: "The SSH alias is not safe to pass to OpenSSH."
        case .noPublicKey: "No public key was found for this SSH host."
        case .invalidPublicKey: "The selected SSH public key is invalid."
        case .passwordRejected: "Windows did not accept the SSH password."
        case .connectionFailed(let message): message
        case .installFailed(let message): message
        case .verificationFailed:
            "The key was installed, but key-only login still failed. Check sshd_config and authorized_keys permissions."
        case .timeout: "SSH key setup timed out."
        case .outputLimit: "Process output exceeded its limit."
        case .processLaunchFailed(let message): "SSH could not start: \(message)"
        }
    }
}

public nonisolated struct SSHProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String
}

public nonisolated enum SSHProcessRunner {
    public static func baseEnvironment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
        if let socket = current["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = socket }
        return environment
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = baseEnvironment(),
        standardInput: Data? = nil,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024,
        timeout: TimeInterval
    ) async throws -> SSHProcessResult {
        guard maximumOutputBytes > 0 else { throw SSHKeyAccessError.outputLimit }
        let worker = Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let input = standardInput == nil ? nil : Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
            do {
                try process.run()
            } catch {
                throw SSHKeyAccessError.processLaunchFailed(error.localizedDescription)
            }
            let outputReader = Task.detached {
                read(output.fileHandleForReading, maximumBytes: maximumOutputBytes, process: process)
            }
            let errorReader = Task.detached {
                read(error.fileHandleForReading, maximumBytes: maximumOutputBytes, process: process)
            }
            if let standardInput, let input {
                input.fileHandleForWriting.write(standardInput)
                try? input.fileHandleForWriting.close()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, !Task.isCancelled, Date() < deadline {
                usleep(20_000)
            }
            let wasCancelled = Task.isCancelled
            let timedOut = process.isRunning && Date() >= deadline
            if process.isRunning {
                process.terminate()
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killDeadline {
                    usleep(20_000)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let outputResult = await outputReader.value
            let errorResult = await errorReader.value
            if wasCancelled { throw CancellationError() }
            if timedOut { throw SSHKeyAccessError.timeout }
            if outputResult.exceeded || errorResult.exceeded { throw SSHKeyAccessError.outputLimit }
            return SSHProcessResult(
                status: process.terminationStatus,
                standardOutput: String(decoding: outputResult.data, as: UTF8.self),
                standardError: String(decoding: errorResult.data, as: UTF8.self)
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func read(_ handle: FileHandle, maximumBytes: Int, process: Process) -> (data: Data, exceeded: Bool) {
        var data = Data()
        var exceeded = false
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8_192) }
            if chunk.isEmpty { break }
            let remaining = max(maximumBytes - data.count, 0)
            data.append(chunk.prefix(remaining))
            exceeded = exceeded || chunk.count > remaining
            if exceeded, process.isRunning { process.terminate() }
        }
        return (data, exceeded)
    }
}

public nonisolated struct LocalIPv4Network: Equatable, Sendable {
    enum NetworkError: LocalizedError {
        case tooManyTargets(Int)

        var errorDescription: String? {
            switch self {
            case .tooManyTargets(let limit): "The local subnet contains more than \(limit) usable addresses."
            }
        }
    }

    public let interfaceName: String
    public let address: IPv4Address
    public let netmask: IPv4Address
    public let prefixLength: Int

    public init?(interfaceName: String, address: String, netmask: String) {
        guard let address = IPv4Address(address), let netmask = IPv4Address(netmask) else { return nil }
        let inverted = ~netmask.rawValue
        guard inverted &+ 1 != 0, (inverted & (inverted &+ 1)) == 0 else { return nil }
        self.interfaceName = interfaceName
        self.address = address
        self.netmask = netmask
        prefixLength = netmask.rawValue.nonzeroBitCount
    }

    public var cidr: String {
        "\(IPv4Address(rawValue: address.rawValue & netmask.rawValue))/\(prefixLength)"
    }

    package func contains(_ candidate: String) -> Bool {
        guard let candidate = IPv4Address(candidate) else { return false }
        return candidate.rawValue & netmask.rawValue == address.rawValue & netmask.rawValue
    }

    func targets(limit: Int) throws -> [IPv4Address] {
        let hostBits = 32 - prefixLength
        let total = UInt64(1) << UInt64(hostBits)
        let excluded = hostBits >= 2 ? 2 : 0
        let usable = total - UInt64(excluded)
        guard usable <= UInt64(limit) else { throw NetworkError.tooManyTargets(limit) }
        let network = address.rawValue & netmask.rawValue
        let first = network &+ UInt32(excluded == 2 ? 1 : 0)
        let last = network &+ UInt32(total - 1 - UInt64(excluded == 2 ? 1 : 0))
        return (first...last).map(IPv4Address.init(rawValue:))
    }

    public static func active(preferredInterfaceName: String? = nil) -> LocalIPv4Network? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [LocalIPv4Network] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  let address = numericAddress(item.pointee.ifa_addr),
                  let mask = numericAddress(item.pointee.ifa_netmask)
            else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun"),
                  let network = LocalIPv4Network(interfaceName: name, address: address, netmask: mask)
            else { continue }
            candidates.append(network)
        }
        return candidates.sorted {
            preference($0.interfaceName, preferred: preferredInterfaceName)
                < preference($1.interfaceName, preferred: preferredInterfaceName)
        }.first
    }

    private static func preference(_ name: String, preferred: String?) -> Int {
        if name == preferred { return 0 }
        if name == "en0" { return 1 }
        if name.hasPrefix("en") { return 2 }
        if name.hasPrefix("bridge") { return 3 }
        return 4
    }

    private static func numericAddress(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let pointer else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
            var raw = address.pointee.sin_addr
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
    }
}

package nonisolated struct TailscalePeer: Equatable, Identifiable, Sendable {
    package var id: String { nodeID }
    package let nodeID: String
    package let hostName: String
    package let dnsName: String
    package let ipAddress: String
    package let isOnline: Bool
}

public nonisolated struct TailscaleFallbackConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public let nodeID: String
    public let hostName: String
    public let ipAddress: String
}

public nonisolated enum TailscalePeerCatalog {
    enum CatalogError: LocalizedError, Equatable {
        case unavailable
        case notRunning
        case invalidStatus
        case peerNotFound

        var errorDescription: String? {
            switch self {
            case .unavailable: "Tailscale is not installed or its status is unavailable."
            case .notRunning: "Connect Tailscale before enabling this fallback."
            case .invalidStatus: "Tailscale returned an unreadable device list."
            case .peerNotFound:
                "The saved Tailscale device is unavailable. Turn Tailscale off and on to choose it again."
            }
        }
    }

    private struct Status: Decodable {
        let backendState: String
        let peer: [String: Peer]?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case peer = "Peer"
        }
    }

    private struct Peer: Decodable {
        let nodeID: String?
        let hostName: String?
        let dnsName: String?
        let tailscaleIPs: [String]?
        let isOnline: Bool?

        enum CodingKeys: String, CodingKey {
            case nodeID = "ID"
            case hostName = "HostName"
            case dnsName = "DNSName"
            case tailscaleIPs = "TailscaleIPs"
            case isOnline = "Online"
        }
    }

    package static func load() async throws -> [TailscalePeer] {
        let paths = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CatalogError.unavailable
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        let data = try await runStatusCommand(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["status", "--json"],
            environment: environment
        )
        return try parse(data)
    }

    public static func runStatusCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        let operation = Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            // Poll instead of blocking for EOF: a process launched elsewhere at the same moment
            // can inherit the pipe's write end and keep it open after this child has exited.
            let reader = Task.detached(priority: .utility) {
                var data = Data()
                var exceeded = false
                let descriptor = output.fileHandleForReading.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 8_192)
                var quietAfterExit = 0
                let readerDeadline = Date().addingTimeInterval(timeout + 4)
                while true {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&event, 1, 100) > 0 else {
                        if Date() > readerDeadline { break }
                        if process.isRunning || process.processIdentifier == 0 { continue }
                        quietAfterExit += 1
                        if quietAfterExit >= 3 { break }
                        continue
                    }
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    let remaining = max(maximumOutputBytes - data.count, 0)
                    data.append(contentsOf: buffer.prefix(min(count, remaining)))
                    exceeded = exceeded || count > remaining
                    if exceeded, process.isRunning { process.terminate() }
                }
                return (data: data, exceeded: exceeded)
            }

            do {
                try process.run()
            } catch {
                try? output.fileHandleForWriting.close()
                _ = await reader.value
                throw CatalogError.unavailable
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let timedOut = process.isRunning && Date() >= deadline
            if process.isRunning {
                process.terminate()
                let killDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < killDeadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            // waitUntilExit() can block forever when Foundation misses the child's exit.
            let reapDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < reapDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let result = await reader.value
            if Task.isCancelled { throw CancellationError() }
            guard !process.isRunning, !timedOut, !result.exceeded, process.terminationStatus == 0 else {
                throw CatalogError.unavailable
            }
            return result.data
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    static func parse(_ data: Data) throws -> [TailscalePeer] {
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw CatalogError.invalidStatus
        }
        guard status.backendState == "Running" else { throw CatalogError.notRunning }
        let peers = status.peer.map { Array($0.values) } ?? []
        return peers.compactMap { peer in
            guard let nodeID = peer.nodeID,
                  let ipAddress = peer.tailscaleIPs?.first(where: isTailscaleAddress),
                  let hostName = [peer.hostName, peer.dnsName]
                    .compactMap({ $0 })
                    .map(AnchorMatcher.hostnameLabel)
                    .first(where: { !$0.isEmpty })
            else {
                return nil
            }
            return TailscalePeer(
                nodeID: nodeID,
                hostName: hostName,
                dnsName: peer.dnsName ?? "",
                ipAddress: ipAddress,
                isOnline: peer.isOnline ?? false
            )
        }.sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
    }

    package static func isTailscaleAddress(_ value: String) -> Bool {
        guard let address = IPv4Address(value) else { return false }
        return address.rawValue & 0xFFC0_0000 == 0x6440_0000
    }

    package static func exactMatch(labels: [String], peers: [TailscalePeer]) -> TailscalePeer? {
        let expected = Set(labels.map(AnchorMatcher.hostnameLabel).filter { !$0.isEmpty })
        let matches = peers.filter {
            expected.contains(AnchorMatcher.hostnameLabel($0.hostName))
                || expected.contains(AnchorMatcher.hostnameLabel($0.dnsName))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    package static func endpoint(
        nodeID: String,
        peers: [TailscalePeer],
        isEnabled: Bool = true
    ) -> TailscaleFallbackConfiguration? {
        guard let peer = peers.first(where: { $0.nodeID == nodeID }) else { return nil }
        return TailscaleFallbackConfiguration(
            isEnabled: isEnabled,
            nodeID: peer.nodeID,
            hostName: peer.hostName,
            ipAddress: peer.ipAddress
        )
    }
}

public nonisolated struct SSHAnchorConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var hostAlias: String
    public var hostName: String
    public var port: UInt16
    public var identity: AnchorIdentity
    public var localHostName: String?
    public var tailscaleFallback: TailscaleFallbackConfiguration?
    public var keyAccessVerifiedAt: Date?

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        hostAlias: String,
        hostName: String,
        port: UInt16,
        identity: AnchorIdentity,
        localHostName: String? = nil,
        tailscaleFallback: TailscaleFallbackConfiguration? = nil,
        keyAccessVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.hostAlias = hostAlias
        self.hostName = hostName
        self.port = port
        self.identity = identity
        self.localHostName = localHostName
        self.tailscaleFallback = tailscaleFallback
        self.keyAccessVerifiedAt = keyAccessVerifiedAt
    }

    package var route: SSHAnchorRoute {
        tailscaleFallback?.ipAddress == hostName ? .tailscale : .local
    }

    package var knownHostsAlias: String {
        "macpowertoys-\(id.uuidString.lowercased())"
    }
}

package nonisolated enum SSHAnchorRoute: Equatable, Sendable {
    case local
    case tailscale
}

nonisolated enum SSHAnchorRouteAction: Equatable, Sendable {
    case none
    case useTailscale
    case useLocal
}

nonisolated struct SSHAnchorRouteMonitor: Sendable {
    static let fallbackFailureCount = 2
    static let restoreSuccessCount = 3
    static let minimumTailscaleDwell: TimeInterval = 30

    private var localFailures = 0
    private var localSuccesses = 0
    private var tailscaleSince: Date?

    mutating func observe(
        route: SSHAnchorRoute,
        localIsOpen: Bool,
        at date: Date
    ) -> SSHAnchorRouteAction {
        switch route {
        case .local:
            localSuccesses = 0
            tailscaleSince = nil
            if localIsOpen {
                localFailures = 0
                return .none
            }
            localFailures = min(localFailures + 1, Self.fallbackFailureCount)
            return localFailures >= Self.fallbackFailureCount ? .useTailscale : .none
        case .tailscale:
            localFailures = 0
            if tailscaleSince == nil { tailscaleSince = date }
            if localIsOpen {
                localSuccesses = min(localSuccesses + 1, Self.restoreSuccessCount)
            } else {
                localSuccesses = 0
            }
            guard localSuccesses >= Self.restoreSuccessCount,
                  date.timeIntervalSince(tailscaleSince ?? date) >= Self.minimumTailscaleDwell
            else { return .none }
            return .useLocal
        }
    }

    mutating func didSwitch(to route: SSHAnchorRoute, at date: Date) {
        localFailures = 0
        localSuccesses = 0
        tailscaleSince = route == .tailscale ? date : nil
    }
}

nonisolated enum SSHAnchorRecovery {
    static func resolve(
        anchor: SSHAnchorConfiguration,
        scanResults: [NetToysScanResult]
    ) -> SSHAnchorConfiguration? {
        let candidates = scanResults
            .filter { $0.openPorts.contains(anchor.port) }
            .map {
                AnchorCandidate(
                    ip: $0.address.description,
                    macAddress: $0.macAddress,
                    hostname: $0.hostname
                )
            }
        guard let match = AnchorMatcher.match(candidates: candidates, identity: anchor.identity) else { return nil }
        var recovered = anchor
        recovered.hostName = match.ip
        if case .randomizedMAC(let hostname, var learnedMACs) = recovered.identity,
           let mac = match.macAddress {
            learnedMACs.insert(AnchorMatcher.normalizedMAC(mac))
            recovered.identity = .randomizedMAC(hostname: hostname, learnedMACs: learnedMACs)
        }
        return recovered
    }
}

public nonisolated struct NetToysConfiguration: Codable, Equatable, Sendable {
    enum ConfigurationError: LocalizedError {
        case anchorNotFound

        var errorDescription: String? { "The SSH Anchor no longer exists." }
    }

    public var probeInterval: TimeInterval
    public var sshAnchorEnabled: Bool
    public var anchors: [SSHAnchorConfiguration]
    public var recordsNetworkHistory: Bool
    public var wifiPriority: WiFiPriorityConfiguration
    public var backgroundRequests: Set<NetToysHostID>

    public init(
        probeInterval: TimeInterval = 2.5,
        sshAnchorEnabled: Bool = true,
        anchors: [SSHAnchorConfiguration] = [],
        recordsNetworkHistory: Bool = true,
        wifiPriority: WiFiPriorityConfiguration = WiFiPriorityConfiguration(),
        backgroundRequests: Set<NetToysHostID> = []
    ) {
        self.probeInterval = min(max(probeInterval, 2), 3)
        self.sshAnchorEnabled = sshAnchorEnabled
        self.anchors = Array(anchors.prefix(16))
        self.recordsNetworkHistory = recordsNetworkHistory
        self.wifiPriority = wifiPriority
        self.backgroundRequests = backgroundRequests
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            probeInterval: try values.decode(TimeInterval.self, forKey: .probeInterval),
            sshAnchorEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .sshAnchorEnabled
            ) ?? true,
            anchors: try values.decode([SSHAnchorConfiguration].self, forKey: .anchors),
            recordsNetworkHistory: try values.decode(Bool.self, forKey: .recordsNetworkHistory),
            wifiPriority: try values.decodeIfPresent(
                WiFiPriorityConfiguration.self,
                forKey: .wifiPriority
            ) ?? WiFiPriorityConfiguration(),
            backgroundRequests: try values.decodeIfPresent(Set<NetToysHostID>.self, forKey: .backgroundRequests) ?? []
        )
    }

    package var monitoredAnchors: [SSHAnchorConfiguration] {
        sshAnchorEnabled ? anchors.filter(\.isEnabled) : []
    }

    func replacingAnchor(_ anchor: SSHAnchorConfiguration) throws -> Self {
        guard let index = anchors.firstIndex(where: { $0.id == anchor.id }) else {
            throw ConfigurationError.anchorNotFound
        }
        var copy = self
        copy.anchors[index] = anchor
        return copy
    }

    mutating func applyEdits(_ edited: Self, since original: Self) {
        if edited.probeInterval != original.probeInterval { probeInterval = edited.probeInterval }
        if edited.sshAnchorEnabled != original.sshAnchorEnabled { sshAnchorEnabled = edited.sshAnchorEnabled }
        if edited.recordsNetworkHistory != original.recordsNetworkHistory { recordsNetworkHistory = edited.recordsNetworkHistory }
        if edited.wifiPriority != original.wifiPriority { wifiPriority = edited.wifiPriority }
        let removed = Set(original.anchors.map(\.id)).subtracting(edited.anchors.map(\.id))
        anchors.removeAll { removed.contains($0.id) }
        for anchor in edited.anchors {
            guard let before = original.anchors.first(where: { $0.id == anchor.id }) else {
                if !anchors.contains(where: { $0.id == anchor.id }) { anchors.append(anchor) }
                continue
            }
            guard let index = anchors.firstIndex(where: { $0.id == anchor.id }) else { continue }
            if anchor.isEnabled != before.isEnabled { anchors[index].isEnabled = anchor.isEnabled }
            if anchor.hostAlias != before.hostAlias { anchors[index].hostAlias = anchor.hostAlias }
            if anchor.hostName != before.hostName { anchors[index].hostName = anchor.hostName }
            if anchor.port != before.port { anchors[index].port = anchor.port }
            if anchor.identity != before.identity { anchors[index].identity = anchor.identity }
            if anchor.localHostName != before.localHostName { anchors[index].localHostName = anchor.localHostName }
            if anchor.tailscaleFallback != before.tailscaleFallback { anchors[index].tailscaleFallback = anchor.tailscaleFallback }
            if anchor.keyAccessVerifiedAt != before.keyAccessVerifiedAt { anchors[index].keyAccessVerifiedAt = anchor.keyAccessVerifiedAt }
        }
    }
}

public nonisolated struct WiFiPriorityConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var outageThreshold: TimeInterval
    public var ssids: [String]

    public init(
        isEnabled: Bool = false,
        outageThreshold: TimeInterval = 10,
        ssids: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.outageThreshold = min(max(outageThreshold, 5), 60)
        self.ssids = Array(
            ssids.compactMap(NetworkIdentity.normalizedSSID).uniqued().prefix(16)
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decode(Bool.self, forKey: .isEnabled),
            outageThreshold: try values.decode(TimeInterval.self, forKey: .outageThreshold),
            ssids: try values.decode([String].self, forKey: .ssids)
        )
    }
}

nonisolated struct WiFiFailoverMonitor: Sendable {
    private(set) var outageBeganAt: Date?
    private(set) var lastAttemptAt: Date?

    mutating func shouldAttempt(
        isFailure: Bool,
        threshold: TimeInterval,
        at date: Date
    ) -> Bool {
        guard isFailure else {
            outageBeganAt = nil
            lastAttemptAt = nil
            return false
        }
        guard let outageBeganAt else {
            self.outageBeganAt = date
            return false
        }
        guard date.timeIntervalSince(outageBeganAt) >= threshold else { return false }
        return lastAttemptAt.map { date.timeIntervalSince($0) >= 30 } ?? true
    }

    mutating func didAttempt(at date: Date) {
        lastAttemptAt = date
    }

    static func nextSSID(
        after currentSSID: String?,
        priorities: [String],
        availableSSIDs: Set<String>
    ) -> String? {
        guard !priorities.isEmpty else { return nil }
        guard let currentSSID,
              let index = priorities.firstIndex(of: currentSSID)
        else { return priorities.first(where: availableSSIDs.contains) }
        let candidates = priorities[(index + 1)...] + priorities[..<index]
        return candidates.first(where: availableSSIDs.contains)
    }
}

public nonisolated struct NetworkHistory: Codable, Equatable, Sendable {
    public var events: [NetworkTransitionEvent]

    public init(events: [NetworkTransitionEvent] = [], limit: Int = 500) {
        self.events = Array(events.suffix(max(1, limit)))
    }

    mutating func append(_ event: NetworkTransitionEvent, limit: Int = 500) {
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    mutating func migrateLegacySSIDs(currentNetwork: NetworkRuntimeSnapshot? = nil) -> Bool {
        var ssidsByNetworkID: [String: Set<String>] = [:]
        for event in events {
            if let ssid = NetworkIdentity.normalizedSSID(event.ssid) {
                ssidsByNetworkID[event.networkID, default: []].insert(ssid)
            }
        }
        if let currentNetwork,
           let ssid = NetworkIdentity.normalizedSSID(currentNetwork.ssid) {
            ssidsByNetworkID[currentNetwork.networkID, default: []].insert(ssid)
        }
        let unambiguousSSIDs = ssidsByNetworkID.compactMapValues { values in
            values.count == 1 ? values.first : nil
        }
        let ssidsByFallbackName = Dictionary(grouping: unambiguousSSIDs) {
            NetworkIdentity(networkID: $0.key, ssid: nil).displayName
        }.compactMapValues { entries in
            let values = Set(entries.map { $0.value })
            return values.count == 1 ? values.first : nil
        }
        var changed = false
        events = events.map { event in
            let ssid = event.ssid ?? unambiguousSSIDs[event.networkID]
            let changes = event.changes.map { change in
                guard case .network(let from, let to) = change else { return change }
                return .network(
                    from: ssidsByFallbackName[from] ?? from,
                    to: ssidsByFallbackName[to] ?? to
                )
            }
            guard ssid != event.ssid || changes != event.changes else { return event }
            changed = true
            return NetworkTransitionEvent(
                networkID: event.networkID,
                ssid: ssid,
                date: event.date,
                changes: changes
            )
        }
        return changed
    }
}

public nonisolated enum SSHAnchorRuntimeState: String, Codable, Sendable {
    case idle
    case healthy
    case fallback
    case fallbackUnavailable
    case scanning
    case recovered
    case notFound
    case ambiguous
    case unavailable
    case error
}

public nonisolated struct SSHAnchorStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { anchorID }
    public let anchorID: UUID
    public let state: SSHAnchorRuntimeState
    public let currentHostName: String
    public let lastCheck: Date
    public let message: String?

    public init(anchorID: UUID, state: SSHAnchorRuntimeState, currentHostName: String, lastCheck: Date, message: String?) {
        self.anchorID = anchorID
        self.state = state
        self.currentHostName = currentHostName
        self.lastCheck = lastCheck
        self.message = message
    }
}

public nonisolated struct NetToysHelperStatus: Codable, Equatable, Sendable {
    public let version: Int
    public let heartbeat: Date
    public let anchors: [SSHAnchorStatus]
    public var network: NetworkRuntimeSnapshot?
    public var sourceCommit: String?
    public var ssidAccess: NetToysSSIDAccessState?
    public var wifiFailover: WiFiFailoverStatus?
    public var ownerBundleID: String?
    public var ownerPID: Int32?
    public var packageVersion: String?

    public init(version: Int, heartbeat: Date, anchors: [SSHAnchorStatus], network: NetworkRuntimeSnapshot? = nil,
                sourceCommit: String? = nil, ssidAccess: NetToysSSIDAccessState? = nil,
                wifiFailover: WiFiFailoverStatus? = nil, ownerBundleID: String? = nil,
                ownerPID: Int32? = nil, packageVersion: String? = nil) {
        self.version = version
        self.heartbeat = heartbeat
        self.anchors = anchors
        self.network = network
        self.sourceCommit = sourceCommit
        self.ssidAccess = ssidAccess
        self.wifiFailover = wifiFailover
        self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID
        self.packageVersion = packageVersion
    }
}

public nonisolated enum NetToysSSIDAccessState: String, Codable, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case allowed
}

public nonisolated enum WiFiFailoverState: String, Codable, Equatable, Sendable {
    case monitoring
    case waiting
    case switching
    case failed
}

public nonisolated struct WiFiFailoverStatus: Codable, Equatable, Sendable {
    public let state: WiFiFailoverState
    public let message: String
    public let updatedAt: Date
}

public nonisolated struct NetworkRuntimeSnapshot: Codable, Equatable, Sendable {
    public let networkID: String
    public let ssid: String?
    public let gateway: NetworkReachability
    public let internet: NetworkReachability
    public let checkedAt: Date

    public init(
        networkID: String,
        ssid: String? = nil,
        gateway: NetworkReachability,
        internet: NetworkReachability,
        checkedAt: Date
    ) {
        self.networkID = networkID
        self.ssid = ssid
        self.gateway = gateway
        self.internet = internet
        self.checkedAt = checkedAt
    }

    public var displayName: String { NetworkIdentity(networkID: networkID, ssid: ssid).displayName }
}

package nonisolated struct NetworkIdentity: Equatable, Sendable {
    package let networkID: String
    package let ssid: String?

    package init(networkID: String, ssid: String?) {
        self.networkID = networkID
        self.ssid = Self.normalizedSSID(ssid)
    }

    package var interfaceName: String? { components?.0 }
    package var gateway: String? { components?.1 }

    package var displayName: String {
        guard networkID != "disconnected" else { return "Disconnected" }
        if let ssid { return ssid }
        guard let components else { return networkID }
        return [components.0, components.1].joined(separator: " | ")
    }

    static func normalizedSSID(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var components: (String, String)? {
        let parts = networkID.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

package nonisolated enum NetworkSSID {
    package static func isWiFi(interfaceName: String) -> Bool {
        CWWiFiClient.shared().interface(withName: interfaceName) != nil
    }

    package static func current(interfaceName: String) -> String? {
        NetworkIdentity.normalizedSSID(
            CWWiFiClient.shared().interface(withName: interfaceName)?.ssid()
        )
    }
}

package nonisolated enum WiFiNetworkController {
    enum WiFiError: LocalizedError {
        case interfaceUnavailable
        case joinFailed(String)

        var errorDescription: String? {
            switch self {
            case .interfaceUnavailable: "No Wi-Fi interface is available."
            case .joinFailed(let message): message
            }
        }
    }

    package static func preferredNetworks() async -> [String] {
        guard let interfaceName = CWWiFiClient.shared().interface()?.interfaceName else { return [] }
        let result = await runNetworkSetup(["-listpreferredwirelessnetworks", interfaceName])
        guard result.status == 0 else { return [] }
        return parsePreferredNetworks(result.output)
    }

    static func availableSSIDs() async -> Set<String> {
        await Task.detached(priority: .utility) {
            guard let interface = CWWiFiClient.shared().interface(),
                  let networks = try? interface.scanForNetworks(withName: nil)
            else { return [] }
            return Set(networks.compactMap { NetworkIdentity.normalizedSSID($0.ssid) })
        }.value
    }

    static func join(_ ssid: String) async throws {
        guard let interfaceName = CWWiFiClient.shared().interface()?.interfaceName else {
            throw WiFiError.interfaceUnavailable
        }
        let result = await runNetworkSetup(["-setairportnetwork", interfaceName, ssid])
        guard result.status == 0 else {
            throw WiFiError.joinFailed(
                NetworkIdentity.normalizedSSID(result.output) ?? "macOS could not join \(ssid)."
            )
        }
    }

    static func parsePreferredNetworks(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap {
            NetworkIdentity.normalizedSSID(String($0))
        }.uniqued()
    }

    private static func runNetworkSetup(_ arguments: [String]) async -> (status: Int32, output: String) {
        do {
            let result = try await SSHProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/networksetup"),
                arguments: arguments,
                maximumOutputBytes: 1_048_576,
                timeout: 15
            )
            return (result.status, result.standardOutput + result.standardError)
        } catch SSHKeyAccessError.timeout {
            return (-1, "The Wi-Fi request timed out. Try again.")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

private nonisolated extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

public nonisolated struct DefaultRoute: Equatable, Sendable {
    public let interfaceName: String
    public let gateway: String

    public init(interfaceName: String, gateway: String) {
        self.interfaceName = interfaceName
        self.gateway = gateway
    }

    package var networkID: String { "\(interfaceName)|\(gateway)" }

    public static func parse(_ output: String) -> DefaultRoute? {
        var interfaceName: String?
        var gateway: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2 else { continue }
            if fields[0] == "interface" { interfaceName = fields[1] }
            if fields[0] == "gateway" { gateway = fields[1] }
        }
        guard let interfaceName, let gateway, IPv4Address(gateway) != nil else { return nil }
        return DefaultRoute(interfaceName: interfaceName, gateway: gateway)
    }

    public static func load() async -> DefaultRoute? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", "default"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return parse(String(decoding: data, as: UTF8.self))
            } catch {
                return nil
            }
        }.value
    }
}

public nonisolated enum NetToysPaths {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPowerToys/NetToys", isDirectory: true)
    }

    public static var configuration: URL { directory.appendingPathComponent("configuration.json") }
    public static var helperStatus: URL { directory.appendingPathComponent("helper-status.json") }
    static var history: URL { directory.appendingPathComponent("history.json") }
    static var scanHistory: URL { directory.appendingPathComponent("scan-history.json") }
    static var scannerAnnotations: URL { directory.appendingPathComponent("scanner-annotations.json") }
    static var favoriteTargets: URL { directory.appendingPathComponent("favorite-targets.json") }
    package static var backups: URL { directory.appendingPathComponent("SSH Backups", isDirectory: true) }
}

public nonisolated enum NetToysConfigurationStore {
    public static func saveChanges(
        _ edited: NetToysConfiguration,
        since original: NetToysConfiguration,
        to url: URL = NetToysPaths.configuration
    ) throws -> NetToysConfiguration {
        let directory = url.deletingLastPathComponent()
        return try NetToysStoreTransaction.withLock(at: directory) {
            var latest = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(NetToysConfiguration.self, from: Data(contentsOf: url))
                : NetToysConfiguration()
            latest.applyEdits(edited, since: original)
            try JSONEncoder().encode(latest).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return latest
        }
    }

    @discardableResult
    public static func setBackgroundRequest(_ enabled: Bool, for host: NetToysHostID,
                                            to url: URL = NetToysPaths.configuration) throws -> NetToysConfiguration {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            var latest = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(NetToysConfiguration.self, from: Data(contentsOf: url))
                : NetToysConfiguration()
            if enabled { latest.backgroundRequests.insert(host) } else { latest.backgroundRequests.remove(host) }
            try JSONEncoder().encode(latest).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return latest
        }
    }

    public static func load() -> NetToysConfiguration {
        guard let data = try? Data(contentsOf: NetToysPaths.configuration),
              let value = try? JSONDecoder().decode(NetToysConfiguration.self, from: data)
        else { return NetToysConfiguration() }
        return value
    }

    public static func status() -> NetToysHelperStatus? {
        guard let data = try? Data(contentsOf: NetToysPaths.helperStatus) else { return nil }
        return try? JSONDecoder().decode(NetToysHelperStatus.self, from: data)
    }

    static func saveStatus(_ status: NetToysHelperStatus) throws {
        try NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            try JSONEncoder().encode(status).write(to: NetToysPaths.helperStatus, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: NetToysPaths.helperStatus.path)
        }
    }

    public static func history() -> NetworkHistory {
        (try? NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            guard let data = try? Data(contentsOf: NetToysPaths.history),
                  var value = try? JSONDecoder().decode(NetworkHistory.self, from: data)
            else { return NetworkHistory() }
            if value.migrateLegacySSIDs(currentNetwork: status()?.network) {
                try JSONEncoder().encode(value).write(to: NetToysPaths.history, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: NetToysPaths.history.path)
            }
            return value
        }) ?? NetworkHistory()
    }

    package static func saveHistory(_ history: NetworkHistory) throws {
        try NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            try JSONEncoder().encode(history).write(to: NetToysPaths.history, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: NetToysPaths.history.path)
        }
    }

    static func appendHistory(_ event: NetworkTransitionEvent) throws {
        try NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            var history = (try? JSONDecoder().decode(NetworkHistory.self, from: Data(contentsOf: NetToysPaths.history)))
                ?? NetworkHistory()
            history.append(event)
            try JSONEncoder().encode(history).write(to: NetToysPaths.history, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: NetToysPaths.history.path)
        }
    }
}
