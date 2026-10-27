# Strip

<p align="center">
  <img src="docs/assets/strip-banner.svg" width="100%"
       alt="Strip: a strip of app windows rolls beneath three fixed slots; the center slot never moves.">
</p>

Strip is an experimental macOS window manager that arranges application windows on a horizontal
"film strip": the focused window stays centered while its neighbors flow past it.

> [!WARNING]
> Strip is an early, source-first project for developers and testers. There are no supported public
> binary releases yet. It can move and resize other applications' windows.

```text
parked  ←  [ window ] [ window ] [ FOCUSED ] [ window ] [ window ]  →  parked
```

Strip is built with Swift and AppKit. It uses macOS Accessibility for window control and does not
require disabling System Integrity Protection or installing a scripting addition.

## Status and Scope

- **Status:** experimental alpha / daily-driver spike, not a supported product.
- **Tested platform:** macOS 14 and newer, primarily on a single ultrawide display.
- **Architecture:** menu-bar accessory app with a pure, unit-tested layout engine.
- **Distribution:** source builds only until Developer ID signing and notarized releases are ready.
- **App Store:** not eligible while it uses the private `_AXUIElementGetWindow` identity bridge.

Multi-display behavior, separate Spaces, polished installation, and stable binary releases remain
incomplete. See [PLAN.md](PLAN.md) and [BUGS.md](BUGS.md) for current status.

## Requirements

- macOS 14 or newer
- Xcode 16 command-line tools
- Accessibility permission for moving, resizing, observing, and focusing windows
- Screen Recording permission only for Overview thumbnails

## Build and Run

```bash
make test
make bundle
make open
```

Use `make open` for real testing. Launching the inner executable from a terminal does not receive
the same Accessibility trust because macOS TCC attributes that execution differently.

`make setup-signing` is an optional **developer-only** convenience. It creates a local self-signed
identity named `Strip Dev` so repeated development builds retain a stable TCC identity. It is not an
installation method and must never produce public binaries. See
[docs/DEVELOPMENT_SIGNING.md](docs/DEVELOPMENT_SIGNING.md).

## Permissions and Privacy

| Permission | Why Strip uses it | When requested |
|---|---|---|
| Accessibility | Enumerate, focus, move, and resize windows; receive global hotkeys | At first launch |
| Screen Recording | Capture still in-memory thumbnails for Overview | When Overview first requests thumbnails |

Strip currently contains no networking, telemetry, analytics, crash-upload, or update-checking
code. Window data and thumbnails remain local. Thumbnails are held in memory and are not written to
disk by Strip. `_AXUIElementGetWindow` is used only for stable identity; movement and resizing use
public Accessibility APIs.

Read [PRIVACY.md](PRIVACY.md) for the complete data model, compatibility warning, and revocation
steps.

## Uninstall

1. Quit Strip from its menu-bar menu and delete `Strip.app`.
2. Remove Strip from **System Settings → Privacy & Security → Accessibility**.
3. Remove Strip from **Screen & System Audio Recording** in the same settings area.
4. Contributors who ran `make setup-signing` may delete `Strip Dev` from the login keychain.

If macOS retains stale records:

```bash
tccutil reset Accessibility io.github.shidil.strip
tccutil reset ScreenCapture io.github.shidil.strip
```

## Known Limitations

- The private identity symbol can change or disappear in a future macOS release.
- Mac App Store distribution is not supported.
- Terminal applications resize in character-cell increments and may visibly step.
- Applications can impose minimum or fixed window sizes that differ from requested layouts.
- Multi-display and Spaces behavior is deliberately limited.
- Privacy grants are tied to bundle identity and code signing.

## Development

- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, tests, style, and performance rules
- [docs/README.md](docs/README.md) — documentation map
- [ARCHITECTURE.md](ARCHITECTURE.md) — current architecture
- [TESTING.md](TESTING.md) — unit, live, and VM end-to-end testing
- [MEASURING.md](MEASURING.md) — required performance workflow
- [SECURITY.md](SECURITY.md) — vulnerability reporting

## License

Strip is available under the [MIT License](LICENSE). Vendored development tooling retains its own
license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
