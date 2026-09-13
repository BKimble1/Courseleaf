#!/usr/bin/env bash
# Generate the Xcode project with XcodeGen and build + test on an iPad simulator.
# Requires macOS with Xcode 16 or newer. Signing is disabled (simulator only).
set -euo pipefail
cd "$(dirname "$0")/../App"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 2; }
xcodebuild -version
xcodegen generate --spec project.yml
if [ -z "${DESTINATION:-}" ]; then
  # Deterministic, and the largest iPad available. "Whichever iPad sorts last"
  # used to decide this, which meant an iPad mini could run the UI tests: a
  # different screen width is a different toolbar tier and different
  # screenshots, so the same commit passed or failed depending on what Xcode
  # happened to install.
  SIM=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["devices"]
def rank(name):
    # Bigger screens first; within a class, prefer the plain Pro name.
    for i,pat in enumerate([r"iPad Pro.*\b13[- ]inch", r"iPad Pro.*\b12\.9[- ]inch",
                            r"iPad Pro.*\b11[- ]inch", r"iPad Air.*\b13[- ]inch",
                            r"iPad Air", r"^iPad \(", r"iPad"]):
        if re.search(pat, name): return i
    return 99
def runtime_key(r):
    m = re.search(r"iOS-(\d+)-(\d+)", r)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
cands=[]
for runtime,devs in d.items():
    if "iOS" not in runtime: continue
    for dev in devs:
        if "iPad" in dev["name"] and dev.get("isAvailable",False):
            cands.append((rank(dev["name"]), [-x for x in runtime_key(runtime)], dev["name"], dev["udid"]))
cands.sort(key=lambda c:(c[0], c[1], c[2]))
print("%s\t%s" % (cands[0][3], cands[0][2]) if cands else "")')
  UDID=${SIM%%$'\t'*}
  [ -n "$UDID" ] || { echo "no available iPad simulator"; xcrun simctl list devices available; exit 3; }
  echo "Simulator: ${SIM#*$'\t'}"
  DESTINATION="platform=iOS Simulator,id=$UDID"
fi
echo "Destination: $DESTINATION"

# What does the generated scheme actually agree to test? An empty Testables list
# is why `xcodebuild test` can exit 0 having run nothing.
SCHEME_FILE="Courseleaf.xcodeproj/xcshareddata/xcschemes/Courseleaf.xcscheme"
if [ -f "$SCHEME_FILE" ]; then
  echo "----- scheme TestAction -----"
  sed -n '/<TestAction/,/<\/TestAction>/p' "$SCHEME_FILE"
  echo "-----------------------------"
else
  echo "no shared scheme at $SCHEME_FILE; schemes present:"; ls -1 Courseleaf.xcodeproj/xcshareddata/xcschemes 2>/dev/null || true
fi
echo "----- test plans / testables xcodebuild sees -----"
xcodebuild -project Courseleaf.xcodeproj -scheme Courseleaf -showTestPlans 2>&1 | head -20 || true
RESULT="${RESULT_BUNDLE:-$PWD/../Build/CourseleafTests.xcresult}"
rm -rf "$RESULT"
set +e
set -o pipefail
# Test timeouts are enabled so a single hanging test fails with its own name
# after a few minutes, instead of running the job into its 60-minute limit and
# leaving no evidence of which test hung.
xcodebuild test \
  -project Courseleaf.xcodeproj -scheme Courseleaf \
  -destination "$DESTINATION" \
  -resultBundlePath "$RESULT" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 600 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  ${XCODEBUILD_EXTRA:-} 2>&1 | tee "$PWD/../Build/xcodebuild-test.log" | (command -v xcbeautify >/dev/null && xcbeautify || cat)
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  echo "----- compile errors (from the raw log) -----"
  grep -E "error:" "$PWD/../Build/xcodebuild-test.log" | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -60 || true
fi
exit "$status"
