import Foundation
import Synchronization

/// Round-trip statistics for one ping target or one traceroute hop. All times are milliseconds.
public nonisolated struct NetToysLatencyStats: Equatable, Sendable {
    public private(set) var sent = 0
    public private(set) var received = 0
    public private(set) var last: Double?
    public private(set) var best: Double?
    public private(set) var worst: Double?
    /// Mean absolute change between consecutive replies (the mtr "jitter" figure).
    public private(set) var jitter: Double?
    private var total = 0.0
    private var jitterTotal = 0.0

    public init() {}

    public var average: Double? { received == 0 ? nil : total / Double(received) }
    public var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }

    /// One probe: the round trip, or nil when it was lost.
    public mutating func record(_ milliseconds: Double?) {
        sent += 1
        guard let milliseconds else { return }
        if let last { jitterTotal += abs(milliseconds - last) }
        received += 1
        total += milliseconds
        last = milliseconds
        best = min(best ?? milliseconds, milliseconds)
        worst = max(worst ?? milliseconds, milliseconds)
        jitter = received > 1 ? jitterTotal / Double(received - 1) : nil
    }
}

public nonisolated struct NetToysHop: Equatable, Sendable, Identifiable {
    public var id: Int { ttl }
    public let ttl: Int
    /// The router that answered last; nil while every probe of this hop is lost.
    public internal(set) var address: String?
    public internal(set) var hostname: String?
    public internal(set) var stats = NetToysLatencyStats()
}

public nonisolated struct NetToysTraceSnapshot: Equatable, Sendable {
    public let target: String
    public let round: Int
    public let reachedTarget: Bool
    public let hops: [NetToysHop]
}

/// Traceroute and MTR over the shared unprivileged ICMP socket: TTL-limited echoes, routers answer with
/// "time exceeded". Each round sends one probe to every hop at once.
public nonisolated enum NetToysTraceroute {
    /// Traceroute is 3 rounds; MTR passes `rounds: nil` and runs until the task or stream is cancelled.
    /// Yields the whole hop table after each round, and once more when reverse names arrive.
    public static func run(
        host: String,
        rounds: Int? = 3,
        maxHops: Int = 30,
        interval: Duration = .seconds(1),
        timeoutMilliseconds: Int = 1_000
    ) -> AsyncThrowingStream<NetToysTraceSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard ICMPEcho.isAvailable else { throw NetToysDiagnoseError.icmpUnavailable }
                    let target = try await DiagnoseHost.resolve(host)
                    let names = ReverseNames()
                    var hops = (1...max(maxHops, 1)).map { NetToysHop(ttl: $0) }
                    var last = hops.count
                    var reached = false
                    var round = 0
                    func snapshot() -> NetToysTraceSnapshot {
                        let named = hops.map { hop in
                            var hop = hop
                            hop.hostname = hop.address.flatMap(names.name)
                            return hop
                        }
                        // Trailing hops that never answered add no information.
                        let shown = (named.prefix(last).lastIndex { $0.address != nil }).map { named.prefix($0 + 1) }
                        return NetToysTraceSnapshot(target: target.description, round: round,
                                                    reachedTarget: reached, hops: Array(shown ?? []))
                    }
                    while rounds.map({ round < $0 }) ?? true, !Task.isCancelled {
                        let started = ContinuousClock.now
                        let span = last
                        let replies = await withTaskGroup(of: (Int, ICMPEcho.Reply?).self) { group in
                            for ttl in 1...span {
                                group.addTask {
                                    (ttl, await ICMPEcho.probe(to: target, timeoutMilliseconds: timeoutMilliseconds, ttl: ttl))
                                }
                            }
                            return await group.reduce(into: [Int: ICMPEcho.Reply]()) { $0[$1.0] = $1.1 }
                        }
                        guard !Task.isCancelled else { break }
                        round += 1
                        for ttl in 1...span {
                            let reply = replies[ttl]
                            hops[ttl - 1].stats.record(reply?.milliseconds)
                            if let source = reply?.source {
                                let address = IPv4Address(rawValue: source)
                                hops[ttl - 1].address = address.description
                                names.lookup(address)
                            }
                        }
                        // The path ends at the first hop where the target answers or a router says unreachable.
                        if let end = replies.filter({ [0, 3].contains($0.value.type) }).keys.min() {
                            last = min(last, end)
                            reached = reached || replies[end]?.type == 0
                        }
                        continuation.yield(snapshot())
                        if let rounds, round >= rounds { break }
                        try? await Task.sleep(until: started + interval)
                    }
                    if !Task.isCancelled {
                        await names.wait()
                        continuation.yield(snapshot())
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reverse DNS for hop addresses, looked up once each in the background.
private nonisolated final class ReverseNames: Sendable {
    private let state = Mutex<(names: [String: String], tasks: [IPv4Address: Task<Void, Never>])>(([:], [:]))

    func name(_ address: String) -> String? { state.withLock { $0.names[address] } }

    func lookup(_ address: IPv4Address) {
        state.withLock { state in
            guard state.tasks[address] == nil else { return }
            state.tasks[address] = Task { [self] in
                guard let name = await HostResolver.reverse(address) else { return }
                self.state.withLock { $0.names[address.description] = name }
            }
        }
    }

    func wait() async {
        for task in state.withLock({ Array($0.tasks.values) }) { await task.value }
    }
}

public nonisolated struct NetToysPingSample: Equatable, Sendable {
    public let sequence: Int
    public let address: String
    /// Nil when the reply did not arrive in time.
    public let milliseconds: Double?
    public let ttl: Int?
}

/// Continuous ping over the shared ICMP socket; feed the samples into `NetToysLatencyStats`.
public nonisolated enum NetToysPing {
    /// `count: nil` pings until the stream is cancelled.
    public static func stream(
        host: String,
        count: Int? = nil,
        interval: Duration = .seconds(1),
        timeoutMilliseconds: Int = 1_000
    ) -> AsyncThrowingStream<NetToysPingSample, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard ICMPEcho.isAvailable else { throw NetToysDiagnoseError.icmpUnavailable }
                    let target = try await DiagnoseHost.resolve(host)
                    var sequence = 0
                    while count.map({ sequence < $0 }) ?? true, !Task.isCancelled {
                        let started = ContinuousClock.now
                        let reply = await ICMPEcho.send(to: target, timeoutMilliseconds: timeoutMilliseconds)
                        guard !Task.isCancelled else { break }
                        sequence += 1
                        continuation.yield(NetToysPingSample(sequence: sequence, address: target.description,
                                                             milliseconds: reply?.milliseconds, ttl: reply?.ttl))
                        if count.map({ sequence >= $0 }) ?? false { break }
                        try? await Task.sleep(until: started + interval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
