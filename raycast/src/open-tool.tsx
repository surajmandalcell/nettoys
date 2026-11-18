import { Action, ActionPanel, Icon, LaunchProps, List, open, closeMainWindow } from "@raycast/api";

// Mirrors NetToysTool.all in Sources/NetToysKit/NetToysTools.swift: id, name, one-line description, group.
const tools: [string, string, string, string][] = [
  ["ping", "Ping", "Live round trip and loss", "Diagnose"],
  ["traceroute", "Traceroute", "Every hop, live MTR and map", "Diagnose"],
  ["dns-lookup", "DNS Lookup", "A, AAAA, MX, TXT, NS records", "Diagnose"],
  ["dns-propagation", "DNS Propagation", "One name on 16 public resolvers", "Diagnose"],
  ["whois", "Whois", "Who owns a domain or IP", "Diagnose"],
  ["port-scan", "Port Scan", "Open TCP ports on one host", "Diagnose"],
  ["ssl-certificate", "SSL Certificate", "Chain, names, days to expiry", "Diagnose"],
  ["http-check", "HTTP Check", "Status, headers, redirects, timing", "Diagnose"],
  ["geoip", "GeoIP", "Country, city, and network of an IP", "Diagnose"],
  ["path-mtu", "Path MTU", "Biggest packet that gets through", "Diagnose"],
  ["internet-check", "Internet Check", "Router, DNS, and web, step by step", "Diagnose"],
  ["subnet-calculator", "Subnet Calculator", "Range, mask, hosts of a CIDR", "Diagnose"],
  ["uptime-monitor", "Uptime Monitor", "Checks on a schedule, alerts on down", "Monitor"],
  ["speed-test", "Speed Test", "History, schedule, ISP report", "Monitor"],
  ["network-monitor", "Network Monitor", "Live traffic per interface", "Monitor"],
  ["network-guard", "Network Guard", "Alert when a new device joins", "Monitor"],
  ["history", "History", "Outages, joins, and actions", "Monitor"],
  ["all-devices", "All Devices", "Every device on the network", "Local Network"],
  ["bonjour-browser", "Bonjour Browser", "Services that devices announce", "Local Network"],
  ["wake-on-lan", "Wake-on-LAN", "Wake a sleeping device", "Local Network"],
  ["arp-table", "ARP Table", "IP to MAC address pairs", "Local Network"],
  ["mac-vendor", "MAC Vendor", "Maker of a MAC address", "Local Network"],
  ["my-connection", "My Connection", "Public IP, interfaces, router, DNS", "Local Network"],
  ["ipv6-check", "IPv6 Check", "IPv6 address and reach", "Local Network"],
  ["clock-check", "Clock Check", "Mac clock offset from NTP", "Local Network"],
  ["ssh-anchor", "SSH Anchor", "Keeps SSH hosts on their new IP", "Local Network"],
  ["wifi-analyzer", "Wi-Fi Analyzer", "Channels and the best one to use", "Wi-Fi"],
  ["wifi-signal", "Wi-Fi Signal", "Live signal, noise, rate", "Wi-Fi"],
  ["wifi-priority", "Wi-Fi Priority", "Auto-join order and switch", "Wi-Fi"],
];

const groups = ["Diagnose", "Monitor", "Local Network", "Wi-Fi"];

function toolURL(id: string, host?: string) {
  const value = host?.trim();
  return `nettoys://tool/${id}${value ? `?host=${encodeURIComponent(value)}` : ""}`;
}

export default function Command(props: LaunchProps<{ arguments: { host?: string } }>) {
  const host = props.arguments.host;
  return (
    <List searchBarPlaceholder="Search 29 network tools">
      {groups.map((group) => (
        <List.Section key={group} title={group}>
          {tools
            .filter((tool) => tool[3] === group)
            .map(([id, name, line]) => (
              <List.Item
                key={id}
                title={name}
                subtitle={line}
                accessories={host ? [{ text: host }] : []}
                actions={
                  <ActionPanel>
                    <Action
                      title="Open in Sam's Network Utilities"
                      icon={Icon.ArrowNe}
                      onAction={async () => {
                        await closeMainWindow();
                        await open(toolURL(id, host));
                      }}
                    />
                    <Action.CopyToClipboard title="Copy Link" content={toolURL(id, host)} />
                  </ActionPanel>
                }
              />
            ))}
        </List.Section>
      ))}
    </List>
  );
}
