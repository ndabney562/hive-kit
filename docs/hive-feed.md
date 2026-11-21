# Hive feed

Each Hive app's status as one small JSON file, so one Hive app can read another's (global rule "Hive family").
Design: `docs/superpowers/specs/2026-11-08-hive-feed-design.md`. Examples: `docs/hive-feed/*.json` (also the tests'
fixtures).

## Where

Branch `hive` of the private repo `ndabney562/hivemind`, one file per app: `<app>.json`, where `<app>` is the app's
repo name (`hivemind`, `hive-tempo`, `health-score`, `ai-business-db`, `hiveworld`; `iphone` is the Mac's weekly iPhone scan, `ideas` the weekly idea generator and `releases` the newest TestFlight upload's release evidence, `jobs` the Mac's automations from hive-tempo's planner, none a repo; `etsy` is the Etsy repo's weekly sales loop). Only the Mac writes, always through HiveMind:

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
| hive-tempo | `current`, `next` | `{title, until}` / `{title, at}` (HH:MM, local), or null; since hive-kit 1.22.0 also `id` (the task's id, for `HiveLink.tempoTask`: opens that task in HiveTempo) |
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
| ai-business-db | `income` | from `income/ledger.csv`: `net_usd`, `month_net_usd`, `pending_usd`, `sales`, `by_route` {route: net}, `last_sale` {date, route, item, net_usd}; since 2026-11-17 also `month` (YYYY-MM), `month_by_route` {route: net this month} and `goal_usd` (rule 15, 100). `IncomeGoal` reads the best route this month against the goal. Since 2026-11-17 also `payouts`: `next` {date, usd} (earliest payout date ahead), `waiting_usd`, `paid_usd`, `overdue` [{date, route, usd}] (pending over 7 days past payout date), `overdue_usd`; amounts are deposits (gross minus fees). Absent in older files |
| ai-business-db | `budget` | from `Budget/_Shared.md` (2026-11-17): `month_usd` (fixed plans a month, yearly ÷ 12, dated price changes applied), `items` [{name, usd_month, estimate}], `estimates` (amounts marked ? or confirm), `credit` [{project, allot_usd, used_usd or null}] (the Anthropic API credit split), and since build order #4 `renewals` [{item, project, date, decide_by or null, cost, decision}] (the Renewals table's dated rows from today on, soonest first). Absent in older files |
| ai-business-db | `lab` | from `reviews/experiments.json` (2026-11-21, Hive build order #21, Lab 16): `running`, `completed`, `due_for_check`, `pilot_unused_days`, `pilot_stop_after_days`, and `experiments[]` (`{id, route, status, started_on, check_on, metric, observed_direction, causation, decision}`). Absent in older files |
| iphone | `free_gb`, `total_gb`, `free_pct` | the iPhone's free and total storage (GB, 1 decimal) and free share (%) from the Mac's weekly scan (ai-scheduled `iphone_health.py`; never the app list) |
| iphone | `battery_health_pct` | battery capacity left vs new (%), or null |
| iphone | `ios`, `ios_latest`, `update_pending` | installed iOS, Apple's newest for the model (null when unknown), and whether an update waits. Read by HiveScore (`PhoneSummary` in HealthScoreKit; moves here when a second app reads it) |
| releases | `app`, `version`, `build`, `commit`, `at` | the newest TestFlight upload of any Hive app (hive-kit `testflight.sh` publishes it after the upload, from `release-evidence/<build>/evidence.json`) |
| releases | `ready`, `override`, `tests_passed`, `screens`, `under_load` | whether its proof was complete (`evidence.py`), the override reason when it wasn't, tests passed, iPhone screenshots kept, and whether heavy-guard ran the tests under load. HiveScore may count proven releases later |
| releases | `baseline`, `changes[]`, `checks[]` | (1.21.0, Release 14) the previous evidence build, PR titles since it (newest first, at most 15, evidence-only commits left out), and those that touch app code or resources: what to check on the phone after updating |
| releases | `apps[]` | the newest release of each app, this one first, then newest first (at most 8), same fields; `testflight.sh` merges it from the current file (`hivemind feed show releases --json`). Read by HiveScore (`ReleasesSummary.releases`) |
| ideas | `ideas[]` | every idea put to Noah in the last 14 days: `{asked_on, n, kind, title, why_now, reuses, size, ais}`; `asked_on` + `n` name its Business Asks card (`kind`: feature, link or new; `size`: S, M or L). Written on Tuesdays by ai-scheduled `improvement_sweep.py` (stale after 8 days); HiveTempo looks Design / Park / No answers up here. No Swift reader yet |
| etsy | `week`, `listing_views_7d`, `orders_7d`, `revenue_7d_usd`, `gumroad_sales_7d` | the Etsy shop's last 7 days (Etsy Shop Stats) and Gumroad sales, from the Etsy repo's `scripts/sales_loop.py --feed`; written Mondays 7:00 by the `etsy-sales-loop` task (stale after 8 days). Shop totals only: never buyer names, messages or addresses |
| etsy | `top[]`, `changes` | `{name, views, sales}` for the 3 busiest products (Etsy + Gumroad); `{edits, new_versions, asks}`: what the loop changed or asked this week. No Swift reader yet |
| jobs | `counts` | `{failed, running, waiting, finished}`: every automation on the Mac (Hive build order #10, Watch 11). Written by hive-tempo's planner (`tempoplan/jobs.py`, reusing the FAILED TODAY check in `failures.py`), on change and at most hourly; stale after 90 minutes. Read by HiveScore (`JobsSummary`) |
| jobs | `jobs[]` | `{kind, name, status, at?, output?, detail?, cause?, last_ok?, handled?}`: `kind` launchd, task or routine; `status` running, waiting, failed or finished; `output` the last line of a launchd job's own log (120 chars, secret-looking lines dropped); `detail` a failed launchd job's exit code and error line; `cause` a failed task's or routine's cause in words (its report never appears); `last_ok` `{at, output}` a failed job's latest successful run; `handled` marked fixed today. Failed first, at most 80 |
| jobs | `issues[]`, `problems[]` | failed jobs grouped by cause: `{cause, jobs[], example?}` (sign-in or permission refused, no connection, timed out, a usage limit, a missing file, else the same error text without numbers); sources the Mac could not read |
| tools | `week[]` | `{id, kind, uses}`: this week's 15 most used Claude capabilities (kind skill, agent, command, connector or plugin), most first. Written Sundays 06:10 by agent-rules `capability_usage_feed.py` (from `capability_report.py`; stale after 7 days). Names and counts only: never prompts, answers or paths. Read by HiveScore's Tools used screen and HiveTempo's top-tools card (`ToolsSummary`, 1.27.0) |
| tools | `weeks[]`, `top_plugins[]`, `top_connectors[]` | `{week_to, uses_total}` for this week and the 4 before (`week_to` YYYY-MM-DD, UTC); `{plugin, uses}` and `{name, uses}` this week, at most 10 each |
| tools | `installed`, `never_used` | `{skills, plugins, connectors}` installed (agent-rules `capability_map.py`); how many indexed capabilities had no use in the 5 weeks |

## Test scenarios (HiveFixture, 1.18.0)

`HiveFixture` holds fixed, fictional feed files (no personal data: every name is made up) for each app above with a
summary, in six scenarios: `normal`, `empty` (fresh files with nothing in them), `missing` (no files), `stale`
(written long before now), `offline` (every read throws `FetchError.offline`) and `malformed` (cut-off JSON). A fixed
`now` gives the same bytes every time. An app started with `-hive-fixture <scenario>` reads
`HiveFixture.reader(scenario)` instead of GitHub, so its UI test can screenshot each state. `HiveFixture.preview(now:)`
lists what `HiveFeedReader.read` gives each app in each scenario. A new app's summary gets a normal and an empty
fixture in `Sources/HiveKit/HiveFixture.swift`.

## Contract check (FeedContract, 1.20.0)

A feed file passes when the type its readers decode reads it (`FeedContract.known`: one per app with a reader in
hive-kit; an app adds its own, e.g. HiveScore's `iphone`). Problems read as sentences in the feed's own names
(`summary.income.month: missing`, `summary.done: not a number`, `schema is 2, readers know 1`). Before changing a
feed's fields, run the new file through the readers:

    swift run --package-path ~/AI.Stuff/hive-kit hive-feed-check <app> <file.json>   # exit 0 passes, 1 problems

Every example in `docs/hive-feed/` passes in hive-kit's tests, and HiveScore checks the live files on every refresh and
lists any that fail in its "Hive feed problems" card. A missing or unreachable file is not a contract break.

## A new app joins

1. Pick its summary fields; add a `Decodable` summary type in `Sources/HiveKit/HiveFeed.swift`, an example in
   `docs/hive-feed/<app>.json` and a row group above (new hive-kit minor version and tag).
2. Its Mac job writes the envelope to a file and runs `hivemind feed publish <app> <file>`.
3. Add a `FeedContract.Contract` for its summary type and run `hive-feed-check` on the example.
4. Readers that want it use `HiveFeedReader` or `hivemind feed show <app> --json`. Every reader works without it.
