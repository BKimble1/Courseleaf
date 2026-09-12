#!/usr/bin/env bash
# Turn an .xcresult bundle into a verdict. Used by every job that claims to run
# tests, so the claim means the same thing everywhere.
#
# Fails if: the bundle is missing, the summary is unreadable, zero tests ran, or
# any test failed. A job that executes nothing is not evidence of anything, and
# a green job once reported totalTestCount 0 — hence the explicit guard.
#
#   Scripts/check-test-results.sh <path/to/Tests.xcresult> [summary-markdown-file]
set -euo pipefail
BUNDLE="${1:?usage: check-test-results.sh <xcresult> [summary-file]}"
SUMMARY_OUT="${2:-/dev/null}"

[ -d "$BUNDLE" ] || { echo "no result bundle at $BUNDLE"; exit 1; }

JSON=$(mktemp)
trap 'rm -f "$JSON"' EXIT
xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json > "$JSON" \
  || { echo "xcresulttool could not read $BUNDLE"; exit 1; }

python3 - "$JSON" <<'PY' | tee -a "$SUMMARY_OUT"
import json, sys
d = json.load(open(sys.argv[1]))
total = d.get("totalTestCount")
failed = d.get("failedTests")
print("## Test results")
print(f"- result: {d.get('result','?')}")
print(f"- total: {total}, passed: {d.get('passedTests','?')}, failed: {failed}, "
      f"skipped: {d.get('skippedTests','?')}, expected failures: {d.get('expectedFailures','?')}")
for dev in d.get("devices", []):
    print(f"- device: {dev.get('deviceName','?')} ({dev.get('platform','?')} {dev.get('osVersion','?')})")
for f in d.get("testFailures", [])[:25]:
    print(f"  - FAILED {f.get('testName','?')}: {f.get('failureText','')[:200]}")
if not isinstance(total, int) or total == 0:
    raise SystemExit("FAIL: no tests executed; a passing job with zero tests is not evidence")
if not isinstance(failed, int) or failed != 0:
    raise SystemExit(f"FAIL: {failed} test(s) failed")
if d.get("result") not in ("Passed", "passed"):
    raise SystemExit(f"FAIL: overall result is {d.get('result')!r}")
print(f"\nOK: {total} tests executed, 0 failed.")
PY
