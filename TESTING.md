# TESTING.md — the e2e/smoke suite (AppKit/AX/menu integration)

> `swift test` (`make test`) covers the pure engine (`StripState`/`StripLayout`/etc.) headlessly and
> needs nothing special to run. This doc is about the layer `swift test` can't reach: does a hotkey
> actually get to `StripController`, does a menu item actually flip a setting, does the log actually
> show what the code claims. That's `make e2e` — a real, bundled, launched Strip driven by synthetic
> input and asserted against `/tmp/strip-e2e.log`, replacing the ad-hoc osascript-and-eyeball flow
> this used to be redone by hand each session.

## 1. Running the suite

```sh
make e2e
```

That's it — it bundles, launches its own Strip instance, drives it, and reports PASS/FAIL per
scenario with a summary at the end. **Prerequisites, unlike `make test`:**

- Strip must already have a granted Accessibility permission on this machine (same grant `make open`
  needs — see `CLAUDE.md`'s "Running it" section). The suite doesn't re-prompt for this.
- A real display and a logged-in GUI session — no headless/CI runner.
- **A clean desktop.** The suite needs the *only* windows Strip can see to be its own 3 fixture
  windows (§3) — see §6 "clean desktop" for why, and what happens if that's not true.
- Nothing else driving the mouse/keyboard while it runs (it sends real synthetic hotkeys and menu
  clicks via System Events).

It is deliberately **not** part of `make test` and **not** wired into the `swift-test-on-edit.sh`
PostToolUse hook — it kills any running Strip instance and needs the preconditions above, so it
can't run on every edit or in CI.

## 2. Scope: what's automated vs. manual-only

Two input surfaces were found reliable enough to automate (confirmed empirically, not assumed):
synthetic hotkey chords via `System Events key code`, and status-menu clicks via UI-scripting
(`click menu item ... of menu 1 of menu bar item 1 of menu bar 1` — Strip is an `LSUIElement`
accessory app, so its menu is `menu bar 1`, not the usual app's `menu bar 2`).

| Covered by `make e2e` | Manual-only (documented, not silently dropped) |
| --- | --- |
| Layout switch 1/2/3-up (hotkey + menu) | Hover-triggered rail preview thumbnails |
| Slide film prev/next | Minimap drag-rearrange / modifier-click swap (not implemented yet anyway) |
| Focus move (J/K) | Any interaction needing precise mouse *positioning* over the custom SwiftUI rail/overlay content |
| `moveFocused` carry-focused swap (⌃⌥⇧H/L) | |
| Pin/unpin | |
| Release-all / resume (⌃⌥0) | |
| Minimap position (all 4 edges, via menu) | |
| Focus-ring toggle (via menu) | |
| Overview open/close (via menu) | |

**Why hover is manual-only — an actual finding, not a guess.** The task that produced this suite
found raw `CGEvent` `.mouseMoved` posting unreliable for triggering SwiftUI's `.onHover`. The
obvious alternative, XCUITest's `XCUIApplication`, was spiked (time-boxed, ~5 minutes to a definitive
answer) by adding a throwaway test to `Tests/StripKitTests` that called
`XCUIApplication(bundleIdentifier: "com.spike.strip").activate()`. Result:

```
error: -[StripKitTests.SpikeXCUITestThrowaway testAttachAndHover] : Device is not configured for UI
testing - use of XCUIApplication is not supported. This can happen when XCUIApplication is used in a
unit test bundle instead of a UI test bundle.
```

`XCUIApplication` requires a real Xcode **UI Testing Bundle** target (its own scheme, its own
XCTRunner host process) — SwiftPM's `.testTarget` can't produce one. Standing up a whole separate
Xcode project just to test hover isn't worth it for what's already a small, deferrable slice of
scope. If someone wants to revisit this, that's the concrete blocker to solve first — not a timing
or reliability question.

## 3. How it works

```
scripts/e2e/
  run.sh              # entry point: launch → fixture → scenarios → teardown → summary
  lib/driver.sh        # osascript wrappers: send_hotkey <name>, click_menu/click_submenu <...>
  lib/fixture.sh        # setup_fixture / teardown_fixture
  lib/log_assert.sh     # checkpoint / wait_for_new_apply / wait_for_line / parse_* / assert_eq
  scenarios.sh          # one function per scenario
  fixtures/placeholder.png   # generated on demand by fixture.sh, not committed
```

**Fixture** (`lib/fixture.sh`): three windows the suite fully controls — **TextEdit** (blank
document), **Activity Monitor**, and **Preview** (opened on a generated placeholder image). Setup
quits any already-running instances first, relaunches them, **activates** each, and **resizes** each
window to 60% of the screen in both dimensions. Both of those steps are load-bearing, not
cosmetic — see §6.

Calculator was the obvious first choice (no save prompt, always present) and was dropped: its window
is **permanently non-resizable** (confirmed empirically — a `System Events` resize request is
silently ignored), so it can never clear the tileability bar below.

**Driver** (`lib/driver.sh`): `send_hotkey <name>` sends one of the v1-scope `⌃⌥`/`⌃⌥⇧` chords (key
codes are the same ones documented in `MEASURING.md` §5, source of truth
`Sources/StripKit/Input/HotkeyService.swift`). `click_menu`/`click_submenu` drive the status menu.

**Oracle** (`lib/log_assert.sh`): parses `/tmp/strip-e2e.log` instead of screenshots. `checkpoint`
snapshots the log's line count before an action; `wait_for_new_apply`/`wait_for_line` poll for the
result *after* that checkpoint, so a stale block from an earlier action can't be misread as this
one's. `parse_cols`/`parse_count`/`parse_focus_app`/`parse_slot_app` read the `apply:` summary line
and (when `STRIP_VERBOSE=1`, which the suite always sets) the per-window detail lines:

```
apply: <cols>-up · <focus|equal> on <screen> — N slotted, M parked[ — pinned ...]
   <●|·> <appName> slot=<L|C|R|PARKED> frame=(x,y wxh) [◀focus]
```

`●` and `◀focus` both mark the slot that currently has **keyboard focus** — not the centered one.
There's no separate "this is centered" marker in the log; center is inferred structurally (see
`scenario_focus_move`/`scenario_move_focused_swap` in `scenarios.sh` for how the suite uses this).

## 4. Reading a failure

Each scenario prints its own mismatches as it goes (`assert_eq` prints `expected` vs. `got`) plus a
`log block:` excerpt of the `/tmp/strip-e2e.log` state it was checking — that excerpt is usually
enough on its own. `run.sh`'s final summary lists which scenario functions failed; re-run just one by
sourcing the libs and calling it directly, e.g.:

```sh
export STRIP_LOG=/tmp/strip-e2e.log STRIP_VERBOSE=1
source scripts/e2e/lib/log_assert.sh
source scripts/e2e/lib/driver.sh
scenario_pin_unpin   # after `source scripts/e2e/scenarios.sh` and with Strip + fixture already up
```

For the one purely-visual check in scope (does the rail actually render on the edge the code says),
there's no log line to assert against — that stays a manual `screencapture` + eyeball check per
`CLAUDE.md`'s "verify visual changes with eyes" rule, not something this suite automates.

## 5. Gotchas learned the hard way

- **New windows need to clear a size threshold, not just exist.**
  `StripController.isTileableSize` requires a *newly appearing* window to be at least 20% of the
  display's width and 40% of its height before Strip admits it to the ring
  (`StripController.swift`, `minTileWidthFraction`/`minTileHeightFraction`). A stock
  TextEdit/Preview window is comfortably below that on most displays — the fixture resizes each
  window after launch specifically to clear this, not for cosmetics. If `make e2e` ever reports
  "Strip is managing more than the 3 fixture windows" — or the opposite, that it's managing *fewer*
  — check this first, not the driver.
- **A window opened via a bare AppleScript verb (e.g. `make new document`) can be invisible to
  Strip.** `StripController.allWindows()` skips apps where `NSRunningApplication.isHidden` is true,
  and TextEdit launched via `tell application "TextEdit" to make new document` alone was never
  brought to the foreground — System Events reported `visible: false` for it. `fixture.sh` explicitly
  `activate`s every fixture app after launching it. This looks identical to an observer-timing race
  at first — it isn't; retrying "Re-tile / Re-scan" doesn't help because the window is being filtered
  the same way on every scan, not merely missed once.
- **The suite needs a genuinely clean desktop, and there's no robust way around that.** Strip manages
  *every* app window that clears `classify()`, not just the fixture's — if other real windows (a
  browser, Slack, a terminal) are open, they get counted too and the exact slotted/parked assertions
  become non-deterministic. `run.sh` fails fast with `wait_for_total_count` rather than silently
  running scenarios against an unknown mixed window set — treat that failure as "close your other
  windowed apps," not as a suite bug.
- **Rapid back-to-back synthetic input is occasionally flaky**, consistent with the original
  finding that synthetic keystrokes/clicks aren't as reliable as real hardware input. `run.sh` puts a
  short settle delay before each scenario; if a scenario fails in the full run but passes in
  isolation (§4), that's almost certainly why — it's a suite timing margin, not a Strip bug.

## 6. Extending the suite

Add a new scenario function to `scenarios.sh` (return 0/pass, non-zero/fail, print the mismatch and
`_fail_dump "$block"` on failure) and list it in `run.sh`'s `SCENARIOS` array. Scenarios run in
sequence and are **not** fully hermetic — each may depend on the layout/focus state the previous one
left behind (documented inline where it matters, e.g. `scenario_focus_move` resets focus to `L`
itself rather than assuming where a prior scenario left it). Keep new hotkeys/menu items in sync with
`Sources/StripKit/Input/HotkeyService.swift` / `AppDelegate.swift`'s `rebuildMenu()` — those are the
sources of truth this suite mirrors, not the other way around.
