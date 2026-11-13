#!/bin/sh
# Checks scripts/asc_check.py against a fake App Store Connect (HIVE_ASC_FAKE): ready, missing app record, no tester group,
# bundle ID registered when missing, --no-register, no key, test bundle IDs ignored, nested apps, DER signature conversion.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
check() { HOME="$t/home" python3 -I "$here/asc_check.py" "$@"; }
mkdir -p "$t/home/.appstoreconnect/private_keys" "$t/app/Config" "$t/app/Shop.xcodeproj"
touch "$t/home/.appstoreconnect/private_keys/AuthKey_K1.p8"
printf 'PRODUCT_BUNDLE_IDENTIFIER = com.x.shop.uitests;\nPRODUCT_BUNDLE_IDENTIFIER = com.x.shop;\nPRODUCT_BUNDLE_IDENTIFIER = "com.x.shop.Tests";\n' > "$t/app/Shop.xcodeproj/project.pbxproj"
# No key yet.
out=$(check "$t/app" 2>&1) && fail "no key should fail"; [ $? -eq 2 ] || true
echo "$out" | grep -q "can't check com.x.shop" || fail "no-key message: $out"
printf 'ASC_KEY_ID = K1\nASC_ISSUER_ID = I1\n' > "$t/app/Config/Signing.xcconfig"
B='"GET /v1/bundleIds?filter[identifier]=com.x.shop&fields[bundleIds]=identifier"'
A='"GET /v1/apps?filter[bundleId]=com.x.shop&fields[apps]=bundleId,name"'
G='"GET /v1/betaGroups?filter[app]=A1&filter[isInternalGroup]=true&include=betaTesters&fields[betaGroups]=name,betaTesters&limit=50"'
printf '{%s: [200, {"data": [{"attributes": {"identifier": "com.x.shop"}}]}], %s: [200, {"data": [{"id": "A1", "attributes": {"bundleId": "com.x.shop"}}]}], %s: [200, {"data": [{"id": "G1", "attributes": {"name": "Me"}, "relationships": {"betaTesters": {"data": [{"type": "betaTesters", "id": "T1"}]}}}]}]}' "$B" "$A" "$G" > "$t/ready.json"
printf '{%s: [200, {"data": [{"attributes": {"identifier": "com.x.shop"}}]}], %s: [200, {"data": [{"id": "A1", "attributes": {"bundleId": "com.x.shop"}}]}], %s: [200, {"data": [{"id": "G1", "attributes": {"name": "Me"}, "relationships": {"betaTesters": {"data": []}}}]}]}' "$B" "$A" "$G" > "$t/nogroup.json"
printf '{%s: [200, {"data": []}], "POST /v1/bundleIds": [201, {"data": {"id": "X"}}], %s: [200, {"data": []}]}' "$B" "$A" > "$t/new.json"
export HIVE_ASC_FAKE_LOG="$t/post.log"
out=$(HIVE_ASC_FAKE="$t/ready.json" check "$t/app") || fail "ready app should pass: $out"
echo "$out" | grep -q "READY Shop: com.x.shop" || fail "ready message (test IDs must be ignored): $out"
[ -f "$t/post.log" ] && fail "a ready app must not register anything"
out=$(HIVE_ASC_FAKE="$t/new.json" check "$t/app") && fail "missing app record should fail"
echo "$out" | grep -q "Registered bundle ID com.x.shop" || fail "registers the bundle ID: $out"
grep -q '"identifier": "com.x.shop", "name": "Shop", "platform": "IOS"' "$t/post.log" || fail "register body: $(cat "$t/post.log")"
echo "$out" | grep -q "NOT READY Shop: App Store Connect has no app" || fail "app record steps: $out"
echo "$out" | grep -q "Bundle ID com.x.shop; SKU shop" || fail "steps name the bundle ID"
rm "$t/post.log"
# No internal TestFlight group with a tester: builds never reach Noah (HiveWorld + HiveBeat, 2026-11-13).
out=$(HIVE_ASC_FAKE="$t/nogroup.json" check "$t/app") && fail "no tester group should fail"
echo "$out" | grep -q "NOT READY Shop: no internal TestFlight group with a tester" || fail "tester group message: $out"
echo "$out" | grep -q "Internal Testing" || fail "tester group steps: $out"
[ -f "$t/post.log" ] && fail "the tester group check must only read"
out=$(HIVE_ASC_FAKE="$t/new.json" check "$t/app" --no-register) && fail "--no-register should fail"
echo "$out" | grep -q "is not registered" || fail "--no-register message: $out"
[ -f "$t/post.log" ] && fail "--no-register must not register"
# An app kept in a subfolder (HiveMind: apps/ios) is found; build output folders are not.
mkdir -p "$t/mono/apps/ios/Config" "$t/mono/apps/ios/Shop.xcodeproj" "$t/mono/.build/x/Old.xcodeproj"
cp "$t/app/Shop.xcodeproj/project.pbxproj" "$t/mono/apps/ios/Shop.xcodeproj/"
cp "$t/app/Config/Signing.xcconfig" "$t/mono/apps/ios/Config/"
printf 'PRODUCT_BUNDLE_IDENTIFIER = com.x.old;\n' > "$t/mono/.build/x/Old.xcodeproj/project.pbxproj"
out=$(HIVE_ASC_FAKE="$t/ready.json" check "$t/mono") || fail "nested app should pass: $out"
echo "$out" | grep -q "READY Shop: com.x.shop" || fail "nested app message: $out"
# A DER signature with a leading zero byte in r turns into exactly 64 bytes.
python3 -I -c "
import sys; sys.path.insert(0, '$here'); from asc_check import der_to_raw
r = b'\x00' + b'\x81' * 32; s = b'\x01' * 31
der = bytes([0x30, 4 + len(r) + len(s), 2, len(r)]) + r + bytes([2, len(s)]) + s
raw = der_to_raw(der); assert raw == b'\x81' * 32 + b'\x00' + b'\x01' * 31, raw
" || fail "DER to raw"
echo "asc_check.test.sh: all checks passed"
