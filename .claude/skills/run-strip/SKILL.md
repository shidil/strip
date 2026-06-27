---
name: run-strip
description: Launch Strip the trusted way (make open via LaunchServices, the only path that gets the Accessibility grant) and tail /tmp/strip.log to observe behavior. Use to run, restart, or watch the live app — never run the binary from a shell.
disable-model-invocation: true
---

# run-strip

Strip's run path is non-obvious (CLAUDE.md "Running it"). This skill captures the trusted launch +
log-watch dance so it isn't gotten wrong.

## Why not just run the binary

- **Accessibility trust requires a LaunchServices launch.** Running the binary from a shell is NOT
  granted Accessibility (TCC attributes it to the parent shell), so AX calls degrade/fail. Always
  launch with **`make open`**. `make run` is a build-check only — **not** trusted.
- **`open`-launched agents have no stdout**, so the app logs to **`/tmp/strip.log`**. That file is the
  only runtime observability — never delete it.

## Launch + watch

```sh
make open            # build + sign (stable "Strip Dev" cert) + launch via LaunchServices
sleep 4 && pgrep -x Strip   # confirm a stable pid
```

If `open` returns LaunchServices `-600` right after killing the old instance, just retry
`open .build/Strip.app`, then re-check `pgrep -x Strip`.

Observe behavior by tailing the log:

```sh
tail -f /tmp/strip.log
```

In the log, `● … ◀focus` marks the centered/focused window. Watch for window placements, focus
changes, hotkey handling, and errors. For a one-shot look use `tail -n 80 /tmp/strip.log`.

## If the Accessibility grant breaks

Symptom: windows stop moving / AX writes fail after a signing-identity change. Recover with:

```sh
tccutil reset Accessibility com.spike.strip
make open
# then re-toggle Strip in System Settings -> Privacy & Security -> Accessibility
```

## Hotkeys (driving it)

All commands are `⌃⌥` + a key (full map in `HotkeyService.swift` and MEASURING.md §5):
⌃⌥L / ⌃⌥H slide, ⌃⌥⇧L / ⌃⌥⇧H move, ⌃⌥J / ⌃⌥K / ⌃⌥Tab focus, ⌃⌥1/2/3 cols, ⌃⌥0 release-all,
⌃⌥Space overview, ⌃⌥/ help.

To verify a visual change, capture **across** a state change (`screencapture -x /tmp/shot.png` before
and after a slide) so a stale render can't pass — requires Screen Recording permission.
