# NetToys

Read `goals.md` when present. Work in this checkout on its current branch.
Use synthetic fixtures for SSH, network, and monitoring tests.

In the shared workspace, read `../powertoys/spec/troubleshoot/troubleshoot.md`
first, then its topics for system tools, UI chrome, and verification.
Shared rules live in `../powertoys/.agents/rules/`. Read code-style.md,
architecture.md, design-tokens.md, window-experience.md, and release.md for
their matching tasks. `../powertoys/DESIGN.md` owns the shared UI contract.
Use `../switch/AGENTS.md` for the synthetic-data and data-recovery rules.
These relative references require the sibling checkouts. If absent, report
the missing guidance before implementation. Keep shared rules in one place.

## Product (owner, 2026-11-16)

- The visible product name is Sam's NetToys (app name, window titles,
  display name). Package, module, bundle id, and repository names stay
  `NetToys` / `nettoys`.
- NetToys left MacPowerToys. This repository is its only home and owns the
  app (no helper or daemon; see `specs/safety.md`), the menu panel,
  routes, and icons. MacPowerToys keeps only the fan part of its shared
  login helper. Keep existing tags (MacPowerToys pins 1.0.13 until its
  removal lands).

Keep build checks off the owner's desktop UI. Publish, tag, install, and
launch only within the owner's task scope.
