#!/usr/bin/env bash
# Build and test the core package. Works on Linux and macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /opt/swift-root/usr/bin ] && ! command -v swift >/dev/null 2>&1; then
  export PATH=/opt/swift-root/usr/bin:$PATH
fi
swift --version
swift build
swift test --parallel "$@" 2>&1 | tee .build/test-output.log | grep -E "Executed|error:|failed" || true
if grep -qE "with [1-9][0-9]* failures|error:" .build/test-output.log; then
  echo "TESTS FAILED"; exit 1
fi
echo "TESTS PASSED"
