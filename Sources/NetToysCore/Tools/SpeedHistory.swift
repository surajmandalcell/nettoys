import Foundation
import os

// MARK: - One run

public nonisolated struct NetToysSpeedRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let downloadMbps: Double
    public let uploadMbps: Double?
    /// Round trips per minute under load, from networkQuality; higher is better.
    public let responsivenessRPM: Double?
    public let idleLatencyMilliseconds: Double?
    public let interfaceName: String?
    /// The Wi-Fi name, or the interface name on a wired network. It is the owner's own data, so it is kept plain.
    public let networkName: String?
    public let publicIP: String?
    public let isp: String?
    /// The test server, when networkQuality names it.
    public let server: String?

    public init(date: Date, downloadMbps: Double, uploadMbps: Double?, responsivenessRPM: Double?,
                idleLatencyMilliseconds: Double?, interfaceName: String?, networkName: String?, publicIP: String?,
                isp: String?, server: String?) {
        self.date = date
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.responsivenessRPM = responsivenessRPM
        self.idleLatencyMilliseconds = idleLatencyMilliseconds
        self.interfaceName = interfaceName
        self.networkName = networkName
        self.publicIP = publicIP
        self.isp = isp
        self.server = server
    }
}

// MARK: - History (speed-history.json: 1 year, 512 KB cap)

public nonisolated enum NetToysSpeedHistory {
    static let maximumAge: TimeInterval = 365 * 86_400
    static let maximumBytes = 512 * 1_024

    /// Every saved run, oldest first.
    public static func load(paths: NetToysRuntimePaths = .standard) -> [NetToysSpeedRecord] {
        ToolFiles.load([NetToysSpeedRecord].self, from: paths.speedHistory) ?? []
    }

    /// Saves a run, for example one the Speed Test page started.
    public static func append(_ record: NetToysSpeedRecord, paths: NetToysRuntimePaths = .standard,
                              now: Date = Date()) throws {
        _ = try ToolFiles.update([NetToysSpeedRecord].self, at: paths.speedHistory, empty: []) { records in
            let result = try capped(records + [record], now: now)
            records = result.items
            return result.data
        }
    }

    static func capped(_ records: [NetToysSpeedRecord], now: Date,
                       maximumBytes: Int = maximumBytes) throws -> (items: [NetToysSpeedRecord], data: Data) {
        try ToolFiles.trimmed(records.sorted { $0.date < $1.date }.filter { now.timeIntervalSince($0.date) < maximumAge },
                              maximumBytes: maximumBytes)
    }
}

// MARK: - Runner

public nonisolated enum NetToysSpeedTestRunner {
    public enum RunError: LocalizedError, Equatable {
        case busy
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .busy: "A speed test is already running."
            case .failed(let message): message
            }
        }
    }

    private static let running = OSAllocatedUnfairLock(initialState: false)

    /// Runs `networkQuality -c` (download and upload at once), then reads the public IP and ISP name.
    /// Cancelling the task stops the test. It does not save the run; call `NetToysSpeedHistory.append`.
    public static func run(maximumSeconds: Int = 30) async throws -> NetToysSpeedRecord {
        guard running.withLock({ busy in defer { busy = true }; return !busy }) else { throw RunError.busy }
        defer { running.withLock { $0 = false } }
        let result: SSHProcessResult
        do {
            result = try await SSHProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/networkQuality"),
                                                    arguments: ["-c", "-M", "\(maximumSeconds)"],
                                                    maximumOutputBytes: 1_048_576,
                                                    timeout: TimeInterval(maximumSeconds + 30))
        } catch {
            throw RunError.failed("The speed test did not finish: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard let parsed = parse(result.standardOutput) else {
            throw RunError.failed("The speed test did not finish.")
        }
        let (ip, isp) = await ToolHTTP.ispName()
        let network = parsed.interfaceName.flatMap {
            NetworkSSID.isWiFi(interfaceName: $0) ? NetworkSSID.current(interfaceName: $0) : $0
        }
        return NetToysSpeedRecord(date: Date(), downloadMbps: parsed.download, uploadMbps: parsed.upload,
                                  responsivenessRPM: parsed.rpm, idleLatencyMilliseconds: parsed.baseRTT,
                                  interfaceName: parsed.interfaceName, networkName: network ?? parsed.interfaceName,
                                  publicIP: ip, isp: isp, server: parsed.server)
    }

    struct Parsed: Equatable {
        var download: Double
        var upload: Double?
        var rpm: Double?
        var baseRTT: Double?
        var interfaceName: String?
        var server: String?
    }

    /// Reads networkQuality's JSON; throughput is in bits per second.
    static func parse(_ json: String) -> Parsed? {
        guard let start = json.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any],
              object["error_code"] == nil,
              let download = (object["dl_throughput"] as? NSNumber)?.doubleValue, download > 0
        else { return nil }
        return Parsed(download: download / 1_000_000,
                      upload: (object["ul_throughput"] as? NSNumber).map { $0.doubleValue / 1_000_000 },
                      rpm: (object["responsiveness"] as? NSNumber)?.doubleValue,
                      baseRTT: (object["base_rtt"] as? NSNumber)?.doubleValue,
                      interfaceName: object["interface_name"] as? String,
                      server: object["test_endpoint"] as? String)
    }
}

// MARK: - Schedule (speed-schedule.json)

public nonisolated enum NetToysSpeedSchedule: Codable, Equatable, Sendable {
    case off
    case everySixHours
    case daily(hour: Int, minute: Int)

    /// Shown beside the schedule switch.
    public static let dataNote = "Each run downloads and uploads a lot of data: often several hundred MB, "
        + "and more on a fast line. Leave it off on a metered or capped plan."

    public static func load(paths: NetToysRuntimePaths = .standard) -> Self {
        ToolFiles.load(Self.self, from: paths.speedSchedule) ?? .off
    }

    public func save(paths: NetToysRuntimePaths = .standard) throws {
        _ = try ToolFiles.update(Self.self, at: paths.speedSchedule, empty: .off) { stored in
            stored = self
            return try JSONEncoder().encode(self)
        }
    }

    /// When the next run is due. A run the Mac slept through is due now, but only once.
    func nextRun(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .off: return nil
        case .everySixHours: return lastRun.map { $0.addingTimeInterval(6 * 3_600) } ?? now
        case .daily(let hour, let minute):
            let time = DateComponents(hour: hour, minute: minute, second: 0)
            return calendar.nextDate(after: lastRun ?? now, matching: time, matchingPolicy: .nextTime)
        }
    }

    /// Runs the schedule until cancelled; part of the app's monitoring runtime, so only while the Mac is awake.
    static func runLoop(paths: NetToysRuntimePaths, notify: @Sendable (NetToysAlert) -> Void) async {
        // A failed run waits for the next slot instead of retrying at once.
        var lastAttempt: Date?
        while !Task.isCancelled {
            let now = Date()
            let lastRun = [NetToysSpeedHistory.load(paths: paths).last?.date, lastAttempt].compactMap { $0 }.max()
            if let due = load(paths: paths).nextRun(lastRun: lastRun, now: now), due <= now {
                lastAttempt = now
                do {
                    try NetToysSpeedHistory.append(try await NetToysSpeedTestRunner.run(), paths: paths)
                } catch NetToysSpeedTestRunner.RunError.busy {
                } catch {
                    if Task.isCancelled { return }
                    notify(NetToysAlert(title: "Scheduled speed test failed", body: error.localizedDescription))
                }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

// MARK: - ISP report

public nonisolated struct NetToysSpeedStats: Equatable, Sendable {
    public let median: Double
    /// The slowest tenth of runs are at or below this value.
    public let p10: Double
    public let count: Int

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        p10 = sorted[max(0, Int((Double(sorted.count) * 0.1).rounded(.up)) - 1)]
        count = sorted.count
    }
}

public nonisolated struct NetToysISPReport: Equatable, Sendable {
    public let days: Int
    public let download: NetToysSpeedStats?
    public let upload: NetToysSpeedStats?
    public let responsiveness: NetToysSpeedStats?
    /// Download stats per hour of the day (0-23), in local time.
    public let downloadByHour: [Int: NetToysSpeedStats]
    /// Download stats per network name.
    public let downloadByNetwork: [String: NetToysSpeedStats]

    /// The runs of the last `days` days (7 or 30 in the app).
    public init(records: [NetToysSpeedRecord], days: Int, now: Date = Date(), calendar: Calendar = .current) {
        let runs = records.filter { now.timeIntervalSince($0.date) < Double(days) * 86_400 }
        self.days = days
        download = NetToysSpeedStats(runs.map(\.downloadMbps))
        upload = NetToysSpeedStats(runs.compactMap(\.uploadMbps))
        responsiveness = NetToysSpeedStats(runs.compactMap(\.responsivenessRPM))
        downloadByHour = Dictionary(grouping: runs) { calendar.component(.hour, from: $0.date) }
            .compactMapValues { NetToysSpeedStats($0.map(\.downloadMbps)) }
        downloadByNetwork = Dictionary(grouping: runs) { $0.networkName ?? "Unknown network" }
            .compactMapValues { NetToysSpeedStats($0.map(\.downloadMbps)) }
    }
}
