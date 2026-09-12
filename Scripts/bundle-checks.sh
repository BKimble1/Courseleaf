# Shared assertions for a built Courseleaf app bundle. Sourced, not executed.
#
# Every check is an assertion with a non-zero exit, not a printout: the point of
# inspecting an archive is to stop a wrong build before it reaches TestFlight,
# and a human reading a log is not a gate.

FAILURES=0
PB=/usr/libexec/PlistBuddy

note() { printf '  %-42s %s\n' "$1" "$2"; }

fail() {
  FAILURES=$((FAILURES + 1))
  printf '  FAIL  %s\n' "$1"
}

plist_get() {  # plist_get <file> <key>  -> value on stdout, empty if absent
  "$PB" -c "Print :$2" "$1" 2>/dev/null || true
}

expect_eq() {  # expect_eq <label> <actual> <expected>
  if [ "$2" = "$3" ]; then note "$1" "$2"; else fail "$1: expected '$3', got '$2'"; fi
}

expect_nonempty() {
  if [ -n "$2" ]; then note "$1" "$(printf '%.70s' "$2")"; else fail "$1 is missing or empty"; fi
}

# Checks that apply to the app bundle whether it came from the archive or the IPA.
check_app_bundle() {  # check_app_bundle <App.app> <version> <build> <teamid>
  # Assertions are the control flow here, so a single failing probe must not
  # abort the caller's `set -e` before the rest of the report is produced.
  local restore; restore=$(set +o | grep errexit)
  set +e
  local app="$1" version="$2" build="$3" team="$4"
  local info="$app/Info.plist"
  [ -f "$info" ] || { fail "no Info.plist in $app"; eval "$restore"; return; }

  echo "-- identity"
  expect_eq "CFBundleIdentifier"           "$(plist_get "$info" CFBundleIdentifier)" "com.idlery.courseleaf"
  expect_eq "CFBundleShortVersionString"   "$(plist_get "$info" CFBundleShortVersionString)" "$version"
  expect_eq "CFBundleVersion"              "$(plist_get "$info" CFBundleVersion)" "$build"
  expect_eq "CFBundleName"                 "$(plist_get "$info" CFBundleName)" "Courseleaf"

  echo "-- built for a device, not a simulator"
  expect_eq "DTPlatformName"               "$(plist_get "$info" DTPlatformName)" "iphoneos"
  local sdk; sdk=$(plist_get "$info" DTSDKName)
  case "$sdk" in iphoneos*) note "DTSDKName" "$sdk";; *) fail "DTSDKName is '$sdk'; a device build must use an iphoneos SDK";; esac
  expect_eq "UIDeviceFamily"               "$(plist_get "$info" UIDeviceFamily:0)" "2"
  local minos; minos=$(plist_get "$info" MinimumOSVersion)
  case "$minos" in 1[89]*|[2-9][0-9]*) note "MinimumOSVersion" "$minos";; *) fail "MinimumOSVersion is '$minos'";; esac

  echo "-- export compliance and permission strings"
  # false because the app ships no cryptography of its own; CryptoKit is used
  # only for SHA-256 digests of asset data, which is not encryption.
  expect_eq "ITSAppUsesNonExemptEncryption" "$(plist_get "$info" ITSAppUsesNonExemptEncryption)" "false"
  expect_nonempty "NSCameraUsageDescription"        "$(plist_get "$info" NSCameraUsageDescription)"
  expect_nonempty "NSPhotoLibraryUsageDescription"  "$(plist_get "$info" NSPhotoLibraryUsageDescription)"
  expect_nonempty "NSPhotoLibraryAddUsageDescription" "$(plist_get "$info" NSPhotoLibraryAddUsageDescription)"

  echo "-- icon"
  local primary; primary=$(plist_get "$info" "CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName")
  [ -n "$primary" ] || primary=$(plist_get "$info" "CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName")
  expect_eq "CFBundleIconName" "$primary" "AppIcon"
  local pngs; pngs=$(find "$app" -maxdepth 1 -name 'AppIcon*.png' | wc -l | tr -d ' ')
  if [ "$pngs" -gt 0 ]; then note "AppIcon*.png in bundle" "$pngs"; else fail "no rendered AppIcon PNGs in the bundle"; fi
  [ -f "$app/Assets.car" ] && note "Assets.car" "present" || fail "no compiled asset catalog"

  echo "-- code signature"
  if codesign -dv "$app" >/dev/null 2>&1; then
    local team_actual; team_actual=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    expect_eq "TeamIdentifier" "$team_actual" "$team"
    local auth; auth=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    expect_nonempty "signing authority" "$auth"
    case "$auth" in
      *Distribution*) note "certificate kind" "distribution";;
      *) fail "signed by '$auth'; TestFlight needs an Apple Distribution certificate";;
    esac
    codesign --verify --strict "$app" 2>&1 && note "codesign --verify" "ok" || fail "code signature does not verify"
    local ents; ents=$(mktemp)
    codesign -d --entitlements :- --xml "$app" > "$ents" 2>/dev/null
    local appid; appid=$(plist_get "$ents" "application-identifier")
    expect_eq "application-identifier" "$appid" "$team.com.idlery.courseleaf"
    local gta; gta=$(plist_get "$ents" "get-task-allow"); [ -n "$gta" ] || gta="absent"
    case "$gta" in false|absent) note "get-task-allow" "$gta";; *) fail "get-task-allow is '$gta'; that is a development signature";; esac
  else
    fail "app bundle is not code signed"
  fi
  eval "$restore"
}

report_failures() {
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
  else
    echo "$FAILURES check(s) failed."
    exit 1
  fi
}
