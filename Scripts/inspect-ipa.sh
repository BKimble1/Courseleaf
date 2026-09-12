#!/usr/bin/env bash
# Assert that the exported IPA is a distribution build of the right app before
# anything is uploaded.
#   Scripts/inspect-ipa.sh <Courseleaf.ipa> <version> <build> <teamID>
set -euo pipefail
IPA="${1:?usage: inspect-ipa.sh <ipa> <version> <build> <teamID>}"
VERSION="${2:?}"; BUILD="${3:?}"; TEAM="${4:?}"
. "$(dirname "$0")/bundle-checks.sh"

echo "===== IPA inspection: $IPA ====="
ls -lh "$IPA" | awk '{print "  size:", $5}'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP=$(ls -d "$WORK"/Payload/*.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "FAIL  no Payload/*.app inside the IPA"; unzip -l "$IPA" | head -20; exit 1; }
echo "app: Payload/$(basename "$APP")"

check_app_bundle "$APP" "$VERSION" "$BUILD" "$TEAM"

echo "-- embedded provisioning profile"
PROFILE="$APP/embedded.mobileprovision"
if [ -f "$PROFILE" ]; then
  PLIST="$WORK/profile.plist"
  security cms -D -i "$PROFILE" > "$PLIST" 2>/dev/null || openssl smime -inform der -verify -noverify -in "$PROFILE" > "$PLIST" 2>/dev/null
  expect_nonempty "profile name" "$(plist_get "$PLIST" Name)"
  expect_eq "profile team" "$(plist_get "$PLIST" TeamIdentifier:0)" "$TEAM"
  # An App Store distribution profile provisions no specific devices and is not
  # marked as provisioning all devices (that is the enterprise/ad-hoc shape).
  DEVICES=$(plist_get "$PLIST" ProvisionedDevices)
  if [ -z "$DEVICES" ]; then note "ProvisionedDevices" "none (App Store profile)"; else fail "profile lists specific devices; that is ad hoc, not App Store"; fi
  EXPIRY=$(plist_get "$PLIST" ExpirationDate)
  expect_nonempty "ExpirationDate" "$EXPIRY"
else
  fail "no embedded.mobileprovision in the app"
fi

report_failures
