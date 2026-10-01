import Foundation

public nonisolated struct NetToysScanPrefill: Equatable, Sendable {
    public let targets: String
    public let ports: String?

    public init(targets: String, ports: String?) {
        self.targets = targets
        self.ports = ports
    }

    public static func parse(_ url: URL, schemes: Set<String> = ["macpowertoys", "powertoys"],
                              toolPath: String? = "nettoys") -> Self? {
        guard let scheme = url.scheme, schemes.contains(scheme), url.host == "open",
              toolPath == nil || url.pathComponents.first(where: { $0 != "/" }) == toolPath,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let targetValue = items.first(where: { $0.name == "targets" })?.value else { return nil }
        let targets = targetValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targets.isEmpty, targets.utf8.count <= 8_192,
              (try? NetToysTargetInput.parse(targets)) != nil else { return nil }
        let ports = items.first(where: { $0.name == "ports" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ports?.utf8.count ?? 0 <= 4_096,
              ports.map({ (try? PortList.parse($0)) != nil }) ?? true else { return nil }
        return Self(targets: targets, ports: ports)
    }
}
