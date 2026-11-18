import Darwin
import Foundation

public nonisolated enum NetToysPortState: String, Codable, Sendable {
    case open
    /// The host answered with a reset.
    case closed
    /// No answer before the timeout, or the network refused to route it.
    case filtered
}

public nonisolated struct NetToysPortResult: Equatable, Sendable, Identifiable {
    public var id: UInt16 { port }
    public let port: UInt16
    public let state: NetToysPortState
    public let milliseconds: Double
    public var service: String? { NetToysPortScan.services[port] }
}

/// TCP connect scan (macOS blocks SYN scans for normal apps). Probes in flight adapt like the LAN scanner.
public nonisolated enum NetToysPortScan {
    public static let services: [UInt16: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3",
        111: "RPC", 135: "MS RPC", 139: "NetBIOS", 143: "IMAP", 389: "LDAP", 443: "HTTPS", 445: "SMB",
        465: "SMTPS", 548: "AFP", 554: "RTSP", 587: "SMTP submission", 631: "IPP", 993: "IMAPS", 995: "POP3S",
        1433: "MS SQL", 1521: "Oracle", 1883: "MQTT", 1900: "UPnP", 2049: "NFS", 3000: "Dev server",
        3306: "MySQL", 3389: "RDP", 5000: "AirPlay / UPnP", 5432: "PostgreSQL", 5900: "VNC", 6379: "Redis",
        7000: "AirPlay", 8000: "HTTP alt", 8080: "HTTP proxy", 8443: "HTTPS alt", 8883: "MQTT TLS",
        9000: "HTTP alt", 9100: "Printer", 9200: "Elasticsearch", 11211: "Memcached", 27017: "MongoDB",
        32400: "Plex", 62078: "iPhone sync",
    ]

    /// The preset: every port in `services`, ascending.
    public static var commonPorts: [UInt16] { services.keys.sorted() }

    /// Results stream in as ports finish, not in port order.
    public static func scan(
        host: String,
        ports: [UInt16],
        timeoutMilliseconds: Int = 1_000,
        concurrency: Int = 256
    ) -> AsyncThrowingStream<NetToysPortResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let target = try await DiagnoseHost.resolve(host)
                    var width = AdaptiveConcurrency(ceiling: concurrency)
                    await withTaskGroup(of: NetToysPortResult.self) { group in
                        var next = 0
                        var inFlight = 0
                        func launch() {
                            while inFlight < width.limit, next < ports.count, !Task.isCancelled {
                                let port = ports[next]
                                next += 1
                                inFlight += 1
                                group.addTask { await connect(target, port: port, timeoutMilliseconds: timeoutMilliseconds) }
                            }
                        }
                        launch()
                        while let result = await group.next() {
                            inFlight -= 1
                            continuation.yield(result)
                            width.record(timedOut: result.state == .filtered)
                            launch()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One nonblocking connect watched by a dispatch source, so no thread waits per port.
    static func connect(_ address: IPv4Address, port: UInt16, timeoutMilliseconds: Int) async -> NetToysPortResult {
        await withCheckedContinuation { continuation in
            ConnectAttempt(address: address, port: port, continuation: continuation)
                .start(timeoutMilliseconds: timeoutMilliseconds)
        }
    }
}

private nonisolated final class ConnectAttempt: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "NetToys.PortScan")
    private let address: IPv4Address
    private let port: UInt16
    private let started = ContinuousClock.now
    // Confined to `queue`.
    private var continuation: CheckedContinuation<NetToysPortResult, Never>?
    private var source: DispatchSourceWrite?

    init(address: IPv4Address, port: UInt16, continuation: CheckedContinuation<NetToysPortResult, Never>) {
        self.address = address
        self.port = port
        self.continuation = continuation
    }

    func start(timeoutMilliseconds: Int) {
        Self.queue.async { [self] in
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return finish(.filtered) }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = port.bigEndian
            target.sin_addr.s_addr = address.rawValue.bigEndian
            let result = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let error = errno
            guard result != 0, error == EINPROGRESS else {
                close(descriptor)
                return finish(result == 0 ? .open : error == ECONNREFUSED ? .closed : .filtered)
            }
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: Self.queue)
            source.setEventHandler { [self] in
                var status: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &status, &length)
                finish(status == 0 ? .open : status == ECONNREFUSED ? .closed : .filtered)
            }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(max(timeoutMilliseconds, 1))) { [self] in
                finish(.filtered)
            }
        }
    }

    private func finish(_ state: NetToysPortState) {
        guard let continuation else { return }
        self.continuation = nil
        source?.cancel()
        source = nil
        continuation.resume(returning: NetToysPortResult(
            port: port, state: state, milliseconds: DiagnoseHost.milliseconds(since: started)
        ))
    }
}
