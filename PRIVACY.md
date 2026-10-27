# Privacy and Permissions

Strip is a local macOS window manager. Its capabilities are powerful, so this document describes
what it can observe, what it changes, and how to revoke access.

## Accessibility

Strip requests Accessibility permission to enumerate standard windows; read titles, roles, state,
position, and size; move, resize, raise, and focus windows; observe lifecycle changes; and receive
global keyboard shortcuts.

When you search in Overview, Strip also reads the tab titles that apps expose through
Accessibility (for example a browser's tab bar) and can press a tab to switch to it. Tab titles stay
in process memory; search queries and tab titles are not written to the log (only counts and ranks).

Movement and resizing use public Accessibility APIs. Strip links the private, underscored
`_AXUIElementGetWindow` symbol solely to map an Accessibility element to a stable `CGWindowID`.
This dependency can break on future macOS versions and prevents Mac App Store distribution.

## Screen Recording

Screen Recording is optional and requested only when Overview needs live thumbnails. ScreenCaptureKit
captures still images of requested windows. Strip keeps them in process memory and does not
intentionally persist them. Without permission, thumbnail cards use placeholders.

## Storage and Network Behavior

Layout preferences are stored in macOS `UserDefaults` under `io.github.shidil.strip`. Runtime
diagnostics are written to `/tmp/strip.log`; they can include application and window titles, window
identifiers, and geometry. The log is local, is not uploaded, and may be deleted at any time.

The audited source contains no networking, telemetry, analytics, crash-upload, account, or automatic
update code. Recheck this statement for each release.

## Revoking Access

Quit Strip and remove it from Accessibility and Screen Recording in **System Settings → Privacy &
Security**. If necessary:

```bash
tccutil reset Accessibility io.github.shidil.strip
tccutil reset ScreenCapture io.github.shidil.strip
```

Changing the bundle identifier or signing identity creates a new TCC identity and requires new grants.

## Compatibility

Strip is tested on macOS 14 and newer. Private API behavior, Accessibility semantics, and
ScreenCaptureKit compatibility are not guaranteed on future macOS releases.
