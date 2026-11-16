import Foundation
import Observation

/// Durations as the product writes them: full hours, then min, then sec ("1 hour 52 min", "45 sec").
nonisolated enum NetToysDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60
        if hours > 0 {
            let unit = hours == 1 ? "hour" : "hours"
            return minutes > 0 ? "\(hours) \(unit) \(minutes) min" : "\(hours) \(unit)"
        }
        return minutes > 0 ? "\(minutes) min" : "\(total) sec"
    }
}

/// Runs macOS `networkQuality` for a download test and keeps the last result.
@Observable
@MainActor
final class NetToysSpeedTest {
    enum Phase: Equatable {
        case idle
        case running(started: Date)
        case failed(String)
    }

    static let maximumSeconds: TimeInterval = 20
    private static let lastKey = "nettoys.speedTest.lastMbps"

    private(set) var phase = Phase.idle
    private(set) var lastMbps: Double?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults, phase: Phase = .idle) {
        self.defaults = defaults
        self.phase = phase
        lastMbps = defaults.object(forKey: Self.lastKey) as? Double
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func start() {
        guard !isRunning else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        // Download only, JSON output, capped run time.
        process.arguments = ["-u", "-c", "-M", "\(Int(Self.maximumSeconds))"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        phase = .running(started: Date())
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                do { try process.run() } catch { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            }.value
            guard self.process === process else { return }
            self.process = nil
            if process.terminationReason == .uncaughtSignal { phase = .idle; return }
            if let mbps = data.flatMap(Self.downloadMbps) {
                lastMbps = mbps
                defaults.set(mbps, forKey: Self.lastKey)
                phase = .idle
            } else {
                phase = .failed("The speed test did not finish.")
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        phase = .idle
    }

    /// `networkQuality -c` reports `dl_throughput` in bits per second.
    nonisolated static func downloadMbps(_ json: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let bits = (object["dl_throughput"] as? NSNumber)?.doubleValue, bits > 0
        else { return nil }
        return bits / 1_000_000
    }
}
