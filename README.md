# HiveKit

The Hive apps' shared logic as one Swift package (Noah, 2026-11-07: "these projects are globally viewed under the same framework"). The look lives in [hive-design](https://github.com/ndabney562/hive-design); everything else a second Hive app would need lives here, so the apps can't drift apart.

- **HTTP:** `HTTPTransport`, `HTTPReply`, `URLSessionTransport` (ephemeral session), `URLRequest.form`.
- **GitHub (read-only):** `GitHubClient` (`rest`, `graphql`, one retry after a refresh, rate limits as `FetchError.rateLimited`), device-flow sign-in (`DeviceFlow`, `TokenKeeper`, `KeychainTokenSafe(service:)` with the app's own bundle id, so apps never share a token).
- **TestFlight:** `scripts/testflight.sh <repo> <project> <name> [--dry-run]` and `scripts/ExportOptions.plist`.
- **App Store Connect check:** `python3 -I scripts/asc_check.py <repo>` registers the app's bundle ID if Apple doesn't have it and stops with Noah's steps when App Store Connect has no app record. `testflight.sh` runs it before every archive; run it the day a new Hive app's Xcode project is made.

## Use it

1. Xcode › File › Add Package Dependencies… › `https://github.com/ndabney562/hive-kit` › Up to Next Major from `1.0.0`, then `import HiveKit`. In a Kit package: `.package(url: "https://github.com/ndabney562/hive-kit", from: "1.0.0")`.
2. TestFlight: copy `scripts/ExportOptions.plist` to the app's `Config/`, and make the app's `scripts/testflight.sh`:
   ```sh
   #!/bin/sh
   exec sh "${HIVE_KIT:-$HOME/AI.Stuff/hive-kit}/scripts/testflight.sh" "$(cd "$(dirname "$0")/.." && pwd)" HiveRounds HiveRounds "$@"
   ```

## Change it

1. Change it here, with a test. `swift test && sh scripts/testflight.test.sh && sh scripts/asc_check.test.sh`.
2. Tag a new version (`git tag 1.0.1 && git push --tags`) and bump each app's package version in the same week.
