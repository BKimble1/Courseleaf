#!/usr/bin/env bash
# Assert that an .xcarchive is the build we meant to ship, before exporting it.
#   Scripts/inspect-archive.sh <Courseleaf.xcarchive> <version> <build> <teamID>
set -euo pipefail
ARCHIVE="${1:?usage: inspect-archive.sh <xcarchive> <version> <build> <teamID>}"
VERSION="${2:?}"; BUILD="${3:?}"; TEAM="${4:?}"
. "$(dirname "$0")/bundle-checks.sh"

echo "===== archive inspection: $ARCHIVE ====="
APP=$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "FAIL  no .app inside the archive"; exit 1; }
echo "app: $APP"

ARCHIVE_INFO="$ARCHIVE/Info.plist"
echo "-- archive metadata"
expect_eq "ApplicationProperties:CFBundleIdentifier" \
  "$(plist_get "$ARCHIVE_INFO" "ApplicationProperties:CFBundleIdentifier")" "com.idlery.courseleaf"
expect_eq "ApplicationProperties:CFBundleShortVersionString" \
  "$(plist_get "$ARCHIVE_INFO" "ApplicationProperties:CFBundleShortVersionString")" "$VERSION"
expect_eq "ApplicationProperties:CFBundleVersion" \
  "$(plist_get "$ARCHIVE_INFO" "ApplicationProperties:CFBundleVersion")" "$BUILD"
expect_eq "ApplicationProperties:Team" \
  "$(plist_get "$ARCHIVE_INFO" "ApplicationProperties:Team")" "$TEAM"
expect_nonempty "ApplicationProperties:SigningIdentity" \
  "$(plist_get "$ARCHIVE_INFO" "ApplicationProperties:SigningIdentity")"

# Automatic signing creates a development-signed archive; exportArchive then
# re-signs the IPA with Apple Distribution. The IPA gate enforces distribution.
check_app_bundle "$APP" "$VERSION" "$BUILD" "$TEAM" development

echo "-- dSYMs"
DSYMS=$(find "$ARCHIVE/dSYMs" -maxdepth 1 -name '*.dSYM' 2>/dev/null | wc -l | tr -d ' ')
[ "${DSYMS:-0}" -gt 0 ] && note "dSYM bundles" "$DSYMS" || fail "no dSYMs in the archive"

report_failures
