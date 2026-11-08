# Hive feed: design

Date: 2026-11-08. Approved path: Noah, "Yes all" (B1 first, GitHub as the store) and "Do whatever you recommend".
Rule it serves: global AGENTS.md "Hive family" (the Hive apps are one connected system).

## Goal

One shared, small data format that every Hive app publishes its status in and reads its siblings' status from, so a
link between two apps is "read the other app's feed file", not a new one-off pipe. Done means:

1. HiveMind, HiveTempo and HiveScore each publish a feed file on every run of their existing Mac job.
2. Swift apps read any feed file through one hive-kit type (`HiveFeed`); Mac scripts and agents read it through one
   command (`hivemind feed show`).
3. The first real link uses it: HiveScore's top fix shows up as a HiveTempo task (B2).
4. A new Hive app joins by publishing one file in the same envelope.

Out of scope here (each gets its own spec later): plan completion as a HiveScore dial (B3, needs a scoring method
bump), one shared sign-in (B4), HiveMind alerts as HiveTempo nudges (B5), the Hive Today widget (C1), the hive-kit
version check in HiveScore (C2). HiveRounds publishes nothing: it runs on the provider's phone (global rule).

## Today

- HiveMind publishes `health.json` to the orphan branch `health` of the private `hivemind` repo
  (`hivemindcore/health_report.py`, launchd `com.noahdabney.hivemind-health`). HiveScore reads it.
- HiveTempo's planner publishes `tempo.json` to the orphan branch `tempo` of `hive-tempo`
  (`planner/tempoplan/publish.py`, a copy of HiveMind's code; launchd `com.noahdabney.hive-tempo-planner`).
- HiveScore computes the score only on the phone, and the phones never write to GitHub. So no other app can see the
  score or the top fixes.

## Design

### 1. Where the feed lives

The orphan branch `hive` of the private `hivemind` repo, one file per app: `hivemind.json`, `hive-tempo.json`,
`health-score.json` (file name = the app's repo name). The GitHub App that HiveScore and HiveTempo sign in with can
already read this repo (HiveScore reads `health` there). The existing `health` and `tempo` branches stay as they are:
they hold each app's full data; the feed holds a summary and points at them.

Only the Mac writes. Every write goes through HiveMind (`hivemind feed publish`), which holds a lock file, so two jobs
never race on the branch, and the git plumbing exists once (it moves out of the copy in hive-tempo's `publish.py` for
the feed; `tempo.json` publishing is unchanged).

### 2. The envelope (schema 1)

```json
{
  "schema": 1,
  "app": "hive-tempo",
  "written_at": "2026-11-08T19:42:00Z",
  "stale_after_minutes": 90,
  "detail": {"repo": "ndabney562/hive-tempo", "branch": "tempo", "path": "tempo.json"},
  "summary": {}
}
```

- `app` must equal the file name without `.json`. `detail` is optional.
- A reader treats a file as stale when `now > written_at + stale_after_minutes` and says so ("from 3 h ago"); it never
  shows stale data as current.
- `summary` is app-specific (below). New fields may be added without a schema bump; readers ignore fields they don't
  know. Removing or changing a field's meaning bumps `schema`, and a reader skips a schema it doesn't know.
- Size limit 64 KB per file. No secrets, tokens, prompts or answer text (same rule as `health.json`).

### 3. Summaries in version 1

`hivemind.json` (written by the health job, hourly):

```json
{"quota": [{"ai": "codex", "left_pct": 90, "read_at": "…"}],
 "alerts": [{"kind": "on_battery", "text": "The Mac is unplugged", "at": "…"}],
 "now": "Speed: median answer 23 s → under 10 s"}
```

`hive-tempo.json` (written by the planner after each plan):

```json
{"date": "2026-11-08", "state": "inProgress", "done": 3, "total": 5,
 "current": {"title": "Post today's TikTok", "until": "14:30"}, "next": {"title": "…", "at": "15:00"}}
```

`state` uses HiveTempo's widget phases: `unavailable`, `empty`, `scheduled`, `inProgress`, `finished`, `outOfTime`.

`health-score.json` (written by the new HiveScore Mac job, hourly):

```json
{"method": 8, "score": 60, "word": "Fair", "capped": true,
 "top_fixes": [{"id": "safety.secret_diff", "repo": "ndabney562/hive-tempo", "title": "…", "points": 40}]}
```

### 4. HiveScore on the Mac

A small executable target `hivescore` in the health-score package (`HealthScoreKit`, which already builds on macOS)
runs the same `FactsFetcher` and `Scorer` as the app, then prints the summary JSON. Its tracked repos are the app's
own list: the app already pairs with the HiveMind hub for Optimize, and on each settings change (and once after an
update) it sends its `[TrackedRepo]` to the hub, which saves it as `state/hivescore-repos.json`. Before the first
sync the job publishes nothing. It reads a GitHub token from the `GITHUB_TOKEN` environment variable. A launchd wrapper sets it
from `gh auth token` at run time; the token is never written to a file. The wrapper then calls
`hivemind feed publish health-score <file>`. One scorer, two places: the app and the Mac show the same number for the
same facts.

### 5. Reading

- Swift: hive-kit gets `HiveFeed` (envelope `Codable`, `isStale(now:)`, per-app summary types) and
  `HiveFeedReader.read(app:)` using the existing `GitHubClient` (`GET /repos/ndabney562/hivemind/contents/<app>.json?ref=hive`).
  A missing file returns `nil`, not an error.
- Mac: `hivemind feed show [app] [--json]` prints one line per app (or the raw JSON), with stale files marked.

### 6. First link: HiveScore fix → HiveTempo task (B2)

HiveTempo's planner runs `hivemind feed show health-score --json` (it already calls only the `hivemind` command).
When the file is fresh and the top fix has at least 5 points, the planner adds one item to the focus candidates:
"HiveScore: <title> (+N points)", tagged to the fix's repo. The usual focus rules and HiveMind's pick still decide
whether it makes the day. A missing, stale or malformed feed adds nothing and the plan is made as before.

## Errors

- Publish: validation failure → exit 1 with the reason, nothing pushed. Push rejected (someone else pushed) → fetch,
  rebuild the commit on the new tip, retry up to 3 times. No network → exit 1; the next hourly run catches up.
- Read: missing → `nil`; stale → returned with `isStale`; unknown schema → skipped with a log line; bad JSON → skipped.
- Every consumer works without the feed (it only adds information).

## Testing

- HiveMind (Python unittest): envelope validation (good, wrong app name, too big, unknown schema); publish to a temp
  bare repo (first write, update, two apps, rejected push retried); lock; `feed show` text and JSON, stale marking.
- hive-kit (swift test): decode fixtures for each summary, unknown fields ignored, stale, missing file is `nil`, schema 2
  skipped. Fixtures are shared: `docs/hive-feed/*.json`, also used by HiveMind's tests (copied by a test that checks
  they stay equal when `~/AI.Stuff/hive-kit` is present, and skips otherwise, like hive-design's app.css drift test).
- health-score: the `hivescore` executable on a contract case gives the same score as `Scorer` (golden); the app sends
  its repo list after a settings change (fake hub).
- HiveMind: the hub saves a posted repo list from a paired HiveScore phone and refuses an unpaired one.
- hive-tempo planner: a fresh fix becomes one candidate; stale, missing, below 5 points or bad JSON adds nothing.

## Rollout

One PR per repo, in order: hive-kit (types, reader, fixtures, this spec, `docs/hive-feed.md`), HiveMind (`feed`
command, `hivemind.json` from the health job, the hub's repo-list endpoint), health-score (`hivescore` executable, launchd job), hive-tempo
(publish `hive-tempo.json`, B2 candidate). Then the global rule gets one line: links between Hive apps use the Hive
feed (`hive-kit/docs/hive-feed.md`).
