# Product scope

Owner decisions of 2026-11-16. The design is settled. Reference renders:
https://claude.ai/artifact/7XBPPhNa35523DhRbpbxvN (older rounds in its
version history).

## Concept

- Device inventory: the home is All Devices, a table of every device on
  the network. Sidebar groups: Devices (All devices, Favorites, Offline)
  and Tools (SSH Anchor, Wi-Fi Priority, History). No "Kinds" group, and
  no "New" sidebar item or in-window new-device banner; new devices are
  announced by a macOS notification only.
- Main window: sidebar; device details open in a centered modal.
- Panel layout: "Headline with auto-join". During an outage it shows
  "Joining <next network> in 45 sec" with Join Now and Stay on <current>.
  Action buttons: Run Speed Test and Copy IP Address only.
- Device modal: a centered, tall single column (about 480 pt) over the
  blurred, dimmed window. Header: name in SF Pro Display 20 pt semibold
  with a star, one status line (status, IP, vendor), a small close button.
  Actions: a row of small capsule push buttons (Wake Device, Open SSH,
  Copy IP Address) and a "..." menu (Add to SSH Anchor, Copy MAC Address,
  Forget Device). Sections: Details, Open ports (watch switches),
  Latency (average first, 24 hours), Alerts, Comment.
- Panel header: no status dot and no pause button. The headline and the
  subtitle (network, IP, latency) only.
- System row, below Copy IP Address, in the same row style. The icon well
  tint carries the state; the whole row does its trailing blue action:
  Running "System Up · Pause", Warning "System Up, 1 Warning · Details",
  Paused "System Paused · Resume", Failed "System Failed · Details".
  Details opens the app window on the failure.
- Panel bottom: Wi-Fi-menu-style rows with round icon wells. "Run Speed
  Test" runs inside its row (progress ring, live "Download 286 Mbps",
  Stop); when idle it shows the last result, such as "Last 412 Mbps".
  "Copy IP Address" shows the address as its value. Then menu rows "Open
  Sam's Network Utilities" (⌘O) and "Settings…" (⌘,). One content edge, nested
  corners, a material surface, 0.5 pt hairlines.
- Look: "Dense pro" polish.
- Durations: full hours, "min", "sec", for example "1 hour 52 min".
- Motion: hover fades in, selection is instant. The menu panel grows from
  its menu bar icon. Pause all actions dims the actions quietly, with no
  note bar in the window. Scan: a 1 pt progress line and a count, rows
  fade in over 80 ms. Device modal: scale and blur in (about 180 ms).
  Filter: rows that do not match fade out, then the rest glide into place
  fast. All motion is fast and responsive.

## Features

- Keep: IP Scanner, SSH Anchor, Wi-Fi Priority, Network History, menu bar.
- Add now:
  - Stay online: outage alert, latency graph, DNS check, speed test
    (macOS `networkQuality`).
  - Devices: new device alert, Wake-on-LAN, port watch.
  - History: SSH Anchor moves in the timeline.
- Cut: weekly summary, four of the six export formats (CSV and JSON stay),
  and the How to use page (short tips on empty pages replace it).

## Look

- App icon: keep `Assets/NetToysLogo.png`.
- The main window is large: the scanner table needs room for many columns.

## Utilities expansion (owner, 2026-11-18)

Renders: https://claude.ai/artifact/JtbRQVx3AjXGnEv93ZYrpK

- Features: the full set of 29 tools, no free or Pro split, in four
  sidebar groups:
  - Diagnose: Ping, Traceroute (with MTR and a map), DNS Lookup, DNS
    Propagation (16 public resolvers), Whois, Port Scan (TCP connect), SSL
    Certificate, HTTP Check, GeoIP, Path MTU, Internet Check, Subnet
    Calculator.
  - Monitor: Uptime Monitor (schedule, down alerts, latency thresholds,
    SSL expiry), Speed Test (history, schedule, ISP report), Network
    Monitor (traffic per interface), Network Guard, History.
  - Local Network: All Devices, Bonjour Browser, Wake-on-LAN, ARP Table,
    MAC Vendor, My Connection (public IP, interfaces, router, DNS), IPv6
    Check, Clock Check (NTP offset), SSH Anchor.
  - Wi-Fi: Wi-Fi Analyzer (channels, best channel), Wi-Fi Signal, Wi-Fi
    Priority.
  macOS blocks SYN scan, OS guess, packet capture, channel load, and
  traffic per app; those are out. Renderer source of the settled design:
  `/Volumes/External1TB/data/_custom/claude/nettoys/design-ref/src/`.
- Sidebar: search field at top, then Pinned (tools only, drag to reorder;
  hidden when nothing is pinned), then the tool groups. No Recent section
  and no history entries (hosts, domains) in the sidebar. A pinned tool
  is not repeated elsewhere.
- Sidebar look: inspired by Mail (option 8 of round 12): Dense pro, glass
  sidebar, monochrome symbols.
- Command palette: both ⌘K in the window and ⌥Space from any app, plus a
  Raycast extension. Look: Xcode Open Quickly style, compact rows,
  monochrome symbols.
- Motion: snappy spring (response 0.30 s, damping 0.86) everywhere. Every
  expand and collapse in the app animates with it.
- Tool page: path diagram on top of the hop table. Long paths fold quiet
  hops into one "+N" stop; a click opens the full path wrapped into rows
  (a snake with rounded bends), with a control to fold it again. Look:
  "Quiet rings" (round 13 option 3). Fold and expand motion: "Line draws
  through" (320 ms line draw, snappy spring), but the rings settle with
  no overshoot, bounce, or bob.
- All 29 tools use the same tool page: a summary or diagram on top, the
  result table below.
