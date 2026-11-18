import Foundation
import NetToysCore
import Observation

/// The manual speed test that the menu row and the Speed Test page share. Each finished run is saved
/// to the speed history, so both show the same last result.
@Observable
@MainActor
final class NetToysSpeedTest {
    enum Phase: Equatable {
        case idle
        case running(started: Date)
        case failed(String)
    }

    static let shared = NetToysSpeedTest()
    /// networkQuality's own limit; the public IP lookup adds a few seconds after it.
    static let maximumSeconds: TimeInterval = 30

    private(set) var phase = Phase.idle
    /// Every saved run, oldest first.
    private(set) var history: [NetToysSpeedRecord] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(history: [NetToysSpeedRecord]? = nil, phase: Phase = .idle) {
        self.phase = phase
        if let history { self.history = history } else { Task { await reload() } }
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var last: NetToysSpeedRecord? { history.last }

    func reload() async {
        history = await Task.detached(priority: .utility) { NetToysSpeedHistory.load() }.value
    }

    func start() {
        guard !isRunning else { return }
        phase = .running(started: Date())
        task = Task {
            do {
                let record = try await NetToysSpeedTestRunner.run(maximumSeconds: Int(Self.maximumSeconds))
                try? await Task.detached(priority: .utility) { try NetToysSpeedHistory.append(record) }.value
                await reload()
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                guard !Task.isCancelled else { phase = .idle; return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}
