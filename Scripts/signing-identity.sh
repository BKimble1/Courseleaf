#!/usr/bin/env bash
# Put an Apple Distribution identity and an App Store provisioning profile on
# this runner, so the Release archive can be signed for distribution.
#
# Why this exists: with automatic signing, `xcodebuild archive` asks Apple for
# an *iOS App Development* profile, and Apple will not issue one to a team with
# no registered devices:
#
#   Communication with Apple failed: Your team has no devices from which to
#   generate a provisioning profile.
#
# Registering a device to get past that would be wrong twice over — nobody here
# has a Mac to register one from, and an App Store profile must contain no
# devices anyway. So the archive signs manually with a distribution identity,
# which is the supported CI path and needs no device at all.
#
# Apple caps a team at three distribution certificates, and revoking one to make
# room is not something a release script may do. So an identity is created at
# most once and then reused: the encrypted PKCS#12 is kept in $IDENTITY_DIR
# (a GitHub Actions cache) and every later run imports it rather than spending
# another certificate slot.
#
# Required environment:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH   App Store Connect API key
#   IDENTITY_DIR      where the stored identity lives across runs
#   APP_BUNDLE_ID     e.g. com.idlery.courseleaf
# Optional:
#   TEAM_ID           defaults to 7GNFT94A9L
#
#   Scripts/signing-identity.sh <env-file-to-write>
set -euo pipefail

ENV_OUT="${1:?usage: signing-identity.sh <env-file>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${TEAM_ID:-7GNFT94A9L}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_PATH:?}"
: "${IDENTITY_DIR:?set IDENTITY_DIR}" "${APP_BUNDLE_ID:?set APP_BUNDLE_ID}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$IDENTITY_DIR"

P12_ENC="$IDENTITY_DIR/identity.p12.enc"
CERT_ID_FILE="$IDENTITY_DIR/certificate-id"

# The passphrase is derived from the App Store Connect key that is already a
# repository secret, so it is identical on every run and stored nowhere. It is
# never echoed.
PASS="$(openssl dgst -sha256 -hex "$ASC_PRIVATE_KEY_PATH" | sed 's/.*= *//')"
[ -n "$PASS" ] || { echo "could not derive an identity passphrase"; exit 2; }

# ---------------------------------------------------------------- keychain ---
# A throwaway keychain, so nothing here touches the runner's login keychain.
# It lives outside $WORK because the build that uses it runs after this script
# exits and the trap above has cleaned $WORK up.
KEYCHAIN="${RUNNER_TEMP:-/tmp}/courseleaf-signing.keychain-db"
KEYCHAIN_PASS="$(openssl rand -hex 32)"
rm -f "$KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
# Keep the runner's existing keychains searchable; codesign needs Apple's
# intermediate certificates, which already live in the system keychain.
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')

import_p12() {  # import_p12 <p12>
  security import "$1" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security -f pkcs12
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
}

# ---------------------------------------------------------------- identity ---
CERT_ID=""
if [ -f "$P12_ENC" ] && [ -f "$CERT_ID_FILE" ]; then
  CERT_ID="$(cat "$CERT_ID_FILE")"
  echo "===== reusing the stored distribution identity ($CERT_ID) ====="
  # Still stored is not still valid: a certificate that expired or was revoked
  # since the last run must not be discovered at codesign time. But only a
  # definite answer may discard it — if App Store Connect cannot be reached,
  # minting a replacement would spend one of three irreplaceable slots over a
  # network blip, so the stored identity is used and codesign can complain.
  set +e
  python3 "$ROOT/Scripts/asc.py" audit-signing --bundle-id "$APP_BUNDLE_ID" > "$WORK/audit.json"
  audit_rc=$?
  set -e
  VERDICT=unknown
  if [ "$audit_rc" -eq 0 ]; then
    VERDICT=$(python3 - "$WORK/audit.json" "$CERT_ID" <<'PY'
import json, sys
certificates = json.load(open(sys.argv[1])).get("certificates")
if not isinstance(certificates, list):
    print("unknown")            # the probe itself failed, so this proves nothing
elif any(c.get("id") == sys.argv[2] for c in certificates):
    print("present")
else:
    print("absent")
PY
)
  fi
  if [ "$VERDICT" = "absent" ]; then
    echo "the stored certificate is no longer on the team; a new one is needed"
    CERT_ID=""
  else
    [ "$VERDICT" = "present" ] || echo "could not confirm the certificate; using the stored one rather than spending a slot"
    openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$PASS" -in "$P12_ENC" -out "$WORK/identity.p12"
    import_p12 "$WORK/identity.p12"
  fi
fi

if [ -z "$CERT_ID" ]; then
  echo "===== creating a distribution certificate ====="
  # The private key is generated here and never sent anywhere: Apple only ever
  # sees the certificate signing request built from its public half.
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$WORK/identity.key" -out "$WORK/identity.csr" \
    -subj "/CN=Courseleaf CI Distribution/O=Idlery/C=US" 2>/dev/null
  python3 "$ROOT/Scripts/asc.py" create-cert --type DISTRIBUTION \
    --csr "$WORK/identity.csr" --out "$WORK/identity.b64" | tee "$WORK/cert.json"
  CERT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/cert.json")"
  base64 --decode < "$WORK/identity.b64" > "$WORK/identity.der"
  openssl x509 -inform DER -in "$WORK/identity.der" -out "$WORK/identity.pem"

  # macOS imports a PKCS#12 only when it uses the older PBE algorithms; an
  # OpenSSL 3 default bundle lands in the keychain with no usable private key.
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/identity.key" -in "$WORK/identity.pem" \
    -name "Courseleaf CI Distribution" -out "$WORK/identity.p12" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout "pass:$PASS" 2>/dev/null \
  || /usr/bin/openssl pkcs12 -export -inkey "$WORK/identity.key" -in "$WORK/identity.pem" \
    -name "Courseleaf CI Distribution" -out "$WORK/identity.p12" -passout "pass:$PASS"

  import_p12 "$WORK/identity.p12"
  # Encrypted at rest, because the cache this lands in is not a secret store:
  # without the App Store Connect key the stored blob is useless.
  openssl enc -aes-256-cbc -pbkdf2 -pass "pass:$PASS" -in "$WORK/identity.p12" -out "$P12_ENC"
  printf '%s' "$CERT_ID" > "$CERT_ID_FILE"
  chmod 600 "$P12_ENC"
  echo "certificate $CERT_ID created and stored for reuse"
fi

echo "===== signing identities in the release keychain ====="
security find-identity -v -p codesigning "$KEYCHAIN"
IDENTITY_NAME="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | sed -n 's/.*"\(Apple Distribution:[^"]*\)".*/\1/p' | head -1)"
[ -n "$IDENTITY_NAME" ] || {
  echo "FAIL  no Apple Distribution identity in the keychain after import"
  exit 1
}
echo "identity: $IDENTITY_NAME"

# ----------------------------------------------------------------- profile ---
echo "===== App Store provisioning profile ====="
python3 "$ROOT/Scripts/asc.py" profile --bundle-id "$APP_BUNDLE_ID" --type IOS_APP_STORE \
  --cert-id "$CERT_ID" --name "Courseleaf App Store" --out "$WORK/profile.b64" | tee "$WORK/profile.json"
base64 --decode < "$WORK/profile.b64" > "$WORK/profile.mobileprovision"

PROFILE_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$WORK/profile.json")"
PROFILE_UUID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uuid"])' "$WORK/profile.json")"

# Xcode 16 moved the profile directory; install into both so the toolchain
# finds it whichever location this Xcode reads.
for DIR in "$HOME/Library/MobileDevice/Provisioning Profiles" \
           "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$DIR"
  cp "$WORK/profile.mobileprovision" "$DIR/$PROFILE_UUID.mobileprovision"
done

# The profile must carry no devices: that is what makes it an App Store profile
# rather than an ad hoc one, and it is why no device needs registering.
security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist" 2>/dev/null
if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$WORK/profile.plist" >/dev/null 2>&1; then
  echo "FAIL  the profile lists devices; that is an ad hoc profile, not App Store"
  exit 1
fi
echo "profile: $PROFILE_NAME ($PROFILE_UUID), no provisioned devices"

cat > "$ENV_OUT" <<ENV
KEYCHAIN_PATH=$KEYCHAIN
CODE_SIGN_IDENTITY_NAME=$IDENTITY_NAME
PROVISIONING_PROFILE_NAME=$PROFILE_NAME
PROVISIONING_PROFILE_UUID=$PROFILE_UUID
SIGNING_CERTIFICATE_ID=$CERT_ID
ENV
echo "wrote $ENV_OUT"
