#!/bin/sh
# Checks scripts/testflight.sh without Xcode: usage errors, a missing Team ID, the --dry-run commands, the release
# evidence gate, the reminder's evidence line and the Hive feed publish (all tools faked: no network).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
sh "$here/testflight.sh" 2>/dev/null && fail "no arguments should fail" || [ $? -eq 2 ] || fail "usage exit code"
mkdir -p "$t/app/Config"
out=$(sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run 2>&1) && fail "no Team ID should fail" || true
echo "$out" | grep -q "no Team ID" || fail "Team ID message"
echo "DEVELOPMENT_TEAM = ABCDE12345" > "$t/app/Config/Signing.xcconfig"
out=$(sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run 2>&1) && fail "missing ExportOptions should fail" || true
echo "$out" | grep -q "ExportOptions.plist is missing" || fail "ExportOptions message"
cp "$here/ExportOptions.plist" "$t/app/Config/"
out=$(sh "$here/testflight.sh" "$t/app" Demo "Demo App" --dry-run)
echo "$out" | grep -q "xcodebuild archive -project $t/app/Demo.xcodeproj -scheme Demo" || fail "archive command: $out"
echo "$out" | grep -q -- "-exportOptionsPlist $t/app/Config/ExportOptions.plist" || fail "export command"
echo "$out" | grep -q "authenticationKey" && fail "no API key unless set"
printf 'DEVELOPMENT_TEAM = ZZZZZ99999\n' > "$t/other.xcconfig"
HIVE_SIGNING="$t/other.xcconfig" sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run | grep -q -- "-xcconfig $t/other.xcconfig" || fail "HIVE_SIGNING"
HIVE_BUILD=20991231.1 sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run | grep -q "CURRENT_PROJECT_VERSION=20991231.1" || fail "HIVE_BUILD"
printf 'DEVELOPMENT_TEAM = ABCDE12345\nASC_KEY_ID = K1\nASC_ISSUER_ID = I1\n' > "$t/app/Config/Signing.xcconfig"
HOME=$t sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run 2>&1 | grep -q "AuthKey_K1.p8 is missing" || fail "key file check"
# A home folder with a space: the key path must reach xcodebuild as one argument.
mkdir -p "$t/my home/.appstoreconnect/private_keys" && touch "$t/my home/.appstoreconnect/private_keys/AuthKey_K1.p8"
cat > "$t/xcodebuild" <<'X'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -authenticationKeyPath ] && echo "KEY=[$2]"; shift; done
X
chmod +x "$t/xcodebuild"
# A fake osascript records the reminder instead of making a real one.
cat > "$t/osascript" <<'X'
#!/bin/sh
prev=; last=; for a; do prev=$last; last=$a; done; printf '%s\n%s\n' "$prev" "$last" > "$OSA_LOG"
X
chmod +x "$t/osascript"
# A fake App Store Connect: the app record exists, so the check passes.
printf '{"GET /v1/bundleIds?filter[identifier]=com.x.demo&fields[bundleIds]=identifier": [200, {"data": [{"attributes": {"identifier": "com.x.demo"}}]}], "GET /v1/apps?filter[bundleId]=com.x.demo&fields[apps]=bundleId,name": [200, {"data": [{"id": "A1", "attributes": {"bundleId": "com.x.demo"}}]}], "GET /v1/betaGroups?filter[app]=A1&filter[isInternalGroup]=true&include=betaTesters&fields[betaGroups]=name,betaTesters&limit=50": [200, {"data": [{"id": "G1", "relationships": {"betaTesters": {"data": [{"id": "T1"}]}}}]}]}' > "$t/ready.json"
printf '{"GET /v1/bundleIds?filter[identifier]=com.x.demo&fields[bundleIds]=identifier": [200, {"data": [{"attributes": {"identifier": "com.x.demo"}}]}], "GET /v1/apps?filter[bundleId]=com.x.demo&fields[apps]=bundleId,name": [200, {"data": []}]}' > "$t/norecord.json"
mkdir -p "$t/app/Demo.xcodeproj" && echo 'PRODUCT_BUNDLE_IDENTIFIER = com.x.demo;' > "$t/app/Demo.xcodeproj/project.pbxproj"
export HIVE_ASC_FAKE="$t/ready.json" HIVE_ASC_FAKE_LOG="$t/post.log"
# Fake release evidence (evidence.py has its own tests): one that is ready, one that is missing proof. No feed publish.
printf '#!/bin/sh\necho "$@" > "%s/ev.args"; echo "Ready: 3 tests pass, 2 screens"\n' "$t" > "$t/evidence-ok"
printf '#!/bin/sh\necho "- no screenshots"; echo "Missing: no screenshots"; exit 1\n' > "$t/evidence-missing"
chmod +x "$t/evidence-ok" "$t/evidence-missing"
export HIVE_EVIDENCE_CMD="$t/evidence-ok" HIVE_NO_FEED=1
out=$(HOME="$t/my home" PATH="$t:$PATH" HIVE_ASC_FAKE="$t/norecord.json" HIVE_NO_REMIND=1 sh "$here/testflight.sh" "$t/app" Demo Demo 2>&1) && fail "no app record should stop the upload"
echo "$out" | grep -q "NOT READY Demo" || fail "app record message: $out"
echo "$out" | grep -q "KEY=" && fail "archive must not run without an app record"
HOME="$t/my home" sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run | grep -q "asc_check.py $t/app" || fail "dry run shows the check"
out=$(OSA_LOG="$t/osa.log" HIVE_BUILD=7 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo "Demo App")
echo "$out" | grep -q "KEY=\[$t/my home/.appstoreconnect/private_keys/AuthKey_K1.p8\]" || fail "key path split: $out"
[ "$(sed -n 1p "$t/osa.log")" = "Update Demo App in TestFlight (build 7)" ] || fail "reminder title: $(cat "$t/osa.log")"
[ "$(sed -n 2p "$t/osa.log")" = "Ready: 3 tests pass, 2 screens" ] || fail "reminder evidence line: $(cat "$t/osa.log")"
[ "$(cat "$t/ev.args")" = "$t/app --build 7 --app Demo" ] || fail "evidence arguments: $(cat "$t/ev.args")"
echo "$out" | grep -q "Reminder set for 20 minutes" || fail "reminder message"
rm "$t/osa.log"
OSA_LOG="$t/osa.log" HIVE_NO_REMIND=1 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo >/dev/null
[ -f "$t/osa.log" ] && fail "HIVE_NO_REMIND should skip the reminder"
# The archive goes through heavy-guard (a fake one records its arguments, then runs the command).
printf '#!/bin/sh\necho "$@" > "$GUARD_LOG"; shift 2; exec "$@"\n' > "$t/guard" && chmod +x "$t/guard"
out=$(GUARD_LOG="$t/guard.log" HEAVY_GUARD_BIN="$t/guard" HIVE_NO_REMIND=1 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo)
grep -q "^testflight-Demo -- xcodebuild archive" "$t/guard.log" || fail "archive not guarded: $(cat "$t/guard.log" 2>/dev/null)"
echo "$out" | grep -q "KEY=\[$t/my home/" || fail "guarded archive lost its arguments: $out"
# The release evidence gate: shown on a dry run, and missing proof stops the upload before the archive.
HIVE_EVIDENCE_CMD= HIVE_BUILD=7 HOME="$t/my home" sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run | grep -q "evidence.py $t/app --build 7 --app Demo" || fail "dry run shows the evidence gate"
out=$(HIVE_EVIDENCE_CMD="$t/evidence-missing" HIVE_NO_REMIND=1 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo 2>&1) && fail "missing evidence should stop the upload"
echo "$out" | grep -q "Missing: no screenshots" || fail "missing list shown: $out"
echo "$out" | grep -q "was not uploaded" || fail "not-uploaded message: $out"
echo "$out" | grep -q "KEY=" && fail "archive must not run without evidence"
# After the upload the release goes to the Hive feed (`releases`) through hivemind (a fake records the call).
mkdir -p "$t/app/release-evidence/8" && printf '{"app": "Demo", "build": "8", "ready": true, "tests": {"passed": 3}, "screenshots": []}' > "$t/app/release-evidence/8/evidence.json"
printf '#!/bin/sh\necho "$1 $2 $3" > "%s/hm.log"; python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\x27app\x27]==\x27releases\x27 and d[\x27summary\x27][\x27build\x27]==\x278\x27" "$4" || exit 1\n' "$t" > "$t/hm" && chmod +x "$t/hm"
out=$(HIVE_NO_FEED= HIVE_HIVEMIND="$t/hm" HIVE_BUILD=8 HIVE_NO_REMIND=1 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo)
[ "$(cat "$t/hm.log")" = "feed publish releases" ] || fail "feed publish: $(cat "$t/hm.log" 2>/dev/null)"
echo "$out" | grep -q "Published build 8 to the Hive feed" || fail "feed message: $out"
echo "testflight.test.sh: all checks passed"
