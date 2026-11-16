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
- Look: "Dense pro" polish.
- Durations: full hours, "min", "sec", for example "1 hour 52 min".
- Motion: hover fades in, selection is instant. The menu panel grows from
  its menu bar icon. Pause all actions shows a note and dims the actions.
  All motion is fast and responsive.

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
