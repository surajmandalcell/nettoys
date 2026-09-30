# NetToys

Read `goals.md` when present. Work in this checkout on its current branch.
Use synthetic fixtures for SSH, network, and helper tests.

In the shared workspace, read `../powertoys/spec/troubleshoot/troubleshoot.md`
first, then its topics for system tools, UI chrome, and verification.
Shared rules live in `../powertoys/.agents/rules/`. Read code-style.md,
architecture.md, design-tokens.md, window-experience.md, and release.md for
their matching tasks. `../powertoys/DESIGN.md` owns the shared UI contract.
Use `../switch/AGENTS.md` for the synthetic-data and data-recovery rules.
These relative references require the sibling checkouts. If absent, report
the missing guidance before implementation. Keep shared rules in one place.

Keep build checks off the owner's desktop UI. Publish, tag, install, and
launch only within the owner's task scope.
