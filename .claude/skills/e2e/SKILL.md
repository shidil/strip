---
name: e2e
description: Verify a Strip behavior change end to end in the isolated Tart VM (make e2e-vm) — hotkeys, menu, Overview, search typing and picks, native tabs — without touching the user's live Strip, and extend the suite with a scenario for what changed. Use after changing input handling, the overlay/search, StripController, AX paths, or the observer, and BEFORE asking the user to hand-test anything.
---

# e2e

The default way to check that a change works in the real app. `make e2e-vm` builds, pushes the app
into the `strip-e2e` Tart VM, re-signs it there with the guest's fixed identity (so its grants hold
across builds), and runs `scripts/e2e/run.sh` against synthetic hotkeys, typing and menu clicks,
asserting on Strip's own log. Full reference: TESTING.md.

## Run

```sh
make e2e-vm                                   # whole suite (~2–4 min)
make e2e-vm E2E_ONLY="scenario_search_type_and_pick scenario_cmd_tab_leaves_overview"
make e2e-vm-check                             # preflight only: VM, signing identity, grants
```

Output streams while it runs and ends with `=== Summary: N passed, M failed ===`; the exit code is
the verdict. Scenario names: the `SCENARIOS` list in `scripts/e2e/run.sh`.

**If it can't run, say why and ask — don't fall back to `make open` on the host:**
- `VM 'strip-e2e' isn't running` → ask the user to run `tart run strip-e2e` in their own terminal
  (a tool-driven `tart run` never shows its window, and the guest needs a real display).
- `doesn't exist` → `scripts/e2e/vm/setup.sh` (restores from `strip-e2e-golden` if present; otherwise
  interactive, needs the user for the privacy toggles).
- Preflight failure → it names the missing grant; the user fixes it in the VM window.

Never run `make e2e` (host) without the user's OK: it kills their live Strip and needs a desktop
with no other windows.

## Read a failure

Each failing scenario prints its mismatch and the log block it checked. More detail lives in the
guest: `tart exec strip-e2e cat /tmp/strip-e2e.log` (Strip's verbose log for the run) and
`/tmp/wm-e2e-output.log` (the suite's output). A scenario that fails in the full run but passes alone
(`E2E_ONLY=…`) is usually a timing margin (TESTING.md §5), not a Strip bug — say which it was.

## Extend — every behavior fix gets a scenario

1. Add a function to `scripts/e2e/scenarios.sh` (layout/hotkeys) or `scripts/e2e/search_scenarios.sh`
   (Overview/search), returning 0/1 and printing the mismatch; list it in `run.sh`'s `SCENARIOS`.
2. Drive it with `lib/driver.sh`: `send_hotkey`, `send_key <name> [mods]`, `type_text`, `click_menu`,
   `click_submenu`, `real_window_frame`. Fixture: Console, Activity Monitor, Preview at 60% size.
3. Assert on the log (`lib/log_assert.sh`: `checkpoint` then `wait_for_line` / `wait_for_new_apply` /
   `wait_for_total_count`), and on real state via System Events where the log isn't proof enough.
4. **If the behavior isn't visible in the log, add a log line in Strip first** — `STRIP_VERBOSE`-only
   if it's chatty. Search lines carry counts and app names only, never query text or titles.
5. Run the new scenario alone, then the whole suite.

## Limits (manual-only — TESTING.md §2)

Mouse hover and positioned clicks on the SwiftUI overlay (card clicks), real browsers (no
Firefox/Chromium in the VM), visual polish, held-key auto-repeat, and timing numbers (VM timing isn't
host timing — use the perf-measure skill with xctrace attached to the user's instance).
