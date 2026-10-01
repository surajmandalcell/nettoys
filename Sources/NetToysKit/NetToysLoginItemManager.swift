import AppKit
import NetToysCore
import Observation
import ServiceManagement

@Observable
@MainActor
public final class NetToysLoginItemManager {
    private let host: NetToysHostID
    private let service: SMAppService
    public private(set) var errorMessage: String?
    @ObservationIgnored private var handoffObserver: NSObjectProtocol?
    private static let handoffNotification = Notification.Name("netToysReleaseOwner")

    public init(host: NetToysHostID) {
        self.host = host
        service = .loginItem(identifier: host.helperIdentifier)
        handoffObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.handoffNotification, object: host.rawValue, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in await self?.releaseForHandoff() } }
    }

    isolated deinit {
        if let handoffObserver { DistributedNotificationCenter.default().removeObserver(handoffObserver) }
    }

    public var status: SMAppService.Status { service.status }

    public nonisolated static func hasFreshHeartbeat(_ status: NetToysHelperStatus?, now: Date = Date(),
                                                     expectedSourceCommit: String? = nil) -> Bool {
        NetToysHelperIdentity.hasFreshHeartbeat(status, now: now, expectedSourceCommit: expectedSourceCommit)
    }

    public func setEnabled(_ enabled: Bool) async -> Bool {
        errorMessage = nil
        do {
            let requests = try NetToysConfigurationStore.setBackgroundRequest(enabled, for: host).backgroundRequests
            if !enabled {
                let owner = NetToysConfigurationStore.status()?.ownerBundleID
                if owner != host.rawValue || requests.isEmpty { try await unregister() }
                return true
            }
            if await enable() { return true }
            try NetToysConfigurationStore.setBackgroundRequest(false, for: host)
        } catch {
            errorMessage = error.localizedDescription
            if !enabled { try? NetToysConfigurationStore.setBackgroundRequest(true, for: host) }
        }
        return false
    }

    /// Explicit user action. The signed parent must be running; no parent is launched.
    public func takeOwnership() async -> Bool {
        guard let status = NetToysConfigurationStore.status(),
              let owner = status.ownerBundleID.flatMap(NetToysHostID.init(rawValue:)), owner != host else {
            return await setEnabled(true)
        }
        let request = NetToysHandoff(requester: host, owner: owner)
        do {
            try request.save()
            DistributedNotificationCenter.default().postNotificationName(Self.handoffNotification,
                object: owner.rawValue, userInfo: nil, deliverImmediately: true)
            while Date() < request.expires, !Task.isCancelled {
                if let response = NetToysHandoff.load(), response.isValidResponse(to: request),
                   !NetToysProcessLock.isHeld() { return await setEnabled(true) }
                try await Task.sleep(for: .milliseconds(250))
            }
            errorMessage = "Open the other NetToys host and disable its helper, then try again."
        } catch { errorMessage = error.localizedDescription }
        return false
    }

    private func releaseForHandoff() async {
        guard var request = NetToysHandoff.load(), request.isValidRequest(for: host)
        else { return }
        do {
            try await unregister()
            request.releasedByPID = ProcessInfo.processInfo.processIdentifier
            try request.save()
        } catch { errorMessage = error.localizedDescription }
    }

    private var embeddedRevision: String? {
        let name = host == .macPowerToys ? "MacPowerToysNetHelper" : "NetToysHelper"
        let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/\(name).app"))
        return (bundle?.object(forInfoDictionaryKey: "NetToysSourceCommit")
            ?? bundle?.object(forInfoDictionaryKey: "MPTSourceCommit")) as? String
    }

    private func enable() async -> Bool {
        let status = NetToysConfigurationStore.status()
        if NetToysHelperIdentity.isCompatible(status) {
            if status?.ownerBundleID != host.rawValue { try? await unregister(); return true }
            if Self.hasFreshHeartbeat(status, expectedSourceCommit: embeddedRevision) { return true }
        }
        if host == .standalone, !legacyHostIsLockAware() {
            errorMessage = "Update MacPowerToys to the extracted NetToys build before enabling this helper. Disable its old helper first."
            return false
        }
        if NetToysProcessLock.isHeld(), status?.ownerBundleID != host.rawValue {
            errorMessage = "Another NetToys helper owns monitoring. Use Take Over Helper while its parent app is open."
            return false
        }
        do {
            try await unregister()
            try service.register()
            if service.status == .requiresApproval {
                errorMessage = "Allow NetToys Helper in System Settings to enable monitoring."
                SMAppService.openSystemSettingsLoginItems()
            } else if service.status == .enabled {
                for _ in 0..<32 {
                    let current = NetToysConfigurationStore.status()
                    if NetToysHelperIdentity.isCompatible(current) {
                        if current?.ownerBundleID != host.rawValue { try? await unregister() }
                        return true
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                errorMessage = "NetToys Helper did not start. Check Background App Activity."
            } else { errorMessage = "macOS did not enable NetToys Helper." }
            try await unregister()
        } catch { errorMessage = error.localizedDescription; try? await unregister() }
        return false
    }

    private func legacyHostIsLockAware() -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: NetToysHostID.macPowerToys.helperIdentifier)
        let status = NetToysConfigurationStore.status()
        if !applications.isEmpty, !NetToysHelperIdentity.isCompatible(status) { return false }
        let url = URL(fileURLWithPath: "/Applications/MacPowerToys.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return applications.isEmpty }
        return NetToysHelperIdentity.isLockAwareHost(at: url)
    }

    private func unregister() async throws {
        if service.status != .notRegistered, service.status != .notFound { try await service.unregister() }
    }
}
