import NetToysCore
import Observation
import ServiceManagement

/// Runs SSH Anchor, Wi-Fi Priority, and Network History inside the app and opens the app at login.
/// Quitting the app stops monitoring.
@Observable
@MainActor
public final class NetToysLoginItemManager {
    private let host: NetToysHostID
    public private(set) var errorMessage: String?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var monitorGeneration = 0

    public init(host: NetToysHostID) {
        self.host = host
    }

    public func setEnabled(_ enabled: Bool) async -> Bool {
        errorMessage = nil
        let host = host
        do {
            // The store transaction waits on a cross-process file lock, so it never runs on the main thread.
            _ = try await Task.detached(priority: .userInitiated) {
                try NetToysConfigurationStore.setBackgroundRequest(enabled, for: host)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if enabled { startMonitoring() } else { await stopMonitoring() }
        let app = SMAppService.mainApp
        do {
            if enabled, app.status != .enabled { try app.register() }
            if !enabled, app.status != .notRegistered, app.status != .notFound { try await app.unregister() }
            if enabled, app.status == .requiresApproval {
                errorMessage = "Allow Sam's Network Utilities in System Settings > General > Login Items to start it at login."
            }
        } catch {
            errorMessage = "Sam's Network Utilities could not change its login item: \(error.localizedDescription)"
        }
        return true
    }

    /// Runs while monitoring is on. The process lock keeps a second monitor, such as an older
    /// MacPowerToys helper, from writing the same SSH config at the same time.
    public func startMonitoring() {
        guard monitor == nil else { return }
        monitorGeneration += 1
        let generation = monitorGeneration
        let host = host
        monitor = Task { [weak self] in
            await Self.removeLegacyServices()
            let runtime = NetToysHelperRuntime(owner: host)
            var location: NetToysHelperLocationAccess?
            while !Task.isCancelled {
                let (requested, lock) = await Task.detached(priority: .utility) {
                    NetToysConfigurationStore.load().backgroundRequests.contains(host)
                        ? (true, try? NetToysProcessLock()) : (false, nil)
                }.value
                guard requested else { break }
                guard let lock else { try? await Task.sleep(for: .seconds(30)); continue }
                if location == nil {
                    location = NetToysHelperLocationAccess { state in Task { await runtime.setSSIDAccess(state) } }
                    location?.start()
                }
                await runtime.run()
                withExtendedLifetime(lock) {}
            }
            if self?.monitorGeneration == generation { self?.monitor = nil }
        }
    }

    private func stopMonitoring() async {
        let running = monitor
        monitor = nil
        running?.cancel()
        await running?.value
    }

    /// Builds up to 1.0.10 registered a separate login helper and a root neighbor daemon.
    private nonisolated static func removeLegacyServices() async {
        for service in [SMAppService.loginItem(identifier: "com.surajmandal.nettoys.helper"),
                        .daemon(plistName: "com.surajmandal.nettoys.neighbor.plist")]
        where service.status != .notRegistered {
            try? await service.unregister()
        }
    }
}
