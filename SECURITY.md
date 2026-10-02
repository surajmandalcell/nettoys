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

- When a host moves, NetToys changes only that host's `HostName` line in
  `~/.ssh/config`. It keeps a private backup and verifies the new address.
  Setup may add one marked host-key policy block so an address change does
  not trigger a prompt. A changed host key still stops the connection.
- The neighbor helper is a signed launch daemon. It answers only signed
  NetToys clients over XPC and returns the system neighbor table. It takes no
  arguments.
- Wi-Fi Priority stores no Wi-Fi passwords. It joins networks that macOS
  already knows.
- Scans and SSH Anchor run only on networks you choose.
