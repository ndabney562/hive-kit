#!/bin/sh
# Checks scripts/testflight.sh without Xcode: usage errors, a missing Team ID, and the --dry-run commands.
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
for a; do last=$a; done; echo "$last" > "$OSA_LOG"
X
chmod +x "$t/osascript"
# A fake App Store Connect: the app record exists, so the check passes.
printf '{"GET /v1/bundleIds?filter[identifier]=com.x.demo&fields[bundleIds]=identifier": [200, {"data": [{"attributes": {"identifier": "com.x.demo"}}]}], "GET /v1/apps?filter[bundleId]=com.x.demo&fields[apps]=bundleId,name": [200, {"data": [{"attributes": {"bundleId": "com.x.demo"}}]}]}' > "$t/ready.json"
printf '{"GET /v1/bundleIds?filter[identifier]=com.x.demo&fields[bundleIds]=identifier": [200, {"data": [{"attributes": {"identifier": "com.x.demo"}}]}], "GET /v1/apps?filter[bundleId]=com.x.demo&fields[apps]=bundleId,name": [200, {"data": []}]}' > "$t/norecord.json"
mkdir -p "$t/app/Demo.xcodeproj" && echo 'PRODUCT_BUNDLE_IDENTIFIER = com.x.demo;' > "$t/app/Demo.xcodeproj/project.pbxproj"
export HIVE_ASC_FAKE="$t/ready.json" HIVE_ASC_FAKE_LOG="$t/post.log"
out=$(HOME="$t/my home" PATH="$t:$PATH" HIVE_ASC_FAKE="$t/norecord.json" HIVE_NO_REMIND=1 sh "$here/testflight.sh" "$t/app" Demo Demo 2>&1) && fail "no app record should stop the upload"
echo "$out" | grep -q "NOT READY Demo" || fail "app record message: $out"
echo "$out" | grep -q "KEY=" && fail "archive must not run without an app record"
HOME="$t/my home" sh "$here/testflight.sh" "$t/app" Demo Demo --dry-run | grep -q "asc_check.py $t/app" || fail "dry run shows the check"
out=$(OSA_LOG="$t/osa.log" HIVE_BUILD=7 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo "Demo App")
echo "$out" | grep -q "KEY=\[$t/my home/.appstoreconnect/private_keys/AuthKey_K1.p8\]" || fail "key path split: $out"
[ "$(cat "$t/osa.log")" = "Update Demo App in TestFlight (build 7)" ] || fail "reminder title: $(cat "$t/osa.log")"
echo "$out" | grep -q "Reminder set for 20 minutes" || fail "reminder message"
rm "$t/osa.log"
OSA_LOG="$t/osa.log" HIVE_NO_REMIND=1 HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo >/dev/null
[ -f "$t/osa.log" ] && fail "HIVE_NO_REMIND should skip the reminder"
echo "testflight.test.sh: all checks passed"
