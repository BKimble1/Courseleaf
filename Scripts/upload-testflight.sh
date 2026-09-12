#!/usr/bin/env bash
# Validate and upload a distribution IPA to App Store Connect for TestFlight.
#
# This uploads a build for internal testing only. It never submits anything for
# App Store review: that is a separate, explicit action in App Store Connect.
#
# Required environment:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH
set -euo pipefail
IPA="${1:?usage: upload-testflight.sh <Courseleaf.ipa>}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_PATH:?}"
[ -f "$IPA" ] || { echo "no IPA at $IPA"; exit 2; }

# altool discovers the key by ID in a private_keys directory; it has no flag for
# a key path. Point it at the directory the key already lives in, so the key is
# never copied into the workspace where an artifact upload could catch it.
KEY_DIR=$(cd "$(dirname "$ASC_PRIVATE_KEY_PATH")" && pwd)
EXPECTED="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$EXPECTED" ] || { echo "key must be named AuthKey_${ASC_KEY_ID}.p8 in $KEY_DIR"; exit 2; }
export API_PRIVATE_KEYS_DIR="$KEY_DIR"

echo "===== validate ====="
xcrun altool --validate-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json \
  | tee "$(dirname "$IPA")/altool-validate.json"

echo "===== upload ====="
# altool retries transient transporter failures itself; a non-zero exit here is
# a real rejection and must fail the job.
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json \
  | tee "$(dirname "$IPA")/altool-upload.json"

echo "Upload accepted by App Store Connect. Acceptance is not processing:"
echo "the build is not installable until its processing state is VALID."
