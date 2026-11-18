import Foundation
import os
import Security

// MARK: - Checks (saved in uptime-checks.json)

public nonisolated struct NetToysUptimeCheck: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case ping(host: String)
        case tcp(host: String, port: UInt16)
        /// `expectedStatus` nil accepts any 2xx or 3xx answer.
        case http(url: String, expectedStatus: Int?)
    }

    public static let minimumInterval: TimeInterval = 10

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var isEnabled: Bool
    public var intervalSeconds: TimeInterval
    /// A notification goes out when a successful check is slower than this.
    public var latencyThresholdMilliseconds: Double?
    /// Failures in a row before the check counts as down.
    public var downAfterFailures: Int
    /// HTTPS only: warn this many days before the certificate expires.
    public var sslWarningDays: Int?

    public init(id: UUID = UUID(), name: String, kind: Kind, isEnabled: Bool = true, intervalSeconds: TimeInterval = 60,
                latencyThresholdMilliseconds: Double? = nil, downAfterFailures: Int = 3, sslWarningDays: Int? = 14) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.intervalSeconds = intervalSeconds
        self.latencyThresholdMilliseconds = latencyThresholdMilliseconds
        self.downAfterFailures = downAfterFailures
        self.sslWarningDays = sslWarningDays
    }

    var interval: TimeInterval { max(Self.minimumInterval, intervalSeconds) }
}

public nonisolated enum NetToysUptimeChecks {
    public static func load(paths: NetToysRuntimePaths = .standard) -> [NetToysUptimeCheck] {
        ToolFiles.load([NetToysUptimeCheck].self, from: paths.uptimeChecks) ?? []
    }

    public static func save(_ checks: [NetToysUptimeCheck], paths: NetToysRuntimePaths = .standard) throws {
        _ = try ToolFiles.update([NetToysUptimeCheck].self, at: paths.uptimeChecks, empty: []) { stored in
            stored = checks
            return try JSONEncoder().encode(checks)
        }
    }
}

// MARK: - Results (uptime-results.json: 30 days, 4 MB cap)

public nonisolated struct NetToysUptimeSample: Codable, Equatable, Sendable {
    public let date: Date
    public let milliseconds: Double?
    /// Nil when the check passed; else a short reason such as "HTTP 503" or "Timed out".
    public let failure: String?
    /// HTTPS only; not stored in the results file.
    public var certificateExpiry: Date?

    public var isUp: Bool { failure == nil }

    public init(date: Date, milliseconds: Double?, failure: String?, certificateExpiry: Date? = nil) {
        self.date = date
        self.milliseconds = milliseconds
        self.failure = failure
        self.certificateExpiry = certificateExpiry
    }

    // Stored as [seconds, ms or null, reason?] to keep 30 days small.
    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        date = Date(timeIntervalSince1970: try values.decode(Double.self))
        milliseconds = try values.decodeNil() ? nil : try values.decode(Double.self)
        failure = values.isAtEnd ? nil : try values.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(date.timeIntervalSince1970.rounded())
        if let milliseconds { try values.encode((milliseconds * 10).rounded() / 10) } else { try values.encodeNil() }
        if let failure { try values.encode(String(failure.prefix(80))) }
    }
}

public nonisolated enum NetToysUptimeResults {
    static let maximumAge: TimeInterval = 30 * 86_400
    static let maximumBytes = 4 * 1_048_576

    /// Samples per check ID, oldest first.
    public static func load(paths: NetToysRuntimePaths = .standard) -> [String: [NetToysUptimeSample]] {
        ToolFiles.load([String: [NetToysUptimeSample]].self, from: paths.uptimeResults) ?? [:]
    }

    static func append(_ samples: [String: [NetToysUptimeSample]], keeping ids: Set<String>, at url: URL,
                       now: Date) throws {
        _ = try ToolFiles.update([String: [NetToysUptimeSample]].self, at: url, empty: [:]) { series in
            try merge(&series, samples, keeping: ids, now: now)
        }
    }

    /// Adds the samples, drops removed checks and samples older than 30 days, then trims the longest series
    /// (oldest first) until the file fits 4 MB.
    static func merge(_ series: inout [String: [NetToysUptimeSample]], _ samples: [String: [NetToysUptimeSample]],
                      keeping ids: Set<String>, now: Date, maximumBytes: Int = maximumBytes) throws -> Data {
        for (key, values) in samples { series[key, default: []].append(contentsOf: values) }
        series = series.filter { ids.contains($0.key) }.compactMapValues { values in
            let kept = values.filter { now.timeIntervalSince($0.date) < maximumAge }
            return kept.isEmpty ? nil : kept
        }
        var data = try JSONEncoder().encode(series)
        while data.count > maximumBytes {
            let counts = series.values.map(\.count)
            let budget = Int(Double(counts.reduce(0, +)) * Double(maximumBytes) / Double(data.count) * 0.95)
            var low = 0, high = counts.max() ?? 0
            while low < high {
                let middle = (low + high + 1) / 2
                if counts.reduce(0, { $0 + min($1, middle) }) <= budget { low = middle } else { high = middle - 1 }
            }
            series = series.compactMapValues { low > 0 ? Array($0.suffix(low)) : nil }
            data = try JSONEncoder().encode(series)
        }
        return data
    }
}

// MARK: - State per check: down after N failures, back up, slow, certificate expiring

public nonisolated struct NetToysUptimeStatus: Equatable, Sendable {
    public private(set) var isDown = false
    public private(set) var failuresInRow = 0
    public private(set) var downSince: Date?
    public private(set) var isSlow = false
    public private(set) var last: NetToysUptimeSample?
    public private(set) var certificateExpiry: Date?
    private var firstFailure: Date?
    private var warnedExpiry: Date?

    public init() {}

    /// Returns the notifications this sample causes. A check that fails from the start still goes down.
    mutating func observe(_ sample: NetToysUptimeSample, check: NetToysUptimeCheck) -> [NetToysAlert] {
        var alerts: [NetToysAlert] = []
        last = sample
        if let failure = sample.failure {
            if failuresInRow == 0 { firstFailure = sample.date }
            failuresInRow += 1
            if !isDown, failuresInRow >= max(1, check.downAfterFailures) {
                isDown = true
                downSince = firstFailure
                alerts.append(NetToysAlert(title: "\(check.name) is down",
                                           body: failuresInRow == 1 ? "\(failure)." : "\(failure). \(failuresInRow) checks failed in a row."))
            }
            return alerts
        }
        failuresInRow = 0
        if isDown, let downSince {
            isDown = false
            alerts.append(NetToysAlert(title: "\(check.name) is back up",
                                       body: "It was down for \(NetToysDuration.text(sample.date.timeIntervalSince(downSince)))."))
        }
        downSince = nil
        if let threshold = check.latencyThresholdMilliseconds, let milliseconds = sample.milliseconds {
            if milliseconds > threshold, !isSlow {
                alerts.append(NetToysAlert(title: "\(check.name) is slow",
                                           body: "It answered in \(Int(milliseconds)) ms, over the \(Int(threshold)) ms limit."))
            }
            isSlow = milliseconds > threshold
        }
        if let expiry = sample.certificateExpiry {
            certificateExpiry = expiry
            let days = Int((expiry.timeIntervalSince(sample.date) / 86_400).rounded(.down))
            // shortcut: the warned certificate lives in memory, so a relaunch warns once more; persist it if that annoys.
            if let warning = check.sslWarningDays, days <= warning, warnedExpiry != expiry {
                warnedExpiry = expiry
                alerts.append(NetToysAlert(
                    title: "\(check.name) certificate expires soon",
                    body: days < 0 ? "The certificate has expired."
                        : "The certificate expires in \(days) \(days == 1 ? "day" : "days"), on \(expiry.formatted(date: .abbreviated, time: .omitted))."))
            }
        }
        return alerts
    }
}

// MARK: - Probes

nonisolated enum UptimeProbe {
    static func run(_ check: NetToysUptimeCheck) async -> NetToysUptimeSample {
        let date = Date()
        switch check.kind {
        case .ping(let host):
            let resolved = IPv4Address(host) == nil ? await HostResolver.forward(host).first : nil
            guard let address = IPv4Address(host) ?? resolved else {
                return NetToysUptimeSample(date: date, milliseconds: nil, failure: "Name not found")
            }
            guard let result = await PingProbe.check(address: address, count: 1, timeoutMilliseconds: 2_000) else {
                return NetToysUptimeSample(date: date, milliseconds: nil, failure: "Ping is not available")
            }
            return NetToysUptimeSample(date: date, milliseconds: result.averageMilliseconds,
                                       failure: result.averageMilliseconds == nil ? "No reply" : nil)
        case .tcp(let host, let port):
            switch await TCPConnectProbe.connect(host: host, port: port) {
            case .success(let milliseconds): return NetToysUptimeSample(date: date, milliseconds: milliseconds, failure: nil)
            case .failure(let error): return NetToysUptimeSample(date: date, milliseconds: nil, failure: error.description)
            }
        case .http(let text, let expected):
            return await http(text, expectedStatus: expected, date: date)
        }
    }

    private static func http(_ text: String, expectedStatus: Int?, date: Date) async -> NetToysUptimeSample {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return NetToysUptimeSample(date: date, milliseconds: nil, failure: "Not an http or https address")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A new session per check, so a pooled connection never hides the certificate.
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let capture = CertificateCapture()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await session.data(for: URLRequest(url: url), delegate: capture)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let passed = expectedStatus.map { $0 == status } ?? (200..<400).contains(status)
            return NetToysUptimeSample(date: date, milliseconds: milliseconds, failure: passed ? nil : "HTTP \(status)",
                                       certificateExpiry: capture.expiry.withLock { $0 })
        } catch {
            let failure = (error as? URLError).map { error -> String in
                switch error.code {
                case .timedOut: "Timed out"
                case .cannotFindHost, .dnsLookupFailed: "Name not found"
                case .cannotConnectToHost: "Connection refused"
                case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid, .secureConnectionFailed: "Certificate not trusted"
                case .notConnectedToInternet: "No internet connection"
                default: error.localizedDescription
                }
            } ?? error.localizedDescription
            return NetToysUptimeSample(date: date, milliseconds: nil, failure: failure,
                                       certificateExpiry: capture.expiry.withLock { $0 })
        }
    }
}

/// Reads the leaf certificate's expiry from the server trust, then lets the system judge the trust.
private nonisolated final class CertificateCapture: NSObject, URLSessionTaskDelegate, Sendable {
    let expiry = OSAllocatedUnfairLock<Date?>(initialState: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let date = SecCertificateCopyNotValidAfterDate(leaf).map({ $0 as Date }) {
            expiry.withLock { $0 = date }
        }
        return (.performDefaultHandling, nil)
    }
}

// MARK: - Monitor

public nonisolated struct NetToysUptimeUpdate: Sendable {
    public let checkID: UUID
    public let sample: NetToysUptimeSample
    public let status: NetToysUptimeStatus
}

/// Runs the saved checks on their intervals inside the app's monitoring runtime, so checks run only
/// while the app runs and the Mac is awake. Checks only read, so Pause and safe mode do not stop them.
public actor NetToysUptimeMonitor {
    public static let shared = NetToysUptimeMonitor()
    static let flushInterval: TimeInterval = 60

    private let probe: @Sendable (NetToysUptimeCheck) async -> NetToysUptimeSample
    private var statuses: [UUID: NetToysUptimeStatus] = [:]
    private var nextDue: [UUID: Date] = [:]
    private var pending: [String: [NetToysUptimeSample]] = [:]
    private var lastFlush = Date()
    private var subscribers: [UUID: AsyncStream<NetToysUptimeUpdate>.Continuation] = [:]
    private var runID: UUID?

    init(probe: @escaping @Sendable (NetToysUptimeCheck) async -> NetToysUptimeSample = UptimeProbe.run) {
        self.probe = probe
    }

    /// Live results of every check, for the tool page. Ends when the caller stops reading.
    public func updates() -> AsyncStream<NetToysUptimeUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetToysUptimeUpdate.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    public func statuses(for ids: [UUID]) -> [UUID: NetToysUptimeStatus] { statuses.filter { ids.contains($0.key) } }

    /// Runs one check now, outside its interval; the result counts like a scheduled one.
    @discardableResult
    public func checkNow(_ check: NetToysUptimeCheck, notify: @Sendable (NetToysAlert) -> Void = NetToysNotifier.post)
        async -> NetToysUptimeSample {
        let sample = await probe(check)
        record(check, sample, notify: notify)
        nextDue[check.id] = sample.date.addingTimeInterval(check.interval)
        return sample
    }

    /// Loops until cancelled. A second call takes over from the first.
    public func run(paths: NetToysRuntimePaths = .standard,
                    notify: @escaping @Sendable (NetToysAlert) -> Void = NetToysNotifier.post) async {
        let id = UUID()
        runID = id
        defer { flush(paths: paths, now: Date()) }
        var stamp: Date?, checks: [NetToysUptimeCheck] = []
        while !Task.isCancelled, runID == id {
            // Decode the checks only after the file changes.
            let modified = try? paths.uptimeChecks.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified != stamp || modified == nil { checks = NetToysUptimeChecks.load(paths: paths); stamp = modified }
            await tick(checks: checks, now: Date(), paths: paths, notify: notify)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func tick(checks: [NetToysUptimeCheck], now: Date, paths: NetToysRuntimePaths,
              notify: @escaping @Sendable (NetToysAlert) -> Void) async {
        let enabled = checks.filter(\.isEnabled)
        let ids = Set(enabled.map(\.id))
        statuses = statuses.filter { ids.contains($0.key) }
        nextDue = nextDue.filter { ids.contains($0.key) }
        let due = enabled.filter { (nextDue[$0.id] ?? .distantPast) <= now }
        for check in due { nextDue[check.id] = now.addingTimeInterval(check.interval) }
        if !due.isEmpty {
            let probe = probe
            let results = await withTaskGroup(of: (NetToysUptimeCheck, NetToysUptimeSample).self) { group in
                for check in due { group.addTask { (check, await probe(check)) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            for (check, sample) in results { record(check, sample, notify: notify) }
        }
        if now.timeIntervalSince(lastFlush) >= Self.flushInterval {
            flush(paths: paths, now: now, keeping: Set(checks.map(\.id.uuidString)))
        }
    }

    private func record(_ check: NetToysUptimeCheck, _ sample: NetToysUptimeSample,
                        notify: @Sendable (NetToysAlert) -> Void) {
        var status = statuses[check.id] ?? NetToysUptimeStatus()
        let alerts = status.observe(sample, check: check)
        statuses[check.id] = status
        pending[check.id.uuidString, default: []].append(sample)
        alerts.forEach(notify)
        let update = NetToysUptimeUpdate(checkID: check.id, sample: sample, status: status)
        for continuation in subscribers.values { continuation.yield(update) }
    }

    private func flush(paths: NetToysRuntimePaths, now: Date, keeping ids: Set<String>? = nil) {
        lastFlush = now
        guard !pending.isEmpty else { return }
        let keep = ids ?? Set(NetToysUptimeChecks.load(paths: paths).map(\.id.uuidString))
        if (try? NetToysUptimeResults.append(pending, keeping: keep, at: paths.uptimeResults, now: now)) != nil {
            pending = [:]
        } else if pending.values.reduce(0, { $0 + $1.count }) > 10_000 {
            pending = [:] // The disk refuses writes; do not grow memory without end.
        }
    }
}
