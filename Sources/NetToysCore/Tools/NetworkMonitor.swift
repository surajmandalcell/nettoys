import Foundation

public nonisolated struct NetToysTrafficSample: Equatable, Sendable {
    public let date: Date
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
}

/// Traffic per interface: the last 10 minutes of 1-second samples, keyed by interface name.
public nonisolated struct NetToysTrafficHistory: Equatable, Sendable {
    public static let capacity = 600
    public private(set) var samples: [String: [NetToysTrafficSample]] = [:]
    private var previous: (date: Date, counters: [String: (UInt32, UInt32)])?

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.samples == rhs.samples }

    /// Adds one reading of the byte counters. The kernel counters are 32 bits, so wrapping
    /// subtraction keeps the rate right across a wrap (at 1 s samples, up to 4 GB/s).
    mutating func add(_ counters: [String: (UInt32, UInt32)], at date: Date) {
        defer { previous = (date, counters) }
        guard let previous, date > previous.date else { return }
        let seconds = date.timeIntervalSince(previous.date)
        for (name, (bytesIn, bytesOut)) in counters {
            guard let (oldIn, oldOut) = previous.counters[name] else { continue }
            var series = samples[name, default: []]
            series.append(NetToysTrafficSample(date: date, bytesInPerSecond: Double(bytesIn &- oldIn) / seconds,
                                               bytesOutPerSecond: Double(bytesOut &- oldOut) / seconds))
            if series.count > Self.capacity { series.removeFirst(series.count - Self.capacity) }
            samples[name] = series
        }
        samples = samples.filter { counters[$0.key] != nil }
    }
}

public nonisolated enum NetToysTrafficMonitor {
    /// Yields the updated history every second while the caller reads. Interfaces that are down,
    /// loopback, and ones that never moved a byte are left out.
    public static func live(interval: Duration = .seconds(1)) -> AsyncStream<NetToysTrafficHistory> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                var history = NetToysTrafficHistory()
                while !Task.isCancelled {
                    history.add(counters(), at: Date())
                    if !history.samples.isEmpty { continuation.yield(history) }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func counters() -> [String: (UInt32, UInt32)] {
        InterfaceAddresses.all(withMAC: false).reduce(into: [:]) { result, item in
            let (name, entry) = item
            guard entry.isUp, name != "lo0", entry.bytesIn > 0 || entry.bytesOut > 0 else { return }
            result[name] = (entry.bytesIn, entry.bytesOut)
        }
    }
}
