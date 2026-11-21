import Foundation

/// The parts of the app the daily usage number marks, one bit each (slot `i` is bit `10 + i` of `u`).
/// The server names the slots in app_backend `releases.json` "nettoys.models": only append, never reorder.
public enum NetToysFeature: Int, CaseIterable, Sendable {
    case diagnose, monitor, localNetwork, wifi, palette, globalPalette, menuPanel, link

    public var name: String {
        switch self {
        case .diagnose: "Diagnose tools"
        case .monitor: "Monitor tools"
        case .localNetwork: "Local Network tools"
        case .wifi: "Wi-Fi tools"
        case .palette: "Command palette"
        case .globalPalette: "Option-Space palette"
        case .menuPanel: "Menu panel"
        case .link: "Raycast and links"
        }
    }
}

/// The counts of the current and the last finished local day, and the last day and month the server answered.
public struct NetToysUsageState: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var day = ""
        public var uses = 0
        public var features = 0
    }

    public var current = Day()
    public var previous = Day()
    public var checkedDay = ""
    public var checkedMonth = ""

    /// A new local day starts a new count; the finished day becomes `previous`.
    public mutating func roll(to today: String) {
        guard current.day != today else { return }
        if !current.day.isEmpty { previous = current }
        current = Day(day: today)
    }

    public mutating func record(_ feature: NetToysFeature?, use: Bool, today: String) {
        roll(to: today)
        if use { current.uses += 1 }
        if let feature { current.features |= 1 << feature.rawValue }
    }

    /// `u` for `yesterday`; a day with no record reports zero uses.
    public func number(yesterday: String) -> Int {
        let day = current.day == yesterday ? current : previous.day == yesterday ? previous : Day()
        return Self.number(uses: day.uses, features: day.features)
    }

    /// Encoding version 1 of app_backend docs/clients.md: bits 0-9 uses (at most 1023), 10-25 features, 26-27 version.
    public static func number(uses: Int, features: Int) -> Int {
        let uses = min(max(uses, 0), 1023)
        // The server rejects feature bits on a day with no use.
        return 1 << 26 | uses | (uses == 0 ? 0 : features & 0xFFFF) << 10
    }

    /// The number in words, for "See what's sent".
    public static func json(_ number: Int) -> String {
        let features = NetToysFeature.allCases.filter { number >> (10 + $0.rawValue) & 1 == 1 }.map(\.name)
        let object: [String: Any] = ["uses": number & 1023, "features": features, "version": number >> 26]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The once-a-day anonymous usage report: the first check of a new local day sends yesterday's `u` to
/// `GET /v1/nettoys/latest` (app_backend docs/clients.md). No install id; nothing at all while sharing is off.
/// NetToys has no updater, so the reply body is ignored.
@MainActor
public final class NetToysUsage {
    public static let shared = NetToysUsage()
    public static let shareKey = "nettoys.usage.share"
    static let stateKey = "nettoys.usage.state"
    static let endpoint = "https://apps.mandalsuraj.com/v1/nettoys/latest"

    private let defaults: UserDefaults
    private let now: () -> Date
    private var sending = false

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    public var isSharing: Bool { defaults.object(forKey: Self.shareKey) as? Bool ?? true }

    var state: NetToysUsageState {
        get { defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(NetToysUsageState.self, from: $0) } ?? .init() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.stateKey) }
    }

    /// One use (a tool run, a palette pick, the menu panel, a link) and the feature it used.
    public func record(_ feature: NetToysFeature?, use: Bool = true) {
        var state = state
        state.record(feature, use: use, today: Self.day(now()))
        self.state = state
        checkIfDue()
    }

    /// The request the first check of today sends, or nil while sharing is off.
    public func dailyRequest() -> (url: URL, number: Int)? {
        guard isSharing else { return nil }
        var state = state
        state.roll(to: Self.day(now()))
        return Self.request(state, date: now(), bundle: .main)
    }

    /// Sends today's report once; call it at launch, on wake, and when the day changes.
    public func checkIfDue() {
        guard isSharing, !sending else { return }
        let date = now()
        let today = Self.day(date)
        var state = state
        state.roll(to: today)
        self.state = state
        guard state.checkedDay != today, let request = Self.request(state, date: date, bundle: .main) else { return }
        sending = true
        Task {
            let reply = try? await URLSession(configuration: .ephemeral).data(from: request.url)
            sending = false
            // 404 "No release published" is normal: NetToys has no update feed, and the server still counts.
            guard let status = (reply?.1 as? HTTPURLResponse)?.statusCode, status == 200 || status == 404 else { return }
            var state = self.state
            state.checkedDay = today
            state.checkedMonth = String(today.prefix(7))
            self.state = state
        }
    }

    static func request(_ state: NetToysUsageState, date: Date, bundle: Bundle) -> (url: URL, number: Int)? {
        let today = day(date)
        let yesterday = day(Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date)
        let number = state.number(yesterday: yesterday)
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "version", value: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
            URLQueryItem(name: "build", value: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"),
            URLQueryItem(name: "d", value: "1"),
        ] + (state.checkedMonth == today.prefix(7) ? [] : [URLQueryItem(name: "m", value: "1")])
            + [URLQueryItem(name: "u", value: String(number))]
        return components?.url.map { ($0, number) }
    }

    /// The local day as yyyy-MM-dd.
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
