# Hive switcher: one ecosystem, separate apps (2026-11-09)

Noah, 2026-11-09: "Each app still seems too separated from one another, these apps should all exist within a shared
ecosystem while maintaining separate individual apps." Plan item 3 (iCloud `AI.Stuff/Hive/Hive-plan-2026-11-09.md`).

## What the user sees
Every Hive app's ☰ menu ends with a **Hive apps** section: one row per sibling app (never itself), its name and a live
one-line status read from the Hive feed, for example:
- HiveScore: "99 · Good" (capped: "60 · capped by a safety problem")
- HiveTempo: "2 of 5 done · next: Post today's TikTok 4:00 pm"
- HiveMind: "Codex 86% left · 2 alerts"
A status past its `stale_after_minutes` reads "not updated since 9:26 am". Tapping a row opens that app
(`hivemind://`, `hivescore://`, `hivetempo://`); if it isn't installed, iOS does nothing and the row says
"Not on this iPhone" after the failed open.

## Parts
1. **hive-kit 1.3.0** `HiveApp` (id = feed name, display name, URL), `HiveStatus` (app, line, stale, written),
   `HiveStatus.line(...)` per summary type (pure, tested), and `HiveFeedReader.statuses(except:now:)`: every sibling's
   file, one failure never hides the others (that row says "No status yet").
2. **hive-design 1.4.0** `HiveAppsSection(statuses:)`: header + rows in the menu's row style, opens the URL with
   `openURL`; VoiceOver reads "HiveScore, 99, Good, opens the app".
3. **Apps**: HiveScore and HiveMind get URL schemes; HiveScore and HiveTempo read statuses when they refresh (they
   already sign in to GitHub). HiveMind's phone app has no GitHub sign-in, so its section waits for step 2 of the plan
   (sign in once, shared Keychain group) and opens the apps without status lines until then.
4. **HiveRounds** never shows it: it runs on the doctor's phone (build-time links only).

## Not in this step
Shared sign-in (Keychain access group), the combined Hive widget, HiveMind alerts as HiveTempo tasks: next steps of
plan item 3, each its own PR.
