#!/usr/bin/env python3
"""Release evidence pack for a Hive app: proof that the build going to TestFlight was tested.

Usage: python3 -I evidence.py <app repo> [--build N] [--app NAME]
       python3 -I evidence.py --feed <evidence.json>   (prints the Hive feed file `releases`)
testflight.sh runs it before archiving and uploads only when it exits 0. No network or API calls.

1. Clean tree: refuses when the repo has uncommitted changes (release-evidence/ itself excepted).
2. Tests: runs the PROJECT.md test command, plus the PROJECT.md xcodebuild UI test when that line names one, through
   ~/agent-rules/scripts/heavy-guard <app>-tests (HEAVY_GUARD_BIN overrides) when it exists. Records exit code,
   pass/fail/skip counts (swift test, XCTest, unittest summaries, and the run's .xcresult), duration, commit, and
   whether heavy-guard said "ran under load".
3. Screenshots: the iPhone image attachments of the newest .xcresult this run made (xcrun xcresulttool), named like
   Bay Ridge's harness shots (path relative to the run folder, compared by bytes/sha256).
4. Build: MARKETING_VERSION and CURRENT_PROJECT_VERSION from the Xcode project (--build wins).
5. Output: <repo>/release-evidence/<build>/evidence.json (committed) plus the screenshots and index.html, which the
   folder's own .gitignore keeps out of git.
6. Gate: anything missing -> exit 1 and the last line is `Missing: a; b`. HIVE_EVIDENCE_OVERRIDE="<reason>" lets it
   through: the reason goes into evidence.json and a line into HANDOFF.md. Otherwise the last line is
   `Ready: N tests pass, M screens` (or `Override: <reason>`), which testflight.sh puts on Noah's reminder.
Exit: 0 ready or overridden · 1 missing proof · 2 usage. Python 3.9 compatible (system python3).
"""

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
SCHEMA = 1


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout


def dirty_files(repo):
    out = git(repo, "status", "--porcelain", "--untracked-files=all")
    return [line[3:] for line in out.splitlines() if line[3:] and not line[3:].startswith("release-evidence/")]


def test_commands(line):
    """The PROJECT.md test command (first `span`), plus any later span that runs xcodebuild tests (UI smoke)."""
    spans = re.findall(r"`([^`]+)`", line)
    if not spans:
        return []
    cmds = [spans[0]]
    cmds += [s for s in spans[1:] if "xcodebuild" in s and re.search(r"\btest\b", s)]
    return cmds


def project_test_line(repo):
    try:
        for line in Path(repo, "PROJECT.md").read_text().splitlines():
            if "**Test command:**" in line:
                return line
    except OSError:
        pass
    return ""


def without_xcodebuild(text):
    """The output minus each xcodebuild run ("Command line invocation:" ... "** TEST/BUILD ... **"): those
    tests are counted from the run's .xcresult instead, so they are never counted twice."""
    keep, inside = [], False
    for line in text.splitlines():
        if line.startswith("Command line invocation:"):
            inside = True
        if not inside:
            keep.append(line)
        if inside and re.match(r"\*\* (TEST|BUILD|TEST BUILD)[A-Z ]* (SUCCEEDED|FAILED|INTERRUPTED) \*\*", line.strip()):
            inside = False
    return "\n".join(keep)


def parse_counts(text):
    """Pass/fail/skip totals from swift test (XCTest and swift-testing) and python unittest output."""
    passed = failed = skipped = 0
    found = False
    lines = text.splitlines()
    for i, line in enumerate(lines):
        # XCTest: the line after "Test Suite 'All tests'|'Selected tests' passed/failed" holds the totals.
        if re.search(r"Test Suite '(All tests|Selected tests)' (passed|failed)", line) and i + 1 < len(lines):
            m = re.search(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", lines[i + 1])
            if m:
                n, s, f = int(m.group(1)), int(m.group(2) or 0), int(m.group(3))
                passed += n - s - f
                skipped += s
                failed += f
                found = True
        m = re.search(r"Test run with (\d+) tests?.* (passed|failed) after", line)  # swift-testing
        if m:
            n = int(m.group(1))
            if m.group(2) == "passed":
                passed += n
            else:
                issues = re.search(r"with (\d+) issues?", line)
                bad = min(n, int(issues.group(1))) if issues else n
                failed += bad
                passed += n - bad
            found = True
        m = re.match(r"Ran (\d+) tests? in", line)  # python unittest
        if m:
            n = int(m.group(1))
            verdict = next((l for l in lines[i + 1:i + 4] if l.startswith(("OK", "FAILED"))), "")
            s = sum(int(x) for x in re.findall(r"skipped=(\d+)", verdict))
            f = sum(int(x) for x in re.findall(r"(?:failures|errors)=(\d+)", verdict))
            passed += n - s - f
            skipped += s
            failed += f
            found = True
    return {"passed": passed, "failed": failed, "skipped": skipped, "found": found}


def derived_data():
    return Path(os.environ.get("HIVE_EVIDENCE_DERIVED_DATA", HOME / "Library" / "Developer" / "Xcode" / "DerivedData"))


def new_xcresults(since, app):
    """This app's .xcresult bundles made at or after `since` (epoch seconds), newest first. Only the app's own
    DerivedData folder (<app>-<hash>) and test bundles (Test-<app>-...), so another app's run never counts."""
    found = []
    for p in derived_data().glob(f"{app}-*/Logs/Test/Test-{app}-*.xcresult"):
        try:
            if p.stat().st_mtime >= since - 1:
                found.append(p)
        except OSError:
            pass
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)


def xcresult_counts(bundle):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                         capture_output=True, text=True)
    try:
        d = json.loads(out.stdout)
    except ValueError:
        return None
    return {"passed": int(d.get("passedTests", 0)) + int(d.get("expectedFailures", 0)),
            "failed": int(d.get("failedTests", 0)), "skipped": int(d.get("skippedTests", 0)), "found": True}


def screen_name(suggested):
    """'walk-largest-card_0_EA6A...png' -> 'walk-largest-card.png' (XCTAttachment adds _<n>_<UUID>)."""
    return re.sub(r"_\d+_[0-9A-Fa-f-]{8,}(\.\w+)$", r"\1", suggested)


def export_screens(bundle, out_dir):
    """Copy the iPhone image attachments into out_dir. Returns [{path, sha256, appearance, test}]."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                        "--output-path", tmp], capture_output=True, text=True)
        try:
            manifest = json.loads(Path(tmp, "manifest.json").read_text())
        except (OSError, ValueError):
            return []
        shots, used = [], set()
        for test in manifest:
            for a in test.get("attachments", []):
                name = a.get("suggestedHumanReadableName") or a.get("exportedFileName", "")
                src = Path(tmp, a.get("exportedFileName", ""))
                if not name.lower().endswith((".png", ".jpg", ".jpeg")) or not src.is_file():
                    continue
                if not str(a.get("deviceName", "")).startswith("iPhone"):
                    continue
                dest = screen_name(name)
                stem, n = dest, 2
                while dest in used:
                    dest = re.sub(r"(\.\w+)$", f"-{n}\\1", stem)
                    n += 1
                used.add(dest)
                shutil.copyfile(src, out_dir / dest)
                low = dest.lower()
                appearance = "dark" if "dark" in low else "light" if "light" in low else "unknown"
                shots.append({"path": dest, "sha256": hashlib.sha256((out_dir / dest).read_bytes()).hexdigest(),
                              "appearance": appearance, "test": test.get("testIdentifier")})
        return sorted(shots, key=lambda s: s["path"])


def build_settings(repo, app):
    """(marketing version, build number) from the app's Xcode project, or (None, None)."""
    projects = sorted(Path(repo).glob(f"{app}.xcodeproj/project.pbxproj")) or \
        sorted(p for p in Path(repo).glob("**/*.xcodeproj/project.pbxproj")
               if not any(x in p.parts for x in (".build", "build", "DerivedData")))
    for pbx in projects:
        text = pbx.read_text(errors="replace")
        ver = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
        build = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)
        return (ver[-1].strip().strip('"') if ver else None, build[-1].strip().strip('"') if build else None)
    return None, None


def run_tests(repo, app, cmds):
    """Runs the commands (through heavy-guard when present). Returns (exit code, output, seconds, under_load)."""
    script = " && ".join(f"( {c} )" for c in cmds)
    cmd = ["zsh", "-c", script]
    guard = os.environ.get("HEAVY_GUARD_BIN", str(HOME / "agent-rules" / "scripts" / "heavy-guard"))
    if os.access(guard, os.X_OK):
        cmd = [guard, f"{app}-tests", "--"] + cmd
    start = time.time()
    proc = subprocess.Popen(cmd, cwd=str(repo), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = []
    for line in proc.stdout:
        sys.stderr.write(line)  # live progress; stdout stays for the result lines
        out.append(line)
    code = proc.wait()
    text = "".join(out)
    return code, text, round(time.time() - start, 1), "heavy-guard: ran under load" in text


def write_index(out_dir, data):
    rows = "".join(f'<figure><img src="{html.escape(s["path"])}" width="240"><figcaption>{html.escape(s["path"])} '
                   f'({s["appearance"]})</figcaption></figure>' for s in data["screenshots"])
    status = "Ready" if data["ready"] else ("Override: " + data["override"] if data["override"] else
                                            "Missing: " + "; ".join(data["missing"]))
    t = data["tests"]
    (out_dir / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>%s %s (%s)</title><body style='font-family:system-ui'>"
        "<h1>%s %s (build %s)</h1><p>%s</p><p>Commit %s · %d passed, %d failed, %d skipped · exit %s%s</p>%s"
        % (html.escape(data["app"]), html.escape(str(data["version"])), html.escape(str(data["build"])),
           html.escape(data["app"]), html.escape(str(data["version"])), html.escape(str(data["build"])),
           html.escape(status), data["commit"][:10], t["passed"], t["failed"], t["skipped"], t["exit_code"],
           " · ran under load" if data["under_load"] else "", rows))


def add_handoff_line(repo, build, reason):
    path = Path(repo, "HANDOFF.md")
    line = f"Released build {build} with override: {reason} ({dt.date.today().isoformat()})."
    try:
        text = path.read_text()
    except OSError:
        text = ""
    if "- **Done:** " in text:
        text = text.replace("- **Done:** ", f"- **Done:** {line} ", 1)
    else:
        text = text.rstrip("\n") + ("\n\n" if text else "") + f"- {line}\n"
    path.write_text(text)


def feed_envelope(data, now=None):
    """Hive feed file `releases` (schema 1) for one release; docs/hive-feed.md has the fields."""
    now = now or dt.datetime.now(dt.timezone.utc)
    return {
        "schema": 1,
        "app": "releases",
        "written_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stale_after_minutes": 60 * 24 * 30,
        "summary": {
            "app": data.get("app"), "version": data.get("version"), "build": data.get("build"),
            "commit": data.get("commit"), "ready": bool(data.get("ready")), "override": data.get("override"),
            "tests_passed": (data.get("tests") or {}).get("passed"),
            "screens": len(data.get("screenshots") or []), "under_load": bool(data.get("under_load")),
            "at": data.get("created_at"),
        },
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--feed"]:  # testflight.sh: evidence.json -> Hive feed file, on stdout
        if len(argv) != 2:
            print("usage: evidence.py --feed <evidence.json>", file=sys.stderr)
            return 2
        print(json.dumps(feed_envelope(json.loads(Path(argv[1]).read_text())), indent=2))
        return 0
    ap = argparse.ArgumentParser(description="Release evidence pack for a Hive app (see the file header).")
    ap.add_argument("repo")
    ap.add_argument("--build", help="build number (default: CURRENT_PROJECT_VERSION in the Xcode project)")
    ap.add_argument("--app", help="app / Xcode project name (default: the repo folder name)")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists() and not git(repo, "rev-parse", "--git-dir").strip():
        print(f"evidence: {repo} is not a git repo", file=sys.stderr)
        return 2
    app = args.app or repo.name
    override = os.environ.get("HIVE_EVIDENCE_OVERRIDE", "").strip() or None
    missing = []

    dirty = dirty_files(repo)
    if dirty:
        # Refuse before running anything: the proof must match what ships.
        missing.append(f"uncommitted changes ({', '.join(dirty[:5])}{', ...' if len(dirty) > 5 else ''})")
        print("\n".join("- " + m for m in missing))
        print("Missing: " + "; ".join(missing))
        return 1

    version, build = build_settings(repo, app)
    build = args.build or build
    if not build:
        missing.append("no build number (CURRENT_PROJECT_VERSION in the Xcode project, or --build)")
    commit = git(repo, "rev-parse", "HEAD").strip()

    cmds = test_commands(project_test_line(repo))
    started = time.time()
    if cmds:
        code, output, seconds, under_load = run_tests(repo, app, cmds)
    else:
        missing.append("no test command in PROJECT.md")
        code, output, seconds, under_load = None, "", 0.0, False
    out_dir = repo / "release-evidence" / (build or "unknown")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / ".gitignore").write_text("# Only evidence.json is committed; screenshots and index.html stay local.\n"
                                       "*\n!.gitignore\n!evidence.json\n")
    screens = []
    bundles = new_xcresults(started, app) if cmds else []
    xc = xcresult_counts(bundles[0]) if bundles else None
    # xcodebuild tests count once, from the .xcresult; without one, its printed summary is the fallback.
    counts = parse_counts(without_xcodebuild(output) if xc else output)
    if xc:
        for k in ("passed", "failed", "skipped"):
            counts[k] += xc[k]
        counts["found"] = True
    if bundles:
        screens = export_screens(bundles[0], out_dir)
    if cmds and code != 0:
        missing.append(f"tests failed (exit {code})")
    if cmds and not counts["found"]:
        missing.append("no test summary in the test output")
    elif cmds and counts["failed"]:
        missing.append(f"{counts['failed']} tests failed")
    if not screens:
        missing.append("no screenshots (the UI tests attached no iPhone images in this run)")

    ready = not missing
    data = {
        "schema": SCHEMA,
        "app": app,
        "version": version,
        "build": build,
        "run": build,  # Bay Ridge harness naming: runs/<run> compared against runs/<baseline>
        "baseline": None,
        "commit": commit,
        "test_command": " && ".join(cmds) if cmds else None,
        "tests": {"passed": counts["passed"], "failed": counts["failed"], "skipped": counts["skipped"],
                  "exit_code": code, "duration_s": seconds},
        "suites": [{"name": "project-test-command", "exit": code}],
        "under_load": under_load,
        "xcresult": str(bundles[0]) if bundles else None,
        "screenshots": screens,
        "ready": ready,
        "missing": missing,
        "override": override if not ready else None,
        "created_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    (out_dir / "evidence.json").write_text(json.dumps(data, indent=2) + "\n")
    write_index(out_dir, data)
    for m in missing:
        print("- " + m)
    print(f"evidence: {out_dir / 'evidence.json'}")
    if ready:
        print(f"Ready: {counts['passed']} tests pass, {len(screens)} screens")
        return 0
    if override:
        add_handoff_line(repo, build or "unknown", override)
        print(f"Override: {override}")
        return 0
    print("Missing: " + "; ".join(missing))
    return 1


if __name__ == "__main__":
    sys.exit(main())
