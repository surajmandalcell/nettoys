@preconcurrency import CoreWLAN
import Foundation

public nonisolated enum NetToysWiFiBand: String, CaseIterable, Codable, Sendable {
    case ghz2 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case ghz6 = "6 GHz"

    init?(_ band: CWChannelBand) {
        switch band {
        case .band2GHz: self = .ghz2
        case .band5GHz: self = .ghz5
        case .band6GHz: self = .ghz6
        default: return nil
        }
    }
}

nonisolated func channelWidthMHz(_ width: CWChannelWidth) -> Int {
    switch width {
    case .width40MHz: 40
    case .width80MHz: 80
    case .width160MHz: 160
    default: 20
    }
}

// MARK: - Wi-Fi Analyzer

public nonisolated struct NetToysWiFiNetwork: Equatable, Identifiable, Sendable {
    public var id: String { bssid ?? "\(ssid ?? "")|\(channel)|\(rssi)|\(band.rawValue)" }
    /// Nil when macOS hides names (no Location permission) or the network hides its name.
    public let ssid: String?
    public let bssid: String?
    public let rssi: Int
    public let noise: Int
    public let channel: Int
    public let band: NetToysWiFiBand
    public let widthMHz: Int

    public init(ssid: String?, bssid: String?, rssi: Int, noise: Int, channel: Int, band: NetToysWiFiBand, widthMHz: Int) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
    }

    /// The 20 MHz channels this network covers. On 2.4 GHz a 20 MHz signal spills about 4 channels each way.
    var covered: ClosedRange<Int> {
        if band == .ghz2 { return (channel - 4)...(channel + 4) }
        let base = band == .ghz6 ? 1 : (channel >= 149 ? 149 : 36)
        let size = max(1, widthMHz / 20)
        let start = (channel - base) / 4 / size * size
        return (base + start * 4)...(base + (start + size - 1) * 4)
    }
}

public nonisolated struct NetToysChannelUsage: Equatable, Identifiable, Sendable {
    public var id: String { "\(band.rawValue)|\(channel)" }
    public let band: NetToysWiFiBand
    public let channel: Int
    /// Networks whose main channel is this one.
    public let networks: Int
    /// Networks that use or overlap this channel, including `networks`.
    public let overlapping: Int
}

public nonisolated struct NetToysChannelAdvice: Equatable, Sendable {
    public let band: NetToysWiFiBand
    public let channel: Int
    public let overlapping: Int
    /// A plain sentence, such as "Channel 44: no other network uses or overlaps it."
    public let reason: String
}

public nonisolated struct NetToysWiFiScan: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ok
        /// Channels and signal are real, but macOS hides network names without Location permission.
        case namesHidden
        case wifiOff
        case noInterface
        case failed(String)
    }

    public let state: State
    public let networks: [NetToysWiFiNetwork]
    public let usage: [NetToysChannelUsage]
    public let advice: [NetToysChannelAdvice]
    public let currentChannel: Int?
    public let currentBand: NetToysWiFiBand?

    /// macOS cannot measure channel load (airtime) without monitor mode, so crowding is a count of networks.
    public static let limitNote = "Busy is a count of nearby networks. macOS cannot measure how much each channel is used."
}

public nonisolated enum NetToysWiFiAnalyzer {
    static let nonDFS5 = [36, 40, 44, 48, 149, 153, 157, 161, 165]
    static let dfs5 = [52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144]
    /// 6 GHz preferred scanning channels, where clients look first.
    static let psc6 = Array(stride(from: 5, through: 229, by: 16))

    /// Scans once (takes a few seconds). Without Location permission macOS hides names but keeps channels.
    public static func scan() async -> NetToysWiFiScan {
        await Task.detached(priority: .utility) {
            guard let interface = CWWiFiClient.shared().interface() else { return empty(.noInterface) }
            guard interface.powerOn() else { return empty(.wifiOff) }
            let found: Set<CWNetwork>
            do { found = try interface.scanForNetworks(withName: nil) } catch {
                return empty(.failed(error.localizedDescription))
            }
            let networks = found.compactMap { network -> NetToysWiFiNetwork? in
                guard let channel = network.wlanChannel, let band = NetToysWiFiBand(channel.channelBand) else { return nil }
                return NetToysWiFiNetwork(ssid: network.ssid, bssid: network.bssid, rssi: network.rssiValue,
                                          noise: network.noiseMeasurement, channel: channel.channelNumber, band: band,
                                          widthMHz: channelWidthMHz(channel.channelWidth))
            }.sorted { $0.rssi > $1.rssi }
            let supported = Set((interface.supportedWLANChannels() ?? []).compactMap { channel in
                NetToysWiFiBand(channel.channelBand).map { "\($0.rawValue)|\(channel.channelNumber)" }
            })
            let current = interface.wlanChannel()
            let others = networks.filter { $0.ssid == nil || $0.ssid != interface.ssid() }
            return NetToysWiFiScan(state: networks.contains { $0.ssid != nil } || networks.isEmpty ? .ok : .namesHidden,
                                   networks: networks, usage: usage(networks),
                                   advice: advice(others, supports: { supported.isEmpty || supported.contains("\($0.rawValue)|\($1)") }),
                                   currentChannel: current?.channelNumber,
                                   currentBand: current.flatMap { NetToysWiFiBand($0.channelBand) })
        }.value
    }

    private static func empty(_ state: NetToysWiFiScan.State) -> NetToysWiFiScan {
        NetToysWiFiScan(state: state, networks: [], usage: [], advice: [], currentChannel: nil, currentBand: nil)
    }

    /// Every channel some network uses, with how many networks sit on it and how many overlap it.
    static func usage(_ networks: [NetToysWiFiNetwork]) -> [NetToysChannelUsage] {
        Set(networks.map { "\($0.band.rawValue)|\($0.channel)" }).compactMap { key -> NetToysChannelUsage? in
            guard let network = networks.first(where: { "\($0.band.rawValue)|\($0.channel)" == key }) else { return nil }
            return NetToysChannelUsage(band: network.band, channel: network.channel,
                                       networks: networks.filter { $0.band == network.band && $0.channel == network.channel }.count,
                                       overlapping: overlapCount(networks, band: network.band, channel: network.channel))
        }.sorted { ($0.band.rawValue, $0.channel) < ($1.band.rawValue, $1.channel) }
    }

    static func overlapCount(_ networks: [NetToysWiFiNetwork], band: NetToysWiFiBand, channel: Int) -> Int {
        networks.filter { $0.band == band && $0.covered.contains(channel) }.count
    }

    /// The least crowded channel per band, from `networks` (the Mac's own network left out). Ties go to
    /// channels without radar rules (DFS), then to the lower channel.
    static func advice(_ networks: [NetToysWiFiNetwork],
                       supports: (NetToysWiFiBand, Int) -> Bool = { _, _ in true }) -> [NetToysChannelAdvice] {
        let candidates: [(NetToysWiFiBand, [Int])] = [(.ghz2, [1, 6, 11]), (.ghz5, nonDFS5 + dfs5), (.ghz6, psc6)]
        return candidates.compactMap { band, channels in
            let scored = channels.filter { supports(band, $0) }
                .map { (channel: $0, count: overlapCount(networks, band: band, channel: $0), dfs: dfs5.contains($0) && band == .ghz5) }
                .sorted { ($0.count, $0.dfs ? 1 : 0, $0.channel) < ($1.count, $1.dfs ? 1 : 0, $1.channel) }
            guard let best = scored.first else { return nil }
            let others = scored.dropFirst().filter { !$0.dfs }.prefix(2)
                .map { "channel \($0.channel) has \($0.count)" }.joined(separator: ", ")
            var reason = best.count == 0
                ? "Channel \(best.channel): no other network uses or overlaps it."
                : "Channel \(best.channel): \(best.count) \(best.count == 1 ? "network uses or overlaps" : "networks use or overlap") it, the fewest on \(band.rawValue)."
            if !others.isEmpty { reason += " For comparison, \(others)." }
            if best.dfs { reason += " It is a radar (DFS) channel: the router may have to leave it when it detects radar." }
            return NetToysChannelAdvice(band: band, channel: best.channel, overlapping: best.count, reason: reason)
        }
    }
}

// MARK: - Wi-Fi Signal

public nonisolated struct NetToysWiFiSignalSample: Equatable, Sendable {
    public let date: Date
    /// Nil without Location permission.
    public let ssid: String?
    public let rssi: Int
    public let noise: Int
    public var snr: Int { rssi - noise }
    public let transmitRateMbps: Double
    public let channel: Int?
    public let band: NetToysWiFiBand?
    public let widthMHz: Int?
}

public nonisolated enum NetToysWiFiSignal {
    /// Nil when Wi-Fi is off or not joined to a network.
    public static func current() -> NetToysWiFiSignalSample? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.rssiValue() != 0
        else { return nil }
        let channel = interface.wlanChannel()
        return NetToysWiFiSignalSample(date: Date(), ssid: interface.ssid(), rssi: interface.rssiValue(),
                                       noise: interface.noiseMeasurement(), transmitRateMbps: interface.transmitRate(),
                                       channel: channel?.channelNumber,
                                       band: channel.flatMap { NetToysWiFiBand($0.channelBand) },
                                       widthMHz: channel.map { channelWidthMHz($0.channelWidth) })
    }

    /// One sample per second (nil while not on Wi-Fi) until the caller stops reading.
    public static func live(interval: Duration = .seconds(1)) -> AsyncStream<NetToysWiFiSignalSample?> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    continuation.yield(current())
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
