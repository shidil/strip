#!/bin/bash
# Creates a stable self-signed code-signing identity ("Strip Dev") in the login keychain so the
# Accessibility grant survives rebuilds. This is the same approach yabai/AeroSpace use for dev.
# Reversible: delete "Strip Dev" from Keychain Access (login keychain) to undo.
set -euo pipefail

CERT_NAME="Strip Dev"
P12_PASS="stripdev"   # throwaway; only used to move the key into the keychain
KEYCHAIN="$(security login-keychain | tr -d ' "')"

# Note: no -v — a self-signed cert reports CSSMERR_TP_NOT_TRUSTED but codesign + TCC still accept it.
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Code-signing identity '$CERT_NAME' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# LibreSSL's empty-password PKCS#12 MAC fails macOS `security import`, so use a throwaway password.
openssl pkcs12 -export -name "$CERT_NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "Importing into login keychain (codesign will be allowed to use the key)…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign >/dev/null 2>&1

echo "✓ Created '$CERT_NAME'."
echo "  Note: the first 'make bundle' may pop a keychain prompt — click \"Always Allow\"."
security find-identity -p codesigning | grep "$CERT_NAME" || true
