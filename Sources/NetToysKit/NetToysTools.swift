import Foundation

/// One tool in the sidebar, the command palette, `nettoys://tool/<id>` routes, and the Raycast extension.
/// Add a tool with one line in `all`; give it a view with one `case` in `NetToysWindowView.toolView`.
public struct NetToysTool: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case diagnose = "Diagnose"
        case monitor = "Monitor"
        case localNetwork = "Local Network"
        case wifi = "Wi-Fi"
    }

    public let id: String
    public let name: String
    public let symbol: String
    public let line: String
    public let group: Group
    /// The toolbar field prompt; nil when the tool takes no input.
    public let input: String?

    public static let all: [NetToysTool] = [
        // Diagnose
        .init(id: "ping", name: "Ping", symbol: "waveform.path.ecg", line: "Live round trip and loss", group: .diagnose, input: "Host or IP address"),
        .init(id: "traceroute", name: "Traceroute", symbol: "point.topleft.down.to.point.bottomright.curvepath", line: "Every hop, live MTR and map", group: .diagnose, input: "Host or IP address"),
        .init(id: "dns-lookup", name: "DNS Lookup", symbol: "text.magnifyingglass", line: "A, AAAA, MX, TXT, NS records", group: .diagnose, input: "Domain"),
        .init(id: "dns-propagation", name: "DNS Propagation", symbol: "globe", line: "One name on 16 public resolvers", group: .diagnose, input: "Domain"),
        .init(id: "whois", name: "Whois", symbol: "person.text.rectangle", line: "Who owns a domain or IP", group: .diagnose, input: "Domain or IP address"),
        .init(id: "port-scan", name: "Port Scan", symbol: "door.left.hand.open", line: "Open TCP ports on one host", group: .diagnose, input: "Host or IP address"),
        .init(id: "ssl-certificate", name: "SSL Certificate", symbol: "lock.shield", line: "Chain, names, days to expiry", group: .diagnose, input: "Domain"),
        .init(id: "http-check", name: "HTTP Check", symbol: "chevron.left.forwardslash.chevron.right", line: "Status, headers, redirects, timing", group: .diagnose, input: "URL"),
        .init(id: "geoip", name: "GeoIP", symbol: "mappin.and.ellipse", line: "Country, city, and network of an IP", group: .diagnose, input: "IP address"),
        .init(id: "path-mtu", name: "Path MTU", symbol: "ruler", line: "Biggest packet that gets through", group: .diagnose, input: "Host or IP address"),
        .init(id: "internet-check", name: "Internet Check", symbol: "checkmark.seal", line: "Router, DNS, and web, step by step", group: .diagnose, input: nil),
        .init(id: "subnet-calculator", name: "Subnet Calculator", symbol: "square.grid.3x3", line: "Range, mask, hosts of a CIDR", group: .diagnose, input: "CIDR, such as 192.168.1.0/24"),
        // Monitor
        .init(id: "uptime-monitor", name: "Uptime Monitor", symbol: "clock.badge.checkmark", line: "Checks on a schedule, alerts on down", group: .monitor, input: nil),
        .init(id: "speed-test", name: "Speed Test", symbol: "speedometer", line: "History, schedule, ISP report", group: .monitor, input: nil),
        .init(id: "network-monitor", name: "Network Monitor", symbol: "chart.xyaxis.line", line: "Live traffic per interface", group: .monitor, input: nil),
        .init(id: "network-guard", name: "Network Guard", symbol: "bell.badge", line: "Alert when a new device joins", group: .monitor, input: nil),
        .init(id: "history", name: "History", symbol: "clock.arrow.circlepath", line: "Outages, joins, and actions", group: .monitor, input: nil),
        // Local Network
        .init(id: "all-devices", name: "All Devices", symbol: "desktopcomputer", line: "Every device on the network", group: .localNetwork, input: nil),
        .init(id: "bonjour-browser", name: "Bonjour Browser", symbol: "bonjour", line: "Services that devices announce", group: .localNetwork, input: nil),
        .init(id: "wake-on-lan", name: "Wake-on-LAN", symbol: "power", line: "Wake a sleeping device", group: .localNetwork, input: "MAC address"),
        .init(id: "arp-table", name: "ARP Table", symbol: "tablecells", line: "IP to MAC address pairs", group: .localNetwork, input: nil),
        .init(id: "mac-vendor", name: "MAC Vendor", symbol: "barcode", line: "Maker of a MAC address", group: .localNetwork, input: "MAC address"),
        .init(id: "my-connection", name: "My Connection", symbol: "cable.connector", line: "Public IP, interfaces, router, DNS", group: .localNetwork, input: nil),
        .init(id: "ipv6-check", name: "IPv6 Check", symbol: "6.circle", line: "IPv6 address and reach", group: .localNetwork, input: nil),
        .init(id: "clock-check", name: "Clock Check", symbol: "clock", line: "Mac clock offset from NTP", group: .localNetwork, input: "NTP server"),
        .init(id: "ssh-anchor", name: "SSH Anchor", symbol: "terminal", line: "Keeps SSH hosts on their new IP", group: .localNetwork, input: nil),
        // Wi-Fi
        .init(id: "wifi-analyzer", name: "Wi-Fi Analyzer", symbol: "wifi", line: "Channels and the best one to use", group: .wifi, input: nil),
        .init(id: "wifi-signal", name: "Wi-Fi Signal", symbol: "antenna.radiowaves.left.and.right", line: "Live signal, noise, rate", group: .wifi, input: nil),
        .init(id: "wifi-priority", name: "Wi-Fi Priority", symbol: "list.number", line: "Auto-join order and switch", group: .wifi, input: nil),
    ]

    public static func tool(_ id: String) -> NetToysTool? { all.first { $0.id == id } }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query) || line.localizedCaseInsensitiveContains(query)
    }
}

public extension NetToysPage {
    /// The sidebar selection that shows this page: a tool id, or `settings` / `how-to-use`.
    var selectionID: String {
        switch self {
        case .scanner: "all-devices"
        case .anchor: "ssh-anchor"
        case .wifiPriority: "wifi-priority"
        case .history: "history"
        case .settings: "settings"
        case .howToUse: "how-to-use"
        }
    }
}
