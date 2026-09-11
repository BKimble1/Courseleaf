#!/usr/bin/env bash
# Produce an unsigned release archive for inspection. Real signing and App Store
# upload require the owner's team and are done manually (docs/RELEASE_CHECKLIST.md).
set -euo pipefail
cd "$(dirname "$0")/../App"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 2; }
xcodegen generate --spec project.yml
mkdir -p ../Build
xcodebuild archive \
  -project Courseleaf.xcodeproj -scheme Courseleaf -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath ../Build/Courseleaf.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" ${XCODEBUILD_EXTRA:-}
echo "Archive at Build/Courseleaf.xcarchive (unsigned)"
