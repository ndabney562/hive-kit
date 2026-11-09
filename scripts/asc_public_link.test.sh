#!/bin/sh
# Checks scripts/asc_public_link.py against a fake App Store Connect: copies a missing contact + feedback email
# from the source app, makes the public group, adds the newest VALID build, submits it; --dry-run writes nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mkdir -p "$t/app/Config" "$t/app/Shop.xcodeproj"
printf 'PRODUCT_BUNDLE_IDENTIFIER = com.x.shop;\n' > "$t/app/Shop.xcodeproj/project.pbxproj"
printf 'ASC_KEY_ID = K1\nASC_ISSUER_ID = I1\n' > "$t/app/Config/Signing.xcconfig"
cat > "$t/fake.json" <<'J'
{"GET /v1/apps?filter[bundleId]=com.x.shop": [200, {"data": [{"id": "A"}]}],
 "GET /v1/apps?filter[bundleId]=com.x.src": [200, {"data": [{"id": "S"}]}],
 "GET /v1/apps/A/betaAppReviewDetail": [200, {"data": {"id": "DA", "attributes": {"contactEmail": null}}}],
 "GET /v1/apps/S/betaAppReviewDetail": [200, {"data": {"id": "DS", "attributes": {"contactFirstName": "N", "contactLastName": "D", "contactPhone": "1", "contactEmail": "n@x"}}}],
 "GET /v1/apps/A/betaAppLocalizations": [200, {"data": []}],
 "GET /v1/apps/S/betaAppLocalizations": [200, {"data": [{"attributes": {"feedbackEmail": "f@x"}}]}],
 "GET /v1/apps/A/betaGroups": [200, {"data": []}],
 "PATCH /v1/betaAppReviewDetails/DA": [200, {"data": {}}],
 "POST /v1/betaAppLocalizations": [201, {"data": {}}],
 "POST /v1/betaGroups": [201, {"data": {"id": "G", "attributes": {"publicLink": "https://testflight.apple.com/join/abc"}}}],
 "GET /v1/builds?filter[app]=A&sort=-uploadedDate&limit=5": [200, {"data": [{"id": "B2", "attributes": {"version": "2", "processingState": "PROCESSING"}}, {"id": "B1", "attributes": {"version": "1", "processingState": "VALID"}}]}],
 "POST /v1/betaGroups/G/relationships/builds": [204, {}],
 "POST /v1/betaAppReviewSubmissions": [201, {"data": {}}]}
J
export HIVE_ASC_FAKE="$t/fake.json" HIVE_ASC_FAKE_LOG="$t/log"
run() { python3 -I "$here/asc_public_link.py" "$t/app" --group Surprise --description "Hi" --contact-from com.x.src "$@"; }
out=$(run --dry-run) || fail "dry run: $out"
[ -f "$t/log" ] && fail "dry run must write nothing"
echo "$out" | grep -q "would submit build 1" || fail "dry run names the valid build: $out"
out=$(run) || fail "run: $out"
grep -q '"contactEmail": "n@x"' "$t/log" || fail "contact copied: $(cat "$t/log")"
grep -q '"feedbackEmail": "f@x"' "$t/log" || fail "feedback email copied"
grep -q '"publicLinkEnabled": true' "$t/log" || fail "public group made"
grep -q '"id": "B1"' "$t/log" && ! grep -q '"id": "B2"' "$t/log" || fail "only the VALID build"
echo "$out" | grep -q "public link: https://testflight.apple.com/join/abc" || fail "prints the link: $out"
# Source with no contact: stop, write nothing.
rm "$t/log"; sed 's/"n@x"/null/' "$t/fake.json" > "$t/nc.json"
(HIVE_ASC_FAKE="$t/nc.json"; run >/dev/null 2>&1) && fail "no contact to copy should fail"
[ -f "$t/log" ] && fail "no contact: nothing written"
# Codex round 1: Apple's 204 has no body; nested apps (HiveMind: apps/ios); a localization missing fields is
# filled; a REJECTED build is a failure, not "already submitted".
python3 -I -c "import sys; sys.path.insert(0, '$here'); import asc_check; assert asc_check.parse(b'') == {} and asc_check.parse(b'{\"a\": 1}') == {'a': 1}" || fail "empty 204 body"
mkdir -p "$t/mono/apps/ios"; cp -R "$t/app/Config" "$t/app/Shop.xcodeproj" "$t/mono/apps/ios/"
rm -f "$t/log"; out=$(python3 -I "$here/asc_public_link.py" "$t/mono" --group Surprise --description Hi --contact-from com.x.src) || fail "nested app: $out"
sed 's|"GET /v1/apps/A/betaAppLocalizations": \[200, {"data": \[\]}\]|"GET /v1/apps/A/betaAppLocalizations": [200, {"data": [{"id": "L", "attributes": {"locale": "en-US", "description": null, "feedbackEmail": null}}]}], "PATCH /v1/betaAppLocalizations/L": [200, {"data": {}}]|' "$t/fake.json" > "$t/loc.json"
rm -f "$t/log"; (HIVE_ASC_FAKE="$t/loc.json"; run >/dev/null) || fail "partial localization run"
grep -q '"path": "/v1/betaAppLocalizations/L"' "$t/log" && grep -q '"description": "Hi"' "$t/log" && grep -q '"feedbackEmail": "f@x"' "$t/log" || fail "partial localization patched: $(cat "$t/log")"
sed 's|"POST /v1/betaAppReviewSubmissions"|"GET /v1/builds/B1/betaAppReviewSubmission": [200, {"data": {"attributes": {"betaReviewState": "REJECTED"}}}], "POST /v1/betaAppReviewSubmissions"|' "$t/fake.json" > "$t/rej.json"
out=$(HIVE_ASC_FAKE="$t/rej.json"; run) && fail "rejected build should fail"
echo "$out" | grep -q "REJECTED" || fail "rejected message: $out"
echo "asc_public_link: all checks passed"
