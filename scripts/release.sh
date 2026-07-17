#!/bin/bash

set -euo pipefail

: "${SIGN_ID:?Set SIGN_ID to an Apple Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a configured notarytool keychain profile}"

if [[ "$SIGN_ID" != Developer\ ID\ Application:* ]]; then
    echo "SIGN_ID must be a Developer ID Application identity" >&2
    exit 1
fi

if ! security find-identity -p codesigning | grep -Fq "$SIGN_ID"; then
    echo "Signing identity not found: $SIGN_ID" >&2
    exit 1
fi

make bundle CONFIG=release SIGN_ID="$SIGN_ID" REQUIRE_SIGNING=1 \
  CODESIGN_OPTIONS="--options runtime --timestamp"
make verify-bundle

app=".build/Strip.app"
dist=".build/dist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
submission="$dist/Strip-$version-notarization.zip"
artifact="$dist/Strip-$version-macos.zip"
artifact_name=$(basename "$artifact")

signature_details=$(codesign -d --verbose=4 "$app" 2>&1)
if ! grep -Eq 'flags=.*\(runtime\)' <<<"$signature_details"; then
  echo "Developer ID signature is missing hardened runtime" >&2
  exit 1
fi
if ! grep -q '^Timestamp=' <<<"$signature_details"; then
  echo "Developer ID signature is missing a secure timestamp" >&2
  exit 1
fi

mkdir -p "$dist"
rm -f "$submission" "$artifact" "$artifact.sha256"
ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$artifact"
(cd "$dist" && shasum -a 256 "$artifact_name" > "$artifact_name.sha256")
rm -f "$submission"

echo "Created notarized release: $artifact"
