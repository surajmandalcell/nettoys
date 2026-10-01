import Foundation

public nonisolated struct NetToysNeighborServiceContract: Sendable {
    public let daemonPlistName: String
    public let machServiceName: String
    public let mainAppRequirement: String
    public let helperRequirement: String

    public init(host: NetToysHostID) {
        let service = host == .macPowerToys ? "com.surajmandal.macpowertoys.nettoys-neighbor" : "com.surajmandal.nettoys.neighbor"
        daemonPlistName = service + ".plist"
        machServiceName = service
        mainAppRequirement = "identifier \"\(host.rawValue)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
        helperRequirement = "identifier \"\(host.helperIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
    }
}

@objc public nonisolated protocol NetToysNeighborXPCProtocol {
    func neighborSnapshot(reply: @escaping (Data?, String) -> Void)
}

nonisolated enum NetToysNeighborXPCClient {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String: String], Never>?
        private var connection: NSXPCConnection?

        init(_ continuation: CheckedContinuation<[String: String], Never>) {
            self.continuation = continuation
        }

        func attach(_ connection: NSXPCConnection) {
            lock.lock()
            self.connection = connection
            lock.unlock()
        }

        func finish(_ value: [String: String]) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            let connection = self.connection
            self.connection = nil
            lock.unlock()
            connection?.invalidate()
            continuation.resume(returning: value)
        }
    }

    static func load(addresses: [IPv4Address], interfaceIndex: UInt32,
                     contract: NetToysNeighborServiceContract) async -> [String: String] {
        guard !addresses.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let connection = NSXPCConnection(machServiceName: contract.machServiceName, options: .privileged)
            reply.attach(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: NetToysNeighborXPCProtocol.self)
            connection.setCodeSigningRequirement(contract.helperRequirement)
            connection.interruptionHandler = { reply.finish([:]) }
            connection.invalidationHandler = { reply.finish([:]) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish([:]) }
                as? NetToysNeighborXPCProtocol
            proxy?.neighborSnapshot { data, _ in
                guard let data else { reply.finish([:]); return }
                let requested = Set(addresses.map(\.description))
                reply.finish(ARPTable.parseRoutingMessages(data, interfaceIndex: interfaceIndex)
                    .filter { requested.contains($0.key) })
            }
            if proxy == nil { reply.finish([:]) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { reply.finish([:]) }
        }
    }
}
