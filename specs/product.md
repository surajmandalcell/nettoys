# Product scope

Owner decisions of 2026-11-16. Visual polish, motion, and the menu bar
panel details are still open (redesign in progress).

## Concept

- Device inventory: the home is All Devices, a table of every device on
  the network. Sidebar groups: Devices (All devices, Favorites, Offline)
  and Tools (SSH Anchor, Wi-Fi Priority, History). No "Kinds" group, and
  no "New" sidebar item or in-window new-device banner; new devices are
  announced by a macOS notification only.
- Main window: sidebar, with an inspector that opens on demand.
- Menu bar panel: the "State headline" variant of "Status and actions".
  Pause all actions is a large play/pause button at the top right. During
  an outage it says which priority network it is joining next. The bottom
  button stays "Open Sam's NetToys".
- Panel layout: "Headline with auto-join". During an outage it shows
  "Joining <next network> in 45 sec" with Join Now and Stay on <current>.
  Action buttons: Run Speed Test and Copy IP Address only.
- Device modal: a centered, tall single column (about 440 pt) over the
  blurred, dimmed window. Header: name in SF Pro Display 20 pt semibold
  with a star, one status line (status, IP, vendor), a small close button.
  Actions: a row of small capsule push buttons (Wake Device, Open SSH,
  Copy IP Address) and a "..." menu (Add to SSH Anchor, Copy MAC Address,
  Forget Device). Sections: Details, Open ports (watch switches),
  Latency (average first, 24 hours), Alerts, Comment.
- Panel header: no status dot anywhere (owner dislikes it). The state
  shows either as a tinted state button (green, amber, gray paused, red
  with "!" that opens failure details) or as a state row in the action
  list (choice open).
- Panel bottom: Wi-Fi-menu-style rows with round icon wells. "Run Speed
  Test" runs inside its row (progress ring, live "Download 286 Mbps",
  Stop); when idle it shows the last result, such as "Last 412 Mbps".
  "Copy IP Address" shows the address as its value. Then menu rows "Open
  Sam's NetToys" (⌘O) and "Settings…" (⌘,). One content edge, nested
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
