# Hive feed

Each Hive app's status as one small JSON file, so one Hive app can read another's (global rule "Hive family").
Design: `docs/superpowers/specs/2026-11-08-hive-feed-design.md`. Examples: `docs/hive-feed/*.json` (also the tests'
fixtures).

## Where

Branch `hive` of the private repo `ndabney562/hivemind`, one file per app: `<app>.json`, where `<app>` is the app's
repo name (`hivemind`, `hive-tempo`, `health-score`, `ai-business-db`, `hiveworld`; `iphone` is the Mac's weekly iPhone scan and `ideas` the weekly idea generator, neither a repo). Only the Mac writes, always through HiveMind:

    hivemind feed publish <app> <file>     # validates, then commits on top of the branch and pushes
    hivemind feed show [app] [--json]      # one line per app, stale ones marked; --json prints the file

Swift apps read with `HiveFeedReader(client:).read("<app>", as: <Summary>.self)` (hive-kit).

## Envelope (schema 1)

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | 1. A reader skips a schema it doesn't know. |
| `app` | string | Equals the file name without `.json`. |
| `written_at` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ`. |
| `stale_after_minutes` | int | After `written_at` plus this, readers show the file as old, never as current. |
| `detail` | object, optional | `{repo, branch, path}` of the app's full data, e.g. `tempo.json`. |
| `summary` | object | The app's own fields, below. |

Rules: at most 64 KB; no secrets, tokens, prompts or answer text; new fields may be added (readers ignore unknown
ones); removing a field or changing its meaning bumps `schema`.

## Summaries

| App | Field | Meaning |
|---|---|---|
| hivemind | `quota[]` | `{ai, left_pct, read_at}` per AI meter |
| hivemind | `alerts[]` | `{kind, text, at}` open alerts |
| hivemind | `now` | the current improvement item, one line |
| hive-tempo | `date`, `state` | today; a widget phase: unavailable, empty, scheduled, inProgress, finished, outOfTime |
| hive-tempo | `done`, `total` | tasks ticked / planned today |
| hive-tempo | `current`, `next` | `{title, until}` / `{title, at}` (HH:MM, local), or null |
| health-score | `method`, `score`, `word`, `capped` | the HiveScore reading (scoring method, 0-100, band word, safety cap) |
| health-score | `top_fixes[]` | `{id, repo, title, points}`, at most 3, biggest gain first |
| health-score | `repos[]` | `{repo, score}`: each scored repo's own score (0-100, the same method run on that repo alone); read by HiveWorld. Absent in files written before 2026-11-11 |
| ai-business-db | `day`, `days_total`, `ends` | the 90-day income challenge: today's day number, its length, its last day (YYYY-MM-DD) |
| ai-business-db | `earned_usd` | dollars earned so far, all routes |
| ai-business-db | `routes[]` | `{name, status, earned_usd}` per earning route (`earned_usd` null when unknown), at most 8 |
| hiveworld | `schema_version`, `generated_at`, `weights` | HiveWorld's own version, run time, need weights (score gap, momentum drop, income boost) |
| hiveworld | `pick` | project ids most in need first (paused and finished never listed); read by HiveTempo |
| hiveworld | `projects[]` | per repo: `id` (owner/repo), `name`, `score`, `momentum` {`weekly`[12], `usual`, `change_pct`, `status`}, `progress` {`done`, `total`, `forecast`}, `next_step`, `need`, `reason`, `paused`, `stale`, `as_of`, `n` and more; full list in HiveWorld's spec. `WorldSummary` decodes the fields HiveTempo needs |
| ai-business-db | `next_checkpoint` | `{date, title}` of the next challenge checkpoint, or null |
| iphone | `free_gb`, `total_gb`, `free_pct` | the iPhone's free and total storage (GB, 1 decimal) and free share (%) from the Mac's weekly scan (ai-scheduled `iphone_health.py`; never the app list) |
| iphone | `battery_health_pct` | battery capacity left vs new (%), or null |
| iphone | `ios`, `ios_latest`, `update_pending` | installed iOS, Apple's newest for the model (null when unknown), and whether an update waits. Read by HiveScore (`PhoneSummary` in HealthScoreKit; moves here when a second app reads it) |
| ideas | `ideas[]` | every idea put to Noah in the last 14 days: `{asked_on, n, kind, title, why_now, reuses, size, ais}`; `asked_on` + `n` name its Business Asks card (`kind`: feature, link or new; `size`: S, M or L). Written on Tuesdays by ai-scheduled `improvement_sweep.py` (stale after 8 days); HiveTempo looks Design / Park / No answers up here. No Swift reader yet |

## A new app joins

1. Pick its summary fields; add a `Decodable` summary type in `Sources/HiveKit/HiveFeed.swift`, an example in
   `docs/hive-feed/<app>.json` and a row group above (new hive-kit minor version and tag).
2. Its Mac job writes the envelope to a file and runs `hivemind feed publish <app> <file>`.
3. Readers that want it use `HiveFeedReader` or `hivemind feed show <app> --json`. Every reader works without it.
