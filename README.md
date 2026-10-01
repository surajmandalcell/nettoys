# NetToys

NetToys runs as a standalone macOS app and as a MacPowerToys package.
Both apps use the same IP Scanner, SSH Anchor, Wi-Fi Priority, Network
History, settings, manual, and menu content.

Requires macOS 15 or later and Swift 6.2 or later.

```sh
swift test --jobs 2
swift build --product NetToys --jobs 2
make build
```

`make build` packages `.build/NetToys.app` from clean committed source,
records its full revision in `NetToysSourceCommit`, and verifies its
signature. Its default ad hoc signature needs no signing account. For a
local Apple Development build, set `SIGNING_IDENTITY` to the configured
identity for team `GF57JXJF5A`. This command does not install or launch the
app. Public distribution needs a separate Developer ID and notarization
step.

The package exports `NetToysCore` and `NetToysKit`. The core has no
SwiftUI dependency. The kit uses OnePlusUI 1.0.0 and exposes configured
window, settings, and menu entry points. MacPowerToys retains its own
routing, tool enablement, and fan daemon.

`make build` embeds the standalone login helper, neighbor-only daemon
plist, resource bundles, approved icon, MIT license, and IEEE notice.
Both app and helper carry their own full source revision and package
version. The IEEE vendor registry has separate terms in its notice.

Both hosts keep data at `~/Library/Application Support/MacPowerToys/NetToys`.
One private lifetime lock allows one user monitor. Each host records its
own monitoring request. Quitting preserves that request; disabling removes
only that host's request. No requests stops monitoring. A separate store
lock protects short atomic data updates. Shared scanner preferences use
`com.surajmandal.nettoys.preferences`; app appearance, window position,
table columns, and menu disclosures remain with each host.

Allow Local Network access for scans and Location access for Wi-Fi names.
Settings shows recovery actions. A signed compatible helper can serve both
hosts. Take Over Helper asks the other running parent to release ownership;
it never launches that parent. Upgrade the old MacPowerToys helper before
standalone monitoring. A stale old heartbeat does not prove safe migration.

The standalone URL scheme is `nettoys://open/<page>`. Page IDs are
`scanner`, `ssh-anchor`, `wifi`, `history`, `settings`, and `how-to-use`.
Scanner URLs accept bounded `targets` and `ports` query values.

Tests use synthetic network/SSH files, defaults suites, and lock directories.
Package tests render native tables offscreen. Signed helper, permission,
handoff, and installed-app acceptance runs in an isolated macOS session.

MIT licensed. Copyright 2026 Suraj Mandal.
