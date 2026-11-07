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
out=$(HOME="$t/my home" PATH="$t:$PATH" sh "$here/testflight.sh" "$t/app" Demo Demo)
echo "$out" | grep -q "KEY=\[$t/my home/.appstoreconnect/private_keys/AuthKey_K1.p8\]" || fail "key path split: $out"
echo "testflight.test.sh: all checks passed"
