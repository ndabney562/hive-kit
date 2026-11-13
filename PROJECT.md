# Project: hive-kit

The Hive apps' shared logic as a Swift package (Noah, 2026-11-07: one Hive framework, "one shared package"; public like hive-design so Xcode and Linux CI fetch it with no sign-in). Replaces the old "copy, don't import" rule in each app.

- **Repo URL:** https://github.com/ndabney562/hive-kit (public)
- **Branch:** main (feature branches and PRs)
- **Test command:** `swift test && sh scripts/testflight.test.sh && sh scripts/asc_check.test.sh && sh scripts/asc_public_link.test.sh && python3 -I scripts/test_evidence.py` (from the repo root)
- **Stack:** Swift 6 package, Foundation only (Keychain code only where `Security` exists), macOS and Linux CI.

## Rules
- No secrets, tokens or personal data: the repo is public. The GitHub App client ID is public by design.
- Read-only GitHub: GET and GraphQL queries only.
- UI belongs in hive-design, not here.

## Milestones
- [x] Package with HTTP, GitHub client and sign-in (from HiveTempo's newer copy), shared TestFlight script; tests pass
- [x] Public repo with CI and tag 1.0.0
- [x] Release evidence pack: `scripts/evidence.py` gates `testflight.sh` on tests + UI screenshots + build number, `releases` feed file (1.10.0, 2026-11-13)
- [x] HiveRounds uses it (hive-rounds PR 5)
- [x] HiveTempo uses it (its own copies removed)
- [x] HiveScore uses it (its own copies removed; gains HiveTempo's sign-out race fix)
- [x] HiveMind's iOS app uses it where it overlaps
- [x] Hive feed: three apps publish, one link live (spec 2026-11-08)
- [x] "How to use" guide data and checks (`Guide`, `GuideLaunch`, `GuideCoverage`; 1.8.0, hive-design plan 2026-11-11-hive-guide)
