# Releasing

Strip is source-first. Never attach self-signed or ad-hoc builds to a public release.

## Source Publication

Before changing repository visibility, enable GitHub private vulnerability reporting and verify the
link in `SECURITY.md` from a non-maintainer account. Do not publish while the documented private
reporting channel is unavailable.

## Version Policy

Public versions use semantic versioning. Update `CFBundleShortVersionString` and `CFBundleVersion`
in `Resources/Info.plist`, then update `CHANGELOG.md` in the same change.

## Validation

```bash
make ci
make archive
```

`make archive` creates an ad-hoc-signed local test archive and SHA-256 checksum. It is for clean-VM
installation testing, not public distribution.

## Notarized Artifact

Public binaries require an Apple `Developer ID Application` certificate and a `notarytool` keychain
profile:

```bash
SIGN_ID="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="strip-notary" \
make notarized-release
```

The release script builds, signs, verifies, notarizes, staples, Gatekeeper-verifies, zips, and writes
a checksum. Test installation, permissions, update, uninstall, and revocation on a clean account or
VM before publishing.
