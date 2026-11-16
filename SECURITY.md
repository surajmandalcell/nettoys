# Security Policy

## Supported versions

Security fixes go into the latest release and the current `main` branch.

## Reporting a vulnerability

Use GitHub's private **Report a vulnerability** form in the repository's
Security tab. Do not open a public issue for an unpatched vulnerability.

Include the affected version, macOS version, impact, and steps to reproduce.
Do not include real SSH configurations, host keys, network names, addresses,
or scan results. You should receive a reply within seven days.

## Security boundaries

- When a host moves, Sam's NetToys changes only that host's `HostName` line in
  `~/.ssh/config`. It searches only the host's home network and accepts the
  new address only when the device shows a MAC address it already knows or
  the same SSH host key; a matching name with an open port is not enough.
  It keeps private backups (per host, 1 MB in total), logs every change, and
  can undo it. Setup may add one marked host-key policy block so an address
  change does not trigger a prompt. A changed host key still stops the
  connection.
- Sam's NetToys has no privileged or separate background parts. It runs as
  you, reads neighbor MAC addresses with `/usr/sbin/arp -an`, and monitors
  only while the app runs.
- Wi-Fi Priority stores no Wi-Fi passwords. It joins networks that macOS
  already knows.
- Scans and SSH Anchor run only on networks you choose.
