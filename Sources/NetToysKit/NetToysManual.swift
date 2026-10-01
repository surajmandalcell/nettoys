public struct NetToysManualSection: Sendable {
    public let title: String
    public let points: [String]
}

public enum NetToysManual {
    public static let sections = [
        NetToysManualSection(title: "IP Scanner", points: [
            "Enter one address, a range, a CIDR block, or a list of addresses.",
            "Choose TCP ports, then scan. Filter, select, copy, rescan, or export the results."
        ]),
        NetToysManualSection(title: "SSH Anchor", points: [
            "Choose an explicit host and port from ~/.ssh/config.",
            "SSH Anchor checks that port every 2 to 3 seconds. If the address stops working, it searches the local subnet on only that port.",
            "Enrollment gives every grouped alias one stable host-key identity and accepts only its first key automatically.",
            "Enable Automatically installs your public key once so SSH stays key-only after address changes.",
            "A successful recovery changes only the HostName value in the selected host block."
        ]),
        NetToysManualSection(title: "Network History", points: [
            "Network History records gateway and internet state changes.",
            "The bundled NetToys Helper runs while either host requests monitoring."
        ])
    ]
}
