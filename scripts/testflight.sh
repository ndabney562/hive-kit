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
signing=$here/Config/Signing.xcconfig
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
# HIVE_BUILD sets the build number by hand: Apple refuses one lower than the last upload (HiveMind, 2026-11-04).
build=${HIVE_BUILD:-$(date +%Y%m%d.%H%M)}
archive="$here/build/$project.xcarchive"
run() {
  if [ "$dry" -eq 1 ]; then printf '%s\n' "$*"; else "$@"; fi
}
run xcodebuild archive -project "$here/$project.xcodeproj" -scheme "$project" -destination generic/platform=iOS \
  -archivePath "$archive" -allowProvisioningUpdates "$@" -xcconfig "$signing" CURRENT_PROJECT_VERSION="$build"
run xcodebuild -exportArchive -archivePath "$archive" -exportPath "$here/build/export" \
  -exportOptionsPlist "$here/Config/ExportOptions.plist" -allowProvisioningUpdates "$@"
if [ "$dry" -eq 0 ]; then
  echo "Uploaded $name build $build. Apple processes it in about 15 minutes; then it appears in App Store Connect › $name › TestFlight and in the TestFlight app on your iPhone."
  if [ -f "$here/Config/testflight-note.txt" ]; then cat "$here/Config/testflight-note.txt"; fi
fi
