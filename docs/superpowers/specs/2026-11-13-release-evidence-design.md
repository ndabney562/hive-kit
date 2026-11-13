# Release evidence pack design (approved by Noah 2026-11-13)

## Spec

**Why:** Codex reviews and HANDOFF lines should cite real proof that a TestFlight build was tested, and HiveTempo should show one line: "ready" or "missing X". The pack is not a report for Noah to read.

**New script:** hive-kit `scripts/evidence.py <repo> [--build <n>]`, run with `python3 -I`, with no network or API calls. `scripts/testflight.sh` calls it before archiving.
1. **Clean tree:** refuse when the repo has uncommitted changes, so the proof matches what ships.
2. **Tests:** run the repo's PROJECT.md test command itself. Use `~/agent-rules/scripts/heavy-guard <app>-tests -- <cmd>` when heavy-guard exists; otherwise run the command directly. Record exit code, pass/fail/skip counts (parse the xcodebuild and swift test summaries), duration, the commit SHA, and whether heavy-guard reported "ran under load".
3. **Screenshots:** pull the screenshot attachments the UI tests already make from the newest `.xcresult` for that run (`xcrun xcresulttool`). Keep iPhone-size light and dark shots. If the app's UI tests make none, that's missing proof.
4. **Build:** marketing version, build number and commit, read from the Xcode project or the build settings `testflight.sh` already uses.
5. **Output:**
   - `<repo>/release-evidence/<build>/evidence.json`, committed. It holds: app, version, build, commit, test command, counts, exit code, under_load, the screenshot list with sha256 for each, created time, and `override` (reason or null).
   - The screenshots and a simple `index.html` go in the same folder but are gitignored. Add the ignore rule, so binaries stay out of git.
6. **Gate:** any missing piece (failing tests, no test summary, no screenshots, no build number, dirty tree) → exit non-zero, list exactly what's missing, and `testflight.sh` doesn't upload. Override: `HIVE_EVIDENCE_OVERRIDE="<reason>"` lets it through. The reason is written into evidence.json, and a line is added to the app's HANDOFF.md ("Released build N with override: <reason>").
7. **Where Noah sees it:** the existing "Update <app> in TestFlight" Reminders item that `testflight.sh` makes, and the matching HiveTempo step if there is one, get one line: `Ready: <N> tests pass, <M> screens` or `Override: <reason>`. Also publish evidence.json with `hivemind feed publish releases <file>` when `hivemind` is on PATH, and add a `releases` entry to `docs/hive-feed.md`. HiveScore can count proven releases later; don't change HiveScore now.

**Scope:**
- v1: every Hive app that uses hive-kit's `testflight.sh`.
- Bay Ridge (not a TestFlight app) isn't blocked. Name evidence.json's fields in line with its screenshot-baseline QA conventions (`~/Desktop/AI.Stuff/Apps.Games/Pokemon.Bay.Ridge/pokefirered/bayridge`; not the `.QA` copy) so it can join later. Read that convention first.

**Tests (TDD, in hive-kit; add to `scripts/` tests and the PROJECT.md test command):**
- A fake repo with passing tests and screenshots → ready.
- Each missing piece → blocked with the right message.
- Override → passes, with the reason in evidence.json and HANDOFF.
- Dirty tree → refused.
- `testflight.sh --dry-run` shows the gate step.
- No network calls (stub the tools).
- hive-kit's existing tests still pass.

