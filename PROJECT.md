# Project: hive-kit

The Hive apps' shared logic as a Swift package (Noah, 2026-11-07: one Hive framework, "one shared package"; public like hive-design so Xcode and Linux CI fetch it with no sign-in). Replaces the old "copy, don't import" rule in each app.

- **Repo URL:** https://github.com/ndabney562/hive-kit (public)
- **Branch:** main (feature branches and PRs)
- **Test command:** `swift test && sh scripts/testflight.test.sh` (from the repo root)
- **Stack:** Swift 6 package, Foundation only (Keychain code only where `Security` exists), macOS and Linux CI.

## Rules
- No secrets, tokens or personal data: the repo is public. The GitHub App client ID is public by design.
- Read-only GitHub: GET and GraphQL queries only.
- UI belongs in hive-design, not here.

## Milestones
- [x] Package with HTTP, GitHub client and sign-in (from HiveTempo's newer copy), shared TestFlight script; tests pass
- [x] Public repo with CI and tag 1.0.0
- [ ] HiveRounds uses it
- [ ] HiveTempo uses it (its own copies removed)
- [ ] HiveScore uses it (its own copies removed; gains HiveTempo's sign-out race fix)
- [ ] HiveMind's iOS app uses it where it overlaps
