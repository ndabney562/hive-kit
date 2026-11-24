#!/usr/bin/env python3
"""Tests for scripts/evidence.py (release evidence pack). Run: python3 -I scripts/test_evidence.py

Every outside tool is a stub: a fake app repo (git), a fake `xcrun` on PATH that exports a fake .xcresult, no
heavy-guard (HEAVY_GUARD_BIN points nowhere unless a test sets a fake one). No network: the stubs are the only tools
the script may call, and `hivemind` is never called by evidence.py (testflight.sh publishes after the upload).
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / "evidence.py"
sys.path.insert(0, str(HERE))
sys.dont_write_bytecode = True  # no scripts/__pycache__ in the repo

import evidence as ev  # noqa: E402

PNG = b"\x89PNG\r\n\x1a\nfake"

XCRUN = textwrap.dedent("""\
    #!/bin/sh
    # Fake xcrun: xcresulttool get test-results summary / export attachments, from $FAKE_XCR.
    [ "$1" = xcresulttool ] || exit 9
    case "$2 $3" in
      "get test-results") cat "$FAKE_XCR/summary.json" ;;
      "export attachments")
        while [ $# -gt 0 ]; do [ "$1" = --output-path ] && out=$2; shift; done
        cp "$FAKE_XCR"/att/* "$out"/ ;;
      *) exit 9 ;;
    esac
    """)


class Fixture:
    def __init__(self, tmp, test_cmd="echo 'Ran 3 tests in 0.01s'; echo OK", screenshots=True, build_setting=True,
                 summary=None):
        self.root = Path(tmp)
        self.repo = self.root / "app"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.dd = self.root / "DerivedData"
        self.xcr = self.root / "xcr"
        (self.xcr / "att").mkdir(parents=True)
        (self.bin / "xcrun").write_text(XCRUN)
        (self.bin / "xcrun").chmod(0o755)
        (self.repo / "PROJECT.md").write_text(f"# Demo\n\n- **Test command:** `{test_cmd}` (from the repo root)\n")
        (self.repo / "HANDOFF.md").write_text("# Handoff\n\n- **Done:** older work.\n")
        proj = self.repo / "Demo.xcodeproj"
        proj.mkdir()
        settings = "MARKETING_VERSION = 1.4;\nCURRENT_PROJECT_VERSION = 7;\n" if build_setting else ""
        (proj / "project.pbxproj").write_text("// fake\n" + settings)
        self.summary = summary or {"passedTests": 9, "failedTests": 0, "skippedTests": 1, "expectedFailures": 0,
                                   "result": "Passed"}
        (self.xcr / "summary.json").write_text(json.dumps(self.summary))
        if screenshots:
            manifest = [{"testIdentifier": "SmokeTests/testHome()", "attachments": [
                {"exportedFileName": "A.png", "suggestedHumanReadableName": "home-light_0_FEA8F2C5-7BCE-4114-9DDF-7F670E4A20D9.png",
                 "deviceName": "iPhone 17e"},
                {"exportedFileName": "B.png", "suggestedHumanReadableName": "home-dark_0_EA6A50A2-58F1-4DD7-A28E-3CDB9EBAEEB2.png",
                 "deviceName": "iPhone 17e"},
                {"exportedFileName": "C.png", "suggestedHumanReadableName": "ipad-wide_0_36F06393-06E3-464F-AB13-E6BD8EB44A0B.png",
                 "deviceName": "iPad Pro 13-inch"},
                {"exportedFileName": "D.txt", "suggestedHumanReadableName": "log_0_46C14649-5898-4758-B8AB-5063D44E70D6.txt",
                 "deviceName": "iPhone 17e"}]}]
            (self.xcr / "att" / "manifest.json").write_text(json.dumps(manifest))
            for n in ("A.png", "B.png", "C.png"):
                (self.xcr / "att" / n).write_bytes(PNG + n.encode())
            (self.xcr / "att" / "D.txt").write_text("log")
        else:
            (self.xcr / "att" / "manifest.json").write_text("[]")
        self.git("init", "-q")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@t")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout

    def env(self, **extra):
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root), "FAKE_XCR": str(self.xcr),
               "HIVE_EVIDENCE_DERIVED_DATA": str(self.dd), "HEAVY_GUARD_BIN": str(self.root / "no-guard")}
        env.update(extra)
        return env

    def run(self, *args, **env):
        return subprocess.run([sys.executable, "-I", str(EVIDENCE), str(self.repo), "--app", "Demo", *args],
                              capture_output=True, text=True, env=self.env(**env), timeout=60)


def xcode_test_cmd(fx):
    """A test command that, like xcodebuild, leaves a fresh .xcresult in DerivedData."""
    target = fx.dd / "Demo-abc" / "Logs" / "Test" / "Test-Demo-now.xcresult"
    return (f"mkdir -p '{target}' && echo 'Command line invocation:' && "
            "printf 'Test Suite \\047All tests\\047 passed\\n\\t Executed 10 tests, with 1 test skipped and 0 failures (0 unexpected) in 1 (1) seconds\\n' && "
            "echo '** TEST SUCCEEDED **'")


class ReadyTest(unittest.TestCase):
    def test_ready_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            proj = fx.repo / "PROJECT.md"
            proj.write_text(proj.read_text().replace("echo 'Ran 3 tests in 0.01s'; echo OK", xcode_test_cmd(fx)))
            fx.git("commit", "-qam", "cmd")
            r = fx.run("--build", "7")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(r.stdout.strip().splitlines()[-1], "Ready: 9 tests pass, 2 screens")
            out = fx.repo / "release-evidence" / "7"
            data = json.loads((out / "evidence.json").read_text())
            self.assertEqual((data["app"], data["version"], data["build"]), ("Demo", "1.4", "7"))
            self.assertEqual(data["commit"], fx.git("rev-parse", "HEAD").strip())
            self.assertEqual(data["tests"]["passed"], 9)
            self.assertEqual(data["tests"]["skipped"], 1)
            self.assertEqual(data["tests"]["exit_code"], 0)
            self.assertFalse(data["under_load"])
            self.assertIsNone(data["override"])
            self.assertTrue(data["ready"])
            self.assertEqual(data["missing"], [])
            shots = {s["path"]: s for s in data["screenshots"]}
            self.assertEqual(sorted(shots), ["home-dark.png", "home-light.png"])  # iPhone images only
            self.assertEqual(shots["home-dark.png"]["appearance"], "dark")
            self.assertEqual(shots["home-light.png"]["sha256"],
                             hashlib.sha256((out / "home-light.png").read_bytes()).hexdigest())
            self.assertTrue((out / "index.html").is_file())
            # Only evidence.json (and the folder's own ignore rule) reach git.
            status = fx.git("status", "--porcelain", "--untracked-files=all")
            self.assertEqual(sorted(line[3:] for line in status.splitlines()),
                             ["release-evidence/7/.gitignore", "release-evidence/7/evidence.json"])

    def test_build_number_from_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            r = fx.run()
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertEqual(data["build"], "7")
            self.assertIn("screenshots", r.stdout)  # no xcresult from this run -> missing screenshots

    def test_counts_from_logs(self):
        log = ("Test Suite 'All tests' passed at 2026-11-13\n"
               "\t Executed 12 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 (0.2) seconds\n"
               "✔ Test run with 5 tests in 2 suites passed after 0.01 seconds.\n"
               "Ran 4 tests in 0.002s\n\nOK (skipped=1)\n")
        c = ev.parse_counts(log)
        self.assertEqual(c, {"passed": 19, "failed": 0, "skipped": 2, "found": True})
        bad = "Ran 3 tests in 0.1s\n\nFAILED (failures=1, errors=1)\n✘ Test run with 4 tests failed after 1 seconds with 2 issues.\n"
        c = ev.parse_counts(bad)
        self.assertEqual((c["failed"], c["passed"]), (4, 3))
        self.assertFalse(ev.parse_counts("nothing here")["found"])


class MissingTest(unittest.TestCase):
    def check_missing(self, fx, want, *args):
        r = fx.run(*args)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(want, r.stdout)
        self.assertTrue(r.stdout.strip().splitlines()[-1].startswith("Missing: "))
        return r

    def test_failing_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, test_cmd="echo 'Ran 2 tests in 0.01s'; echo 'FAILED (failures=1)'; exit 1")
            self.check_missing(fx, "tests failed (exit 1)", "--build", "7")

    def test_no_test_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, test_cmd="echo hello")
            self.check_missing(fx, "no test summary", "--build", "7")

    def test_no_screenshots(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, screenshots=False)
            proj = fx.repo / "PROJECT.md"
            proj.write_text(proj.read_text().replace("echo 'Ran 3 tests in 0.01s'; echo OK", xcode_test_cmd(fx)))
            fx.git("commit", "-qam", "cmd")
            self.check_missing(fx, "no screenshots", "--build", "7")

    def test_no_build_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, build_setting=False)
            self.check_missing(fx, "no build number")

    def test_no_test_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            (fx.repo / "PROJECT.md").write_text("# no command\n")
            fx.git("commit", "-qam", "x")
            self.check_missing(fx, "no test command", "--build", "7")

    def test_dirty_tree_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, test_cmd="touch ran-tests; echo 'Ran 1 test in 0.01s'; echo OK")
            (fx.repo / "PROJECT.md").write_text((fx.repo / "PROJECT.md").read_text() + "\nedit\n")
            r = self.check_missing(fx, "uncommitted changes", "--build", "7")
            self.assertFalse((fx.repo / "ran-tests").exists())  # refused before running anything
            self.assertFalse((fx.repo / "release-evidence").exists())


class OverrideTest(unittest.TestCase):
    def test_override_passes_and_is_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp, screenshots=False)
            r = fx.run("--build", "7", HIVE_EVIDENCE_OVERRIDE="hotfix for a crash, UI tests broken upstream")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(r.stdout.strip().splitlines()[-1],
                             "Override: hotfix for a crash, UI tests broken upstream")
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertEqual(data["override"], "hotfix for a crash, UI tests broken upstream")
            self.assertFalse(data["ready"])
            self.assertIn("no screenshots", " ".join(data["missing"]))
            self.assertIn("Released build 7 with override: hotfix for a crash, UI tests broken upstream",
                          (fx.repo / "HANDOFF.md").read_text())


class XcresultScopeTest(unittest.TestCase):
    def test_other_apps_bundle_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            other = fx.dd / "OtherApp-xyz" / "Logs" / "Test" / "Test-OtherApp-now.xcresult"
            proj = fx.repo / "PROJECT.md"
            proj.write_text(proj.read_text().replace("echo 'Ran 3 tests in 0.01s'; echo OK",
                                                     f"mkdir -p '{other}'; echo 'Ran 3 tests in 0.01s'; echo OK"))
            fx.git("commit", "-qam", "cmd")
            r = fx.run("--build", "7")
            self.assertEqual(r.returncode, 1)
            self.assertIn("no screenshots", r.stdout)
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertEqual(data["tests"]["passed"], 3)
            self.assertEqual(data["xcresult"], [])

    def test_two_bundles_both_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            two = xcode_test_cmd(fx) + " && " + xcode_test_cmd(fx).replace("Test-Demo-now", "Test-Demo-later")
            proj = fx.repo / "PROJECT.md"
            proj.write_text(proj.read_text().replace("echo 'Ran 3 tests in 0.01s'; echo OK", two))
            fx.git("commit", "-qam", "cmd")
            r = fx.run("--build", "7")
            self.assertEqual(r.returncode, 0, r.stdout)
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertEqual(data["tests"]["passed"], 18)  # 9 per bundle, printed summaries not added
            self.assertEqual(len(data["xcresult"]), 2)
            self.assertEqual(len(data["screenshots"]), 4)  # same names from both runs kept apart

    def test_without_xcodebuild(self):
        text = ("Ran 2 tests in 0s\n\nOK\nCommand line invocation:\n  xcodebuild test\n"
                "Test Suite 'All tests' passed\n\t Executed 5 tests, with 0 failures (0 unexpected) in 1 (1) seconds\n"
                "** TEST SUCCEEDED **\nRan 1 test in 0s\n\nOK\n")
        self.assertEqual(ev.parse_counts(ev.without_xcodebuild(text))["passed"], 3)
        self.assertEqual(ev.parse_counts(text)["passed"], 8)


class GuardTest(unittest.TestCase):
    def test_runs_through_heavy_guard_and_records_under_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            guard = fx.root / "guard"
            guard.write_text('#!/bin/sh\necho "$1 $2" > "$GUARD_LOG"; shift 3; "$@"; rc=$?\n'
                             'echo "heavy-guard: ran under load (load 40.0)" >&2; exit $rc\n')
            guard.chmod(0o755)
            fx.run("--build", "7", HEAVY_GUARD_BIN=str(guard), GUARD_LOG=str(fx.root / "g.log"))
            self.assertEqual((fx.root / "g.log").read_text().strip(), "--retry-quiet Demo-tests")
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertTrue(data["under_load"])
            self.assertFalse(data["quiet_rerun"])

    def test_quiet_rerun_counts_only_the_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(tmp)
            fx.run("--build", "6")
            plain = json.loads((fx.repo / "release-evidence" / "6" / "evidence.json").read_text())["tests"]
            guard = fx.root / "guard"
            guard.write_text('#!/bin/sh\nshift 3\n'
                             'printf "Ran 9 tests in 0s\\n\\nFAILED (failures=2)\\n"\n'
                             'echo "heavy-guard: ran under load (load 40.0)" >&2\n'
                             'echo "heavy-guard: failed under load (exit 1); rerunning on a quiet Mac" >&2\n'
                             '"$@"; rc=$?\n'
                             'echo "heavy-guard: failed under load, passed on quiet rerun" >&2; exit $rc\n')
            guard.chmod(0o755)
            fx.run("--build", "7", HEAVY_GUARD_BIN=str(guard))
            data = json.loads((fx.repo / "release-evidence" / "7" / "evidence.json").read_text())
            self.assertEqual(data["tests"]["passed"], plain["passed"])
            self.assertEqual(data["tests"]["failed"], 0)
            self.assertFalse(data["under_load"])
            self.assertTrue(data["quiet_rerun"])


class FeedTest(unittest.TestCase):
    def test_feed_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp, "evidence.json")
            f.write_text(json.dumps({"app": "Demo", "version": "1.4", "build": "7", "commit": "abc", "ready": True,
                                     "override": None, "tests": {"passed": 9}, "screenshots": [{}, {}],
                                     "under_load": False, "created_at": "2026-11-13T23:00:00Z"}))
            r = subprocess.run([sys.executable, "-I", str(EVIDENCE), "--feed", str(f)], capture_output=True, text=True)
            doc = json.loads(r.stdout)
            self.assertEqual((doc["schema"], doc["app"]), (1, "releases"))
            self.assertRegex(doc["written_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
            self.assertEqual(doc["summary"]["screens"], 2)
            self.assertEqual(doc["summary"]["tests_passed"], 9)
            self.assertTrue(doc["summary"]["ready"])


class ChangesTest(unittest.TestCase):
    """Release 14: what changed since the last build, and which of it to check on the phone."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        for args in (["init", "-q", "-b", "main"], ["config", "user.name", "t"],
                     ["config", "user.email", "t@example.invalid"], ["config", "commit.gpgsign", "false"]):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, files, subject):
        for name in files:
            f = self.repo / name
            f.parent.mkdir(parents=True, exist_ok=True)
            if not f.exists():  # a file the test wrote itself keeps its content
                f.write_text(subject + name)
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", subject], check=True)
        return ev.git(self.repo, "rev-parse", "HEAD").strip()

    def test_phone_files(self):
        for path in ("App/ReportView.swift", "AppKit/Sources/AppKit/Glance.swift", "App/Info.plist",
                     "App/Assets.xcassets/AppIcon.appiconset/icon.png", "Config/App.xcconfig"):
            self.assertTrue(ev.phone_file(path), path)
        for path in ("AppKit/Tests/AppKitTests/GlanceTests.swift", "AppUITests/SmokeTests.swift", "HANDOFF.md",
                     "release-evidence/7/evidence.json", "docs/x.json", "scripts/x.py", "AppKit/Package.swift",
                     "AppKit/Package.resolved", "restore-evidence/2026-11-18-app.json", "load-evidence/x.json"):
            self.assertFalse(ev.phone_file(path), path)

    def test_changes_since_the_previous_build(self):
        first = self.commit(["App/A.swift"], "First (#1)")
        (self.repo / "release-evidence" / "20990101.1000").mkdir(parents=True)
        (self.repo / "release-evidence" / "20990101.1000" / "evidence.json").write_text(json.dumps({"commit": first, "ready": True}))
        self.commit(["release-evidence/20990101.1000/evidence.json"], "Release evidence for 20990101.1000 (#2)")
        self.commit(["App/Card.swift", "AppTests/CardTests.swift"], "New card (#3)")
        head = self.commit(["HANDOFF.md", "AppKit/Tests/AppKitTests/T.swift"], "Docs and tests only")
        # A later attempt that failed (not uploaded) is never the baseline; nor is a ready one never uploaded.
        for name, data in (("20990101.1100", {"commit": first, "ready": False, "changes": []}),
                           ("20990101.1200", {"commit": first, "ready": True, "changes": []})):
            (self.repo / "release-evidence" / name).mkdir(parents=True)
            (self.repo / "release-evidence" / name / "evidence.json").write_text(json.dumps(data))
        build, base = ev.previous_release(self.repo, "20990102.1000")
        self.assertEqual((build, base), ("20990101.1000", first))  # a pre-1.21 file: committed, so it was uploaded
        self.assertEqual(ev.previous_release(self.repo, "20990101.1000"), (None, None))  # never itself or later
        changes = ev.changes_since(self.repo, base, head)
        self.assertEqual(changes, [{"title": "Docs and tests only", "pr": None, "phone": False},
                                   {"title": "New card", "pr": 3, "phone": True}])
        self.assertEqual(ev.changes_since(self.repo, None, head), [])
        self.assertEqual(ev.changes_since(self.repo, "0" * 40, head), [])  # unknown base: nothing claimed


class UploadedTest(unittest.TestCase):
    def test_uploaded_marks_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp, "evidence.json")
            f.write_text(json.dumps({"commit": "abc", "ready": True, "changes": []}))
            self.assertEqual(ev.main(["--uploaded", str(f)]), 0)
            self.assertRegex(json.loads(f.read_text())["uploaded_at"], r"^\d{4}-\d\d-\d\dT")
            os.makedirs(Path(tmp, "release-evidence", "7"))
            os.replace(f, Path(tmp, "release-evidence", "7", "evidence.json"))
            self.assertEqual(ev.previous_release(Path(tmp), "8"), ("7", "abc"))


class FeedMergeTest(unittest.TestCase):
    def test_newest_release_of_every_app(self):
        this = {"app": "Demo", "build": "9", "ready": True, "created_at": "2026-11-18T10:00:00Z",
                "changes": [{"title": "New card", "pr": 3, "phone": True}, {"title": "Docs", "pr": None, "phone": False}]}
        prev = {"summary": {"app": "Other", "build": "5", "at": "2026-11-10T00:00:00Z", "apps": [
            {"app": "Other", "build": "5", "at": "2026-11-10T00:00:00Z"},
            {"app": "Demo", "build": "8", "at": "2026-11-09T00:00:00Z"},
            {"app": "Third", "build": "2", "at": "2026-11-12T00:00:00Z"}]}}
        s = ev.feed_envelope(this, previous=prev)["summary"]
        self.assertEqual((s["app"], s["build"]), ("Demo", "9"))  # top level stays this release (old readers)
        self.assertEqual([(a["app"], a["build"]) for a in s["apps"]], [("Demo", "9"), ("Third", "2"), ("Other", "5")])
        self.assertEqual(s["changes"], ["New card", "Docs"])
        self.assertEqual(s["checks"], ["New card"])
        self.assertTrue(all("apps" not in a for a in s["apps"]))
        # An old single-release file still counts as that app's newest release.
        old = {"summary": {"app": "Other", "build": "4", "at": "2026-11-01T00:00:00Z"}}
        self.assertEqual([a["app"] for a in ev.feed_envelope(this, previous=old)["summary"]["apps"]], ["Demo", "Other"])

    def test_feed_cli_with_a_missing_previous_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp, "evidence.json")
            f.write_text(json.dumps({"app": "Demo", "build": "7", "ready": True}))
            r = subprocess.run([sys.executable, "-I", str(EVIDENCE), "--feed", str(f), "--previous", str(Path(tmp, "nope"))],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual([a["app"] for a in json.loads(r.stdout)["summary"]["apps"]], ["Demo"])
            r = subprocess.run([sys.executable, "-I", str(EVIDENCE), "--feed", str(f), "--other"], capture_output=True)
            self.assertEqual(r.returncode, 2)


class CommandsTest(unittest.TestCase):
    def test_test_commands_include_ui_smoke(self):
        line = ("- **Test command:** `python3 -I -m unittest discover -s planner/tests && swift test` (from the root). "
                "The UI smoke test on a simulator runs on the Mac only: "
                "`~/agent-rules/scripts/heavy-guard x-ui -- xcodebuild -project X.xcodeproj -scheme X test`. Extra `text`.")
        self.assertEqual(ev.test_commands(line), [
            "python3 -I -m unittest discover -s planner/tests && swift test",
            "~/agent-rules/scripts/heavy-guard x-ui -- xcodebuild -project X.xcodeproj -scheme X test"])

    def test_screen_name(self):
        self.assertEqual(ev.screen_name("walk-largest-card_0_EA6A50A2-58F1-4DD7-A28E-3CDB9EBAEEB2.png"),
                         "walk-largest-card.png")
        self.assertEqual(ev.screen_name("plain.png"), "plain.png")


if __name__ == "__main__":
    unittest.main(verbosity=1)
