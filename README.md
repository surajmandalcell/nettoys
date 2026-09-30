# NetToys

NetToys will run as a standalone macOS app and as a MacPowerToys package.
This phase 1 scaffold builds a native app shell. The working IP Scanner,
SSH Anchor, Wi-Fi Priority, Network History, and helpers remain in
MacPowerToys until the phase 2 move.

Requires macOS 15 or later and Swift 6.2 or later.

```sh
swift build --product NetToys
make build
```

`make build` packages `.build/NetToys.app` from clean committed source,
records its full revision in `NetToysSourceCommit`, and verifies its
signature. Its default ad hoc signature needs no signing account. For a
local Apple Development build, set `SIGNING_IDENTITY` to the configured
identity for team `GF57JXJF5A`. This command does not install or launch the
app. Public distribution needs a separate Developer ID and notarization
step.

The package exports `NetToysKit`; `Sources/NetToysApp` consumes it.
`packaging/macos` holds the app metadata and entitlements. The shell has
no background tasks, helper registration, network requests, or permission
requests. It has no OnePlusUI dependency yet, so it builds independently
before that package's first tag exists.

Phase 2 adds `NetToysCore` for shared network code and helper runtime,
moves the current UI into `NetToysKit`, and adds standalone helper targets.
Both NetToys and MacPowerToys will use `surajmandalcell/oneplus-ui` at
`1.0.0`; MacPowerToys will use a reviewed NetToys version tag. The
orchestrator owns public repository creation, pushes, and tags.

MIT licensed. Copyright 2026 Suraj Mandal.
