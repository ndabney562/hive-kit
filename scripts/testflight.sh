#!/bin/sh
# Archive a Hive app and upload it to App Store Connect, where it appears under TestFlight. Shared by every Hive app
# (Noah, 2026-11-07: one Hive framework); each app's scripts/testflight.sh is a one-line call to this.
# Usage: testflight.sh <app repo dir> <Xcode project/scheme name> <name shown to you> [--dry-run]
#   (--dry-run prints the two xcodebuild commands and runs nothing)
# Needs the Team ID in <repo>/Config/Signing.xcconfig and <repo>/Config/ExportOptions.plist. Signs in with Xcode's
# Apple ID (Xcode › Settings › Accounts), or with an App Store Connect API key when Signing.xcconfig sets ASC_KEY_ID
# and ASC_ISSUER_ID (key file in ~/.appstoreconnect/private_keys/). HiveTempo saw the key answer "Authentication
# failed" in xcodebuild (2026-11-05), so the Apple ID is the default.
# Optional: <repo>/Config/testflight-note.txt is printed after a successful upload (e.g. a CloudKit reminder).
# After an upload it adds a Reminders item with an alert in 20 minutes ("Update <name> in TestFlight"), which reaches
# the iPhone too (agent rules: a step more than 10 minutes away gets a reminder). HIVE_NO_REMIND=1 turns it off.
set -eu
usage() { echo "usage: testflight.sh <repo dir> <project name> <display name> [--dry-run]" >&2; exit 2; }
[ $# -ge 3 ] || usage
here=$(cd "$1" && pwd)
project=$2
name=$3
dry=0
case "${4:-}" in
  --dry-run) dry=1 ;;
  "") ;;
  *) usage ;;
esac
# HIVE_SIGNING points at another Signing.xcconfig (an app's own tests use a temporary one).
signing=${HIVE_SIGNING:-$here/Config/Signing.xcconfig}
if ! [ -f "$signing" ] || ! grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Za-z0-9]+' "$signing"; then
  echo "testflight.sh: no Team ID. Copy Config/Signing.xcconfig.example to $signing and put your Team ID after DEVELOPMENT_TEAM =" >&2
  exit 1
fi
if ! [ -f "$here/Config/ExportOptions.plist" ]; then
  echo "testflight.sh: $here/Config/ExportOptions.plist is missing (copy it from hive-kit/scripts/ExportOptions.plist)." >&2
  exit 1
fi
if [ "$dry" -eq 0 ] && pgrep -f "xcodebuild.*$project.xcodeproj.*archive" >/dev/null; then
  echo "testflight.sh: another $name archive is running; wait for it." >&2
  exit 1
fi
setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$signing" | tail -1; }
key_id=$(setting ASC_KEY_ID)
issuer=$(setting ASC_ISSUER_ID)
# The API-key arguments, as positional parameters so a path with spaces stays one argument.
set --
if [ -n "$key_id" ] && [ -n "$issuer" ]; then
  key_file=$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8
  if ! [ -f "$key_file" ]; then
    echo "testflight.sh: ASC_KEY_ID is set but $key_file is missing. Download the key from App Store Connect › Users and Access › Integrations." >&2
    exit 1
  fi
  set -- -authenticationKeyPath "$key_file" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer"
fi
# Stop before a 10-minute archive when Apple has no app for this bundle ID (asc_check.py registers a missing bundle
# ID and prints Noah's steps for the app record). Needs the API key; without one it can't check and says so.
if [ -n "$key_id" ] && [ -n "$issuer" ]; then
  if [ "$dry" -eq 1 ]; then
    echo "python3 -I $(dirname "$0")/asc_check.py $here"
  else
    python3 -I "$(dirname "$0")/asc_check.py" "$here" || exit 1
  fi
else
  echo "testflight.sh: no API key, so the App Store Connect app record isn't checked (run asc_check.py by hand)." >&2
fi
# HIVE_BUILD sets the build number by hand: Apple refuses one lower than the last upload (HiveMind, 2026-11-04).
build=${HIVE_BUILD:-$(date +%Y%m%d.%H%M)}
# Release evidence gate (2026-11-13): evidence.py runs the app's tests (through heavy-guard), takes the UI tests'
# iPhone screenshots and writes release-evidence/<build>/evidence.json. Missing proof stops the upload;
# HIVE_EVIDENCE_OVERRIDE="<reason>" releases anyway and records why. HIVE_EVIDENCE_CMD replaces the command in tests.
evidence_py="$(cd "$(dirname "$0")" && pwd)/evidence.py"
evidence() {  # the script path stays one argument even with spaces in it
  if [ -n "${HIVE_EVIDENCE_CMD:-}" ]; then "$HIVE_EVIDENCE_CMD" "$@"; else python3 -I "$evidence_py" "$@"; fi
}
evidence_line=""
if [ "$dry" -eq 1 ]; then
  echo "${HIVE_EVIDENCE_CMD:-python3 -I $evidence_py} $here --build $build --app $project"
else
  if ! evidence_out=$(evidence "$here" --build "$build" --app "$project"); then
    printf '%s\n' "$evidence_out"
    echo "testflight.sh: release evidence is missing, so $name build $build was not uploaded. Fix it, or set HIVE_EVIDENCE_OVERRIDE=\"<reason>\" to release anyway." >&2
    exit 1
  fi
  printf '%s\n' "$evidence_out"
  evidence_line=$(printf '%s\n' "$evidence_out" | tail -1)
fi
archive="$here/build/$project.xcarchive"
run() {
  if [ "$dry" -eq 1 ]; then printf '%s\n' "$*"; else "$@"; fi
}
# The archive runs through agent-rules heavy-guard on Noah's Mac: one heavy job at a time, after load spikes
# pass (it never skips; exit code unchanged). Without heavy-guard it runs directly. HEAVY_GUARD_BIN overrides.
heavy() {
  g="${HEAVY_GUARD_BIN:-$HOME/agent-rules/scripts/heavy-guard}"
  if [ -x "$g" ]; then "$g" "$@"; else shift 2; "$@"; fi
}
run heavy "testflight-$project" -- xcodebuild archive -project "$here/$project.xcodeproj" -scheme "$project" -destination generic/platform=iOS \
  -archivePath "$archive" -allowProvisioningUpdates "$@" -xcconfig "$signing" CURRENT_PROJECT_VERSION="$build"
run xcodebuild -exportArchive -archivePath "$archive" -exportPath "$here/build/export" \
  -exportOptionsPlist "$here/Config/ExportOptions.plist" -allowProvisioningUpdates "$@"
if [ "$dry" -eq 0 ]; then
  echo "Uploaded $name build $build. $evidence_line"
  # Publish the release to the Hive feed (`releases`) when hivemind is here; HIVE_HIVEMIND overrides, HIVE_NO_FEED=1 skips.
  hm=${HIVE_HIVEMIND:-$(command -v hivemind || true)}
  [ -z "$hm" ] && [ -x "$HOME/AI.Stuff/HiveMind/hivemind" ] && hm=$HOME/AI.Stuff/HiveMind/hivemind
  ev_json="$here/release-evidence/$build/evidence.json"
  if [ -z "${HIVE_NO_FEED:-}" ] && [ -n "$hm" ] && [ -f "$ev_json" ]; then
    feed=$(mktemp)
    if python3 -I "$evidence_py" --feed "$ev_json" > "$feed" && "$hm" feed publish releases "$feed" >/dev/null 2>&1; then
      echo "Published build $build to the Hive feed (releases)."
    else
      echo "testflight.sh: couldn't publish build $build to the Hive feed (releases); the upload itself is fine." >&2
    fi
    rm -f "$feed"
  fi
  [ -f "$ev_json" ] && echo "Commit release-evidence/$build/evidence.json (and its .gitignore) with the HANDOFF update."
  echo "Apple processes it in about 15 minutes; then it appears in App Store Connect › $name › TestFlight and in the TestFlight app on your iPhone."
  if [ -f "$here/Config/testflight-note.txt" ]; then cat "$here/Config/testflight-note.txt"; fi
  if [ -z "${HIVE_NO_REMIND:-}" ] && command -v osascript >/dev/null; then
    title="Update $name in TestFlight (build $build)"
    if osascript -e 'on run argv' \
      -e 'tell application "Reminders" to make new reminder with properties {name:(item 1 of argv), body:(item 2 of argv), remind me date:((current date) + 20 * minutes)}' \
      -e 'end run' "$title" "$evidence_line" >/dev/null 2>&1; then
      echo "Reminder set for 20 minutes from now: $title"
    else
      echo "Couldn't set the Reminders alert (allow Terminal in System Settings › Privacy & Security › Reminders)."
    fi
  fi
fi
