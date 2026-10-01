import Observation
import NetToysCore
import ServiceManagement

@Observable
@MainActor
public final class NetToysNeighborServiceManager {
    private let service: SMAppService
    public private(set) var revision = 0
    public private(set) var errorMessage: String?
    public private(set) var status: SMAppService.Status?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let readStatus: @Sendable () -> SMAppService.Status

    public init(host: NetToysHostID, refreshOnInit: Bool = true,
                readStatus: (@Sendable () -> SMAppService.Status)? = nil) {
        let contract = NetToysNeighborServiceContract(host: host)
        service = .daemon(plistName: contract.daemonPlistName)
        self.readStatus = readStatus ?? { SMAppService.daemon(plistName: contract.daemonPlistName).status }
        if refreshOnInit { refresh() }
    }

    public var isEnabled: Bool { status == .enabled }

    @discardableResult
    public func enable(openSettings: Bool = true) -> Bool {
        refreshTask?.cancel()
        refreshTask = nil
        errorMessage = nil
        do {
            let current = service.status
            if current == .notRegistered || current == .notFound { try service.register() }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = service.status
        revision &+= 1
        guard status == .enabled else {
            if errorMessage == nil {
                errorMessage = status == .requiresApproval
                    ? "Allow MAC Address Access in System Settings > Login Items."
                    : "macOS could not start MAC Address Access."
            }
            if openSettings { SMAppService.openSystemSettingsLoginItems() }
            return false
        }
        return true
    }

    public func refresh() {
        guard refreshTask == nil else { return }
        let readStatus = readStatus
        refreshTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility, operation: readStatus).value
            guard !Task.isCancelled, let self else { return }
            self.status = status
            self.revision &+= 1
            self.refreshTask = nil
        }
    }

    public func restart() async throws {
        refreshTask?.cancel()
        refreshTask = nil
        defer { refresh() }
        try await service.unregister()
        try service.register()
    }
}
