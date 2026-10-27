---
name: perf-measure
description: Run the MEASURE-FIRST performance workflow for Strip — baseline a trace, A/B a change with an identical controlled workload, query p50/p90/max from DuckDB, and record the verdict. Use before/after any perf-sensitive change to Animation/, Layout/, or AX enumeration paths.
---

# perf-measure

Enforce Strip's **MEASURE-FIRST** rule (CLAUDE.md, hard rule): no performance change lands without a
measurement that justifies it. `MEASURING.md` is the authoritative how-to — read it for the full
detail and the hard-won gotchas. This skill is the checklist that keeps the ritual honest.

## When to use

Before AND after any change to a hot path: `Animation/` (springs, `WindowAnimator`, `setFrame`),
`Layout/` (`resolve()`/`placements`), or AX enumeration/reconcile (`AccessibilityService`,
`WindowObserver`). If the thing isn't measurable yet, the **first** change is an `os_signpost`, not a
fix.

## Where to measure (pick before step 1)

- **Timing on real hardware → attach to the user's running Strip.** `xcrun xctrace record --template
  Logging --attach "$(pgrep -x Strip)" …` records it **without relaunching** — the user drives the
  workload (or you send synthetic chords, with their OK, since they land on their real windows).
  Same build for A and B needs a relaunch between them: that's a `make open`, so ask first.
- **Counts and structural invariants (reconciles, `allWindows` n=0, presses per pick) → the VM.**
  `make e2e-vm` runs a fresh build in isolation; add a scenario that asserts the count. VM timings
  are not representative of host hardware — don't use them for p50/p90 verdicts.
- **Prerequisite:** `duckdb` (`brew install duckdb`) for the DuckDB queries below; ask before
  installing. Without it, report signpost percentiles from the trace another way and say so.

## The workflow (do these in order)

1. **Baseline before touching code.** Capture a trace of the real hot path with a controlled,
   repeatable workload; read **p50 / p90 / max** (the tail is the bug). Pick the workload that
   actually exercises the change — a continuous-motion storm and a settle-based reseed can give
   opposite verdicts (MEASURING.md §5.1, §6).

2. **A/B with an identical workload.** Same window set, same chord count + cadence, before vs after.
   Prefer a true before/after via `git stash` over a remembered baseline (MEASURING.md §6).

3. **Canonical recipe** (MEASURING.md §10):
   ```sh
   # Host A/B: the build under test must be the running one — `make open` (ask the user first),
   # or attach to whatever the user already runs.
   PID=$(pgrep -x Strip)
   xcrun xctrace record --template Logging --attach "$PID" --time-limit 16s --output .build/run.trace &
   sleep 2   # lead-in so the trace is warm before the workload
   for i in $(seq 1 30); do
     osascript -e 'tell application "System Events" to key code 37 using {control down, option down}'
     sleep 0.22
   done
   wait
   .claude/skills/instruments-analyzer/scripts/export_to_duckdb.py .build/run.trace .build/run.duckdb
   duckdb .build/run.duckdb -c "SELECT name, count(*) n,
     round(quantile_cont(duration_ns,0.5)/1e6,3) p50_ms,
     round(quantile_cont(duration_ns,0.9)/1e6,3) p90_ms,
     round(max(duration_ns)/1e6,3) max_ms
     FROM os_signpost_intervals GROUP BY name ORDER BY name;"
   ```
   - **Pin the pid** — an empty `--attach` silently records nothing.
   - Pick the chord that drives what you're measuring (MEASURING.md §5 table): `37`=⌃⌥L slide,
     `29`=⌃⌥0 reseed-all (max animate-seeding), focus-only (`40/38/48`) must do **zero** `allWindows`.

4. **Acceptance bar** (MEASURING.md §2 healthy-readings table): `apply` max under a frame;
   `placements` sub-ms; `animate` sub-ms; `allWindows`/`watchWindows` **n=0** on pure focus/activation;
   `tapDisabled` = 0; report p50/p90/**max**, never averages.

5. **Caveats that invalidate a synthetic result** (MEASURING.md §5): synthetic keystrokes carry
   `autorepeat=0` (can't test held-key pacing — the user is the oracle) and delivery-time timestamps
   (`chordLatency` reads ~0). For visual changes, verify with eyes captured **across** a state change
   (`screencapture`, §7).

6. **Commit with the numbers.** Every perf commit body states measured **before→after AND the exact
   workload**. Then update the `perf-review-2026-06` engram/memory note with the verdict (and any
   platform constraint discovered, so a future session doesn't re-fight a dead end).

## Respect proven dead ends (don't re-measure these)

- `kAXWindows` enumeration is **main-thread-only**; the lever is **frequency**, not threading
  (`mem_search "ax-enumeration-main-bound"`).
- SwiftUI/AppKit rendering is **main-thread-only**; make it cheap, don't relocate it.
