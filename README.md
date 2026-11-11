# HiveKit

The Hive apps' shared logic as one Swift package (Noah, 2026-11-07: "these projects are globally viewed under the same framework"). The look lives in [hive-design](https://github.com/ndabney562/hive-design); everything else a second Hive app would need lives here, so the apps can't drift apart.

- **HTTP:** `HTTPTransport`, `HTTPReply`, `URLSessionTransport` (ephemeral session), `URLRequest.form`.
- **GitHub (read-only):** `GitHubClient` (`rest`, `graphql`, one retry after a refresh, rate limits as `FetchError.rateLimited`), device-flow sign-in (`DeviceFlow`, `TokenKeeper`, `SharedTokenSafe.hive(service: <bundle id>)`: one sign-in shared by every Hive app through the Keychain group `$(AppIdentifierPrefix)com.noahdabney.hive` (entitlement `keychain-access-groups` plus Info.plist key `HiveKeychainGroup`); an app's older own token moves in on first read, and sign-out signs every app out. Since 1.5.0, Noah 2026-11-09: "sign in once").
- **Hive feed:** `HiveFeedReader(client:)` reads `<app>.json` from the `hive` branch with the user's GitHub token; `HiveFeedReader(fetch:)` (since 1.6.1; tag 1.6.0 was pushed on the wrong commit by mistake and holds 1.5.0 code, so depend on 1.6.1) takes the files from any other source, e.g. HiveMind's iPhone asking its Mac hub. `statuses(except:)` gives each Hive app's status line.
- **HiveAI (since 1.7.0):** `HiveAI(engines:)` tries each `HiveAIEngine` in order (on-device model, the Mac hub) and falls back to a paste prompt (`HiveAIResult.pastePrompt`, `OpenInApp`); moved out of HiveRounds so HiveBeat shares it.
- **HiveMind link (since 1.7.0):** `HubLink(config:)` asks the owner's Mac hub one question (`ping()` within 3 s, `ask(_:project:)` posts to `/api/run` and polls `/api/job`; a cancelled task throws `CancellationError`), `HubEngine(link:)` makes it a `HiveAIEngine` named "HiveMind". `PairingSafe.load()/save(_:)/clear()` keep the hub pairing (`HubConfig`) in the shared Keychain group under account `hivemind-pairing`, so one pairing serves every Hive app.
- **TestFlight:** `scripts/testflight.sh <repo> <project> <name> [--dry-run]` and `scripts/ExportOptions.plist`.
- **App Store Connect check:** `python3 -I scripts/asc_check.py <repo>` registers the app's bundle ID if Apple doesn't have it and stops with Noah's steps when App Store Connect has no app record. `testflight.sh` runs it before every archive; run it the day a new Hive app's Xcode project is made.
- **TestFlight public link:** `python3 -I scripts/asc_public_link.py <repo> --group NAME --description TEXT --contact-from <bundle id> [--dry-run]` makes an external group with a public link, adds the newest processed build and submits it to beta review. It copies the review contact and feedback email from another of Noah's apps only where missing (his OK each time: personal data).

## Use it

1. Xcode › File › Add Package Dependencies… › `https://github.com/ndabney562/hive-kit` › Up to Next Major from `1.0.0`, then `import HiveKit`. In a Kit package: `.package(url: "https://github.com/ndabney562/hive-kit", from: "1.0.0")`.
2. TestFlight: copy `scripts/ExportOptions.plist` to the app's `Config/`, and make the app's `scripts/testflight.sh`:
   ```sh
   #!/bin/sh
   exec sh "${HIVE_KIT:-$HOME/AI.Stuff/hive-kit}/scripts/testflight.sh" "$(cd "$(dirname "$0")/.." && pwd)" HiveRounds HiveRounds "$@"
   ```

3. "How to use" guide (`Guide.swift`): ship `Guide.json` (`{"cards": [{"id", "title", "steps", "screen", "changed", "welcome"?}]}`) in the app target; hive-design 1.7.0 draws it. In the app's Kit tests, list the screens and run the shared check:
   ```swift
   let url = URL(filePath: #filePath).deletingLastPathComponent()  // up to the repo root, then <App>/Guide.json
   let guide = try #require(Guide.load(try? Data(contentsOf: url)))
   #expect(GuideCoverage.problems(guide, screens: GuideScreen.allCases.map(\.rawValue)) == [])
   ```

## Change it

1. Change it here, with a test. `swift test && sh scripts/testflight.test.sh && sh scripts/asc_check.test.sh && sh scripts/asc_public_link.test.sh`.
2. Tag a new version (`git tag 1.0.1 && git push --tags`) and bump each app's package version in the same week.
