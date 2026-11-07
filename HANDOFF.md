# Handoff: hive-kit

- **Goal:** One Swift package with the Hive apps' shared logic, so HiveMind, HiveScore, HiveTempo and HiveRounds can't drift apart (Noah, 2026-11-07).
- **Done:** 2026-11-07: package written from HiveTempo's `HTTP.swift`, `GitHubClient.swift` and `GitHubAuth.swift` (newer than HiveScore's: it has the sign-out-during-refresh fix from Codex review 2026-11-05), now public API. Codex review 2026-11-07 fixed 3 more that every app had: sign-out while the sign-in code is on screen, callers joining a refresh after sign-out, a 403 rate limit read as "feature off", an older refresh overwriting a new sign-in; Linux imports; `KeychainTokenSafe(service:)` and `TokenKeeper(flow:safe:)` take the app's own Keychain name, no default. Shared `scripts/testflight.sh` (HiveScore's API-key option + HiveTempo's one-archive check) with `scripts/testflight.test.sh`. 20 Swift tests (1 live sign-in test off unless `HIVEKIT_LIVE_SIGNIN=1`) and the script checks pass.
- **In progress:** public repo + tag 1.0.0, then HiveRounds moves onto it.
- **Next step (exact):** [Assigned: Claude Code] Move HiveTempo onto HiveKit (delete its `HTTP.swift`, `GitHubClient.swift`, `GitHubAuth.swift`; keep the `plan()` extension in HiveTempoKit; pass `KeychainTokenSafe(service: "com.noahdabney.hivetempo")`; one-line `scripts/testflight.sh`), then HiveScore, then HiveMind's iOS app. One PR per repo; each removes its "copy, don't import" line.
- **Blockers:** none.
- **Last test result:** 2026-11-07 `swift test` 20 passed; `testflight.test.sh` passed.
- **Last commit hash:** see `git log -1`.
- **Model + timestamp:** Claude Code (Opus 5.5), 2026-11-07.
