import Foundation
import Observation

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
    /// The download value while the test runs.
    private(set) var liveMbps: Double?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults, phase: Phase = .idle, liveMbps: Double? = nil) {
        self.defaults = defaults
        self.phase = phase
        self.liveMbps = liveMbps
        lastMbps = defaults.object(forKey: Self.lastKey) as? Double
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func start() {
        guard !isRunning else { return }
        let process = Process()
        // networkQuality prints live values only to a terminal; `script` gives it one. Stopping `script` stops it.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/networkQuality", "-u", "-M", "\(Int(Self.maximumSeconds))"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        liveMbps = nil
        phase = .running(started: Date())
        Task {
            let text = await Task.detached(priority: .utility) { () -> String? in
                do { try process.run() } catch { return nil }
                var text = ""
                while let chunk = try? output.fileHandleForReading.read(upToCount: 4_096), !chunk.isEmpty {
                    text += String(decoding: chunk, as: UTF8.self)
                    if text.utf8.count > 262_144 { text = String(text.suffix(4_096)) }
                    if let mbps = Self.downloadMbps(text) {
                        Task { @MainActor in if self.process === process { self.liveMbps = mbps } }
                    }
                }
                process.waitUntilExit()
                return text
            }.value
            guard self.process === process else { return }
            self.process = nil
            liveMbps = nil
            if let mbps = text.flatMap({ Self.downloadMbps($0, final: true) }) {
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
        liveMbps = nil
        phase = .idle
    }

    /// The newest download value in networkQuality's terminal output. Live lines read
    /// "Downlink: 286.335 Mbps, 52 RPM - Uplink: ..."; the summary reads "Downlink capacity: 11.385 Gbps".
    nonisolated static func downloadMbps(_ output: String, final: Bool = false) -> Double? {
        let lines = output.split(whereSeparator: \.isNewline)
        for line in lines.reversed() where line.contains(final ? "Downlink capacity:" : "Downlink") {
            let words = line.split(separator: " ")
            for index in words.indices.dropLast() {
                guard let value = Double(words[index]) else { continue }
                switch words[index + 1].trimmingCharacters(in: .punctuationCharacters) {
                case "Kbps": return value / 1_000
                case "Mbps": return value
                case "Gbps": return value * 1_000
                default: continue
                }
            }
        }
        return nil
    }
}
