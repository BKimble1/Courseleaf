#!/usr/bin/env bash
# Generate the Xcode project with XcodeGen and build + test on an iPad simulator.
# Requires macOS with Xcode 16 or newer. Signing is disabled (simulator only).
set -euo pipefail
cd "$(dirname "$0")/../App"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 2; }
xcodebuild -version
xcodegen generate --spec project.yml
if [ -z "${DESTINATION:-}" ]; then
  UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
cands=[]
for runtime,devs in d.items():
    if "iOS" not in runtime: continue
    for dev in devs:
        if "iPad" in dev["name"] and dev.get("isAvailable",False): cands.append((runtime,dev))
cands.sort(key=lambda x:(x[0],x[1]["name"]),reverse=True)
print(cands[0][1]["udid"] if cands else "")')
  [ -n "$UDID" ] || { echo "no available iPad simulator"; xcrun simctl list devices available; exit 3; }
  DESTINATION="platform=iOS Simulator,id=$UDID"
fi
echo "Destination: $DESTINATION"
RESULT="${RESULT_BUNDLE:-$PWD/../Build/CourseleafTests.xcresult}"
rm -rf "$RESULT"
set -o pipefail
xcodebuild test \
  -project Courseleaf.xcodeproj -scheme Courseleaf \
  -destination "$DESTINATION" \
  -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  ${XCODEBUILD_EXTRA:-} | tee "$PWD/../Build/xcodebuild-test.log" | (command -v xcbeautify >/dev/null && xcbeautify || cat)
