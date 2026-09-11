#!/usr/bin/env bash
# Regenerate deterministic fixtures into Fixtures/ using the Fixtures module.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /opt/swift-root/usr/bin ] && ! command -v swift >/dev/null 2>&1; then export PATH=/opt/swift-root/usr/bin:$PATH; fi
swift run --package-path . fixturegen Fixtures
