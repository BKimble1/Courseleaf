#!/usr/bin/env bash
# Build a signed Release archive of Courseleaf for a physical iPad and export a
# distribution IPA. macOS with Xcode only; there is no simulator anywhere in it.
#
# Required environment:
#   MARKETING_VERSION   e.g. 1.0.0
#   BUILD_NUMBER        an unused CFBundleVersion for that marketing version
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH
#                       App Store Connect API key, used so Xcode can fetch or
#                       create the distribution certificate and profile itself
# Optional:
#   TEAM_ID             defaults to the team in App/project.yml
#
# Output: Build/Courseleaf.xcarchive and Build/export/Courseleaf.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/Build"
TEAM_ID="${TEAM_ID:-7GNFT94A9L}"
: "${MARKETING_VERSION:?set MARKETING_VERSION}"
: "${BUILD_NUMBER:?set BUILD_NUMBER}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_PRIVATE_KEY_PATH:?set ASC_PRIVATE_KEY_PATH}"
[ -f "$ASC_PRIVATE_KEY_PATH" ] || { echo "no key file at ASC_PRIVATE_KEY_PATH"; exit 2; }

ARCHIVE="$BUILD/Courseleaf.xcarchive"
EXPORT_DIR="$BUILD/export"
mkdir -p "$BUILD"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

echo "===== toolchain ====="
xcodebuild -version
XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
SDK=$(xcodebuild -showsdks | sed -n 's/.*iphoneos\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -1)
SDK_MAJOR=${SDK%%.*}
echo "Xcode major $XCODE_MAJOR, newest iOS SDK $SDK"
# App Store Connect requires Xcode 26 and the iOS 26 SDK for uploads made
# after April 28, 2026. Fail here rather than after a long archive.
[ "${XCODE_MAJOR:-0}" -ge 26 ] || { echo "ERROR: Xcode 26 or newer is required to upload"; exit 2; }
[ "${SDK_MAJOR:-0}" -ge 26 ] || { echo "ERROR: iOS 26 SDK or newer is required to upload (found $SDK)"; exit 2; }

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 2; }
cd "$ROOT/App"
xcodegen generate --spec project.yml

echo "===== archive (generic/platform=iOS, Release, signed) ====="
set +e
set -o pipefail
xcodebuild archive \
  -project Courseleaf.xcodeproj -scheme Courseleaf -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ${XCODEBUILD_EXTRA:-} 2>&1 | tee "$BUILD/xcodebuild-archive.log" | (command -v xcbeautify >/dev/null && xcbeautify || cat)
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "----- archive errors -----"
  grep -E "error:|Provisioning|certificate|Signing" "$BUILD/xcodebuild-archive.log" \
    | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -40 || true
  exit "$status"
fi

"$ROOT/Scripts/inspect-archive.sh" "$ARCHIVE" "$MARKETING_VERSION" "$BUILD_NUMBER" "$TEAM_ID"

echo "===== export distribution IPA ====="
set +e
set -o pipefail
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/Scripts/export-options.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  2>&1 | tee "$BUILD/xcodebuild-export.log" | (command -v xcbeautify >/dev/null && xcbeautify || cat)
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "----- export errors -----"
  grep -E "error:|Provisioning|certificate" "$BUILD/xcodebuild-export.log" \
    | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -40 || true
  exit "$status"
fi

IPA=$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)
[ -n "$IPA" ] || { echo "ERROR: no .ipa produced in $EXPORT_DIR"; ls -la "$EXPORT_DIR"; exit 2; }
"$ROOT/Scripts/inspect-ipa.sh" "$IPA" "$MARKETING_VERSION" "$BUILD_NUMBER" "$TEAM_ID"
echo "IPA: $IPA"
