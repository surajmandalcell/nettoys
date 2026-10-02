import Foundation
import NetToysCore

final class NetToysNeighborDaemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = NetToysNeighborService()
    private let idleExit = NetToysDaemonIdleExit()

    static func run() -> Never {
        let contract = NetToysNeighborServiceContract(host: .standalone)
        let delegate = NetToysNeighborDaemon()
        let listener = NSXPCListener(machServiceName: contract.machServiceName)
        listener.setConnectionCodeSigningRequirement(contract.mainAppRequirement)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
        fatalError("NetToys neighbor daemon stopped")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NetToysNeighborXPCProtocol.self)
        connection.exportedObject = service
        idleExit.track(connection)
        connection.resume()
        return true
    }
}

final class NetToysNeighborService: NSObject, NetToysNeighborXPCProtocol, @unchecked Sendable {
    func neighborSnapshot(reply: @escaping (Data?, String) -> Void) {
        reply(ARPTable.neighborCacheData(), Bundle.main.object(forInfoDictionaryKey: "NetToysSourceCommit") as? String ?? "")
    }
}
