# Safety, performance, and testing

Owner decisions of 2026-11-16. All sections are in the code except the
Docker lab.

## No privileged parts

- Drop the root neighbor daemon. macOS 27 hides the neighbor table from
  normal processes (the routing sysctl returns 0 entries), but the platform
  tool `/usr/sbin/arp -an` still lists MAC addresses as the user. Read MACs
  by running that tool, as Angry IP Scanner does.
- Drop the separate login helper. The app itself is a menu bar app that
  starts at login (`SMAppService.mainApp`) and keeps running when its
  window closes. Quitting the app stops monitoring.

## Performance

- Scans adapt: start at 64 probes at once, rise to 256 while timeouts stay
  low, back off when they rise. No fixed packet rate cap. The limits are the
  Mac's (open sockets, Wi-Fi airtime), not the router's.
- Cap scan memory and the scan archive by size, not only by run count.
  The archive cap is 8 MB. A running scan keeps 16 MB of results; past
  that it drops addresses that did not answer and keeps every device.
- Latency history (gateway and devices, from checks and scans): 24 hours,
  512 KB cap, oldest first, in `latency.json`.
- Background network check every 30 s, every 60 s on battery. SSH Anchor
  probe every 5 s.
- Pings never spawn `ping`: one shared unprivileged ICMP datagram socket
  in process serves every target.

## Guardrails

- SSH config writes: automatic with Undo. Search only the home network.
  Accept a moved host only with proof by MAC address or SSH host key, never
  by an open port alone. Write atomically, sync the folder, and clean temp
  files on start. The home network is the subnet plus the router MAC,
  learned the first time the host answers at its saved address. Undo of
  an SSH move also turns that anchor off, so it does not move again.
- Backups tab: every SSH config change keeps a backup, per host, with
  periodic and incremental snapshots. Total cap 1 MB, oldest first.
  A change snapshot is the whole file before each change; a periodic
  snapshot is taken at most once a day when the file changed.
- Wi-Fi switch: automatic with cooldown. Defaults: wait 60 s after wake,
  rest 10 min after a switch, Undo. Both values are settings. Use a
  monotonic clock, reset the outage timer on wake, and do not count leaving
  a network on purpose as an outage.
- Scan range: any range, no warning, no extra cap.
- Pause switch: "Pause all actions" stops every automatic change. Safe mode
  starts by itself after 3 failed actions in 10 minutes. Resume ends
  both. An action that pause, safe mode, or dry run holds is never
  marked done, so it runs when the hold ends.
- Action log: a file log of every automatic action, shown in History.
  30 days, 5 MB cap.
- A damaged history or scan file is kept aside, never silently replaced.

## Testing

- Quick tests with fakes on the Mac for the risky logic only: SSH write,
  host match, Wi-Fi switch timing, safe mode. Fake network, fake clock,
  fake Wi-Fi, and a temp home folder.
- A Docker lab on oci2 before release: hosts with sshd that change address,
  packet loss, and DHCP moves. It cannot test Wi-Fi joins or other macOS
  calls.
- A dry-run mode in the real app that logs what it would do and changes
  nothing.
- Never a macOS virtual machine.
