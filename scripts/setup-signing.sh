#!/bin/bash

# DEVELOPER-ONLY: creates a stable self-signed identity ("Strip Dev") in the login keychain so
# Accessibility grants survive local rebuilds. It is not trusted for distribution or notarization.
# Never use this identity for a public artifact. See docs/DEVELOPMENT_SIGNING.md.
# Reversible: delete "Strip Dev" from Keychain Access (login keychain) to undo.
set -euo pipefail

cat <<'NOTICE'
Strip development signing setup
--------------------------------
This creates and imports a self-signed private key into your login keychain.
It is for local development only and is not suitable for public distribution.
Press Ctrl-C now if you did not intend to modify your login keychain.
NOTICE

CERT_NAME="Strip Dev"
P12_PASS="stripdev" # throwaway; only used to move the key into the keychain
KEYCHAIN="$(security login-keychain | tr -d ' "')"

# Note: no -v — a self-signed certificate reports CSSMERR_TP_NOT_TRUSTED, but codesign and TCC
# still accept it. The -v form hides identities that are not rooted in a trusted certificate chain.
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
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# LibreSSL's empty-password PKCS#12 MAC fails macOS `security import`, so use a throwaway password.
openssl pkcs12 -export -name "$CERT_NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "Importing into the login keychain (codesign will be allowed to use the key)…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -A -T /usr/bin/codesign >/dev/null 2>&1

echo "✓ Created '$CERT_NAME'."
echo "  Note: the first 'make bundle' may show a keychain prompt — click \"Always Allow\"."
security find-identity -p codesigning | grep "$CERT_NAME" || true
