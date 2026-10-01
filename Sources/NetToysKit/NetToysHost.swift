import Foundation
import NetToysCore

@MainActor
public final class NetToysHost {
    public let id: NetToysHostID
    public let displayName: String
    public let requestsPermissions: Bool
    public let defaults: UserDefaults
    public let scannerDefaults: UserDefaults
    public let loginItems: NetToysLoginItemManager
    public let neighborService: NetToysNeighborServiceManager
    let localNetworkAccess: NetToysLocalNetworkAccess

    public init(id: NetToysHostID, requestsPermissions: Bool = true,
                defaults: UserDefaults = .standard, scannerDefaults: UserDefaults? = nil) {
        self.id = id
        displayName = id == .macPowerToys ? "MacPowerToys" : "NetToys"
        self.requestsPermissions = requestsPermissions
        self.defaults = defaults
        let shared = scannerDefaults ?? UserDefaults(suiteName: NetToysPreferences.suiteName)!
        self.scannerDefaults = shared
        if requestsPermissions { try? NetToysPreferences.migrate(legacy: defaults, shared: shared, host: id) }
        loginItems = NetToysLoginItemManager(host: id)
        neighborService = NetToysNeighborServiceManager(host: id, refreshOnInit: requestsPermissions)
        localNetworkAccess = NetToysLocalNetworkAccess(requestsPermissions: requestsPermissions)
    }
}
