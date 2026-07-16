# Development Signing

macOS ties Accessibility and Screen Recording grants to bundle identity and code signature.
Repeated ad-hoc signatures can cause development builds to lose trust.

`make setup-signing` creates a local, ten-year, self-signed identity named `Strip Dev` and imports
its private key into the current user's login keychain. This is a development convenience only.

- It is not trusted for distribution, Gatekeeper, or notarization.
- Public artifacts require Apple Developer ID signing and notarization.
- The script allows `/usr/bin/codesign` to use the imported key.
- Remove the certificate and private key in Keychain Access to undo setup.

```bash
make setup-signing
make bundle
make open
```

If the identity changes, reset old permissions:

```bash
tccutil reset Accessibility io.github.shidil.strip
tccutil reset ScreenCapture io.github.shidil.strip
```
