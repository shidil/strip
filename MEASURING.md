# MEASURING.md — running, testing & measuring Strip

The toolkit used across the performance campaign to run, test, and measure Strip — with the exact
commands and the non-obvious gotchas that make each one actually work. Grouped by purpose.

> Coordinates everything internal is **Quartz global** (top-left origin). Subsystem for all signposts
> is `com.spike.strip`, category `hotpath`. See also `OPTIMIZATION_PLAN.md` (the in-repo capture of the
> review + the shipped before/after ledger), `PLAN.md`, `HANDOFF.md`, `CLAUDE.md`.

> **Provenance — the external "Performance Review & Optimization Plan" artifact is a PRE-campaign
> snapshot.** It was the planning doc; its Phase 0 premise ("zero `os_signpost` usage exists in
> `Sources/`") is now **false** — the full signpost set in §2 shipped, and its risk IDs (R1–R10) map to
> merged commits (see `OPTIMIZATION_PLAN.md`). Treat the artifact as history, not current state. **This
> file + `OPTIMIZATION_PLAN.md` + the engram notes (`perf-review-2026-06`) are the source of truth.**

---

## 1. Running the app (trusted launch)

- **`make open`** — the *only* trusted run. Builds, signs with the stable "Strip Dev" cert, and
  launches via LaunchServices so Accessibility/TCC is granted. Running the binary from a shell
  (`make run`) is **not** trusted — TCC attributes it to the parent shell and AX calls degrade/fail.
- **Confirm a stable pid before doing anything:**
  ```sh
  sleep 4; pgrep -x Strip
  ```
  `open` sometimes returns LaunchServices `-600` right after killing the old instance — just retry
  `open .build/Strip.app`, then re-check `pgrep`.
- **`/tmp/strip.log`** — `open`-launched agents have **no stdout**, so the app logs here. `tail` it to
  observe window placements, focus (`● … ◀focus` marks the centered/focused window), hotkeys, errors.
  **Never delete this sink** — it's the only runtime observability for a trusted launch.
- **Signing must stay stable** or every rebuild invalidates the AX grant. If the identity changes:
  `tccutil reset Accessibility com.spike.strip`, `make open`, re-toggle in System Settings → Privacy
  & Security → Accessibility.

---

## 2. Instrumentation (os_signpost)

`Sources/StripKit/Signpost.swift` wraps an `OSSignposter` (subsystem `com.spike.strip`, category
`hotpath`). Two shapes:

- **Intervals** (durations) — `beginInterval`/`endInterval`, paired with `defer`:
  ```swift
  let st = Signpost.log.beginInterval("animate")
  defer { Signpost.log.endInterval("animate", st, "targets=\(targets.count)") }
  ```
  Present intervals: `apply`, `animate`, `frame`, `placements`, `allWindows`, `refresh`,
  `watchWindows`, `overlayRender`.
- **Events** (points in time):
  ```swift
  Signpost.log.emitEvent("inFlightDrop", "id=\(id)")
  ```
  Present events: `setFrame.enqueue` / `setFrame.done`, `inFlightDrop`, `reconcile` /
  `reconcile.skip`, `chordLatency` (`us=…`), `tapDisabled`.

**Hard-won rules:**
- **Add a signpost when the cost moves out of view.** Once the overlay render was deferred onto a
  throttle timer it left the `apply` interval, so `apply` duration no longer captured it — a dedicated
  `overlayRender` interval was added to measure it directly. If a number stops adding up, the work
  probably moved to a different runloop turn; instrument *that*.
- **Integer metadata lives in `os_signpost_arg.value`**, NOT the rendered message. Join on it for
  per-id breakdowns (e.g. drops per window).
- **`start_thread_tid`** attributes a signpost to a thread — used to prove `kAXWindows` enumeration is
  main-bound (the dominant cost) vs per-window IPC.
- Signposts are **zero-cost when not tracing**; keep the useful ones permanent.
- **Not every verification is a duration signpost — some are count-based.** "How many times did
  `resolve()` run per `apply()`?" (the 5→1 dedup target) or "how many `setSize` calls per frame?" have
  no permanent interval; they're proven with a *temporary* counter (a local `var n += 1` logged once,
  or a throwaway `emitEvent`) added for the A/B and reverted after. Don't add a permanent signpost for a
  one-shot structural-invariant check — instrument it, measure it, pull it back out.

### Signpost → question → healthy value (quick index)

What each permanent signpost is *for*, and what "good" reads like (144 Hz dev machine, working set
`cols`≈3–4). Use as the acceptance bar when re-measuring.

| Signpost | Answers | Healthy reading |
| --- | --- | --- |
| `apply` (interval) | chord→layout→enqueue cost on main | p50 ≈ 3–6 ms; **max under a frame** — a focus-change slide must not spike to 20–60 ms |
| `placements` (interval) | pure layout (`resolve()`) cost | sub-ms; never the bottleneck at real ring sizes |
| `animate` (interval) | spring-seeding cost on main | sub-ms (post-33273ea); a spike means sync AX IPC crept back into seeding |
| `frame` (interval) | per-tick spring step + write enqueue | ~6.9 ms floor at 144 Hz; a sub-1 ms outlier is two signposts back-to-back, not a real frame |
| `allWindows` (interval) | full all-apps enumeration (main-bound) | **n = 0 on pure focus/activation**; runs only on real membership change |
| `watchWindows` (interval) | per-app `kAXWindows` re-attach copy | **n = 0 on re-activation** of an already-observed app |
| `refresh` (interval) | full reconcile wall-time | membership-only; ~25 ms typical, ~50 ms tail acceptable (infrequent) |
| `overlayRender` (interval) | SwiftUI overlay render on main | p50 ≈ 0.1–0.2 ms (post-850d768); no forced `layoutSubtreeIfNeeded` on the slide path |
| `reconcile` vs `reconcile.skip` (events) | membership-change vs no-op focus | **skips dominate** a Cmd-Tab storm |
| `setFrame.enqueue` / `inFlightDrop` (events) | AX write volume + backpressure | drops *evenly distributed* across windows = healthy coalescing; concentrated on one pid = slow-app pathology (see §8) |
| `chordLatency` (event, `us=`) | real hardware-key → callback latency | only meaningful on a **physical** keypress — synthetic keystrokes read ~0 (§5) |
| `tapDisabled` (event) | OS disabled the ⌃⌥ tap (main blocked too long) | **0** — any occurrence means a main-thread block exceeded the tap timeout |

---

## 3. Tracing (xctrace)

```sh
PID=$(pgrep -x Strip)
xcrun xctrace record --template Logging --attach "$PID" --time-limit 16s --output .build/<name>.trace
```

- Run the record **in the background**, then `sleep 2` (lead-in) before driving the workload, so the
  trace is attached and warmed before events start.
- An **empty `--attach` silently no-ops** (prints usage and records nothing) — always pin the pid.
- `make profile` attaches xctrace to a `make open` instance (default "Logging" template). For
  main-thread stalls use the Time Profiler template.

---

## 4. Export & analysis (DuckDB)

```sh
.agents/skills/instruments-analyzer/scripts/export_to_duckdb.py <trace> <out.duckdb>
duckdb <out.duckdb> -c "…"
```

Tables: `os_signpost_intervals` (durations), `os_signpost` (events), `os_signpost_arg` (metadata).

- **Always report p50 / p90 / max, not averages** — the *tail* is the bug:
  ```sql
  SELECT name, count(*) n,
    round(quantile_cont(duration_ns,0.5)/1e6,3) p50_ms,
    round(quantile_cont(duration_ns,0.9)/1e6,3) p90_ms,
    round(max(duration_ns)/1e6,3) max_ms
  FROM os_signpost_intervals
  WHERE name IN ('frame','animate','apply','overlayRender')
  GROUP BY name ORDER BY name;
  ```
- **Per-id event breakdown** (e.g. drops vs enqueues per window) via the arg table:
  ```sql
  SELECT signpost_name, value AS wid, count(*) n
  FROM os_signpost_arg
  WHERE signpost_name IN ('inFlightDrop','setFrame.enqueue')
  GROUP BY signpost_name, value ORDER BY wid;
  ```
- **Watch for UINT64 underflow** when subtracting timestamps (`start_ns - other`) — cast to `INT128`
  when computing offsets relative to a reference event, or DuckDB throws "Overflow in subtraction".

---

## 5. Synthetic workload generation

Permission-free hotkey chords reach Strip's global CGEventTap:

```sh
osascript -e 'tell application "System Events" to key code 37 using {control down, option down}'  # ⌃⌥L slideNext
```

All chords are `⌃⌥` + a key; modifiers are `{control down, option down}` (add `shift down` for the
move variants). The full map (from `HotkeyService.swift:95`), grouped by the hot path each exercises —
**pick the chord that actually drives the thing you're measuring** (§6):

| Path measured | Chord | `key code` | Command | Notes for workloads |
| --- | --- | --- | --- | --- |
| **slide** (spring / `frame` / `setFrame`) | ⌃⌥L / ⌃⌥H | 37 / 4 | `slideNext` / `slidePrev` | the canonical motion storm |
| **move** (ring mutation + reseed) | ⌃⌥⇧L / ⌃⌥⇧H | 37 / 4 +shift | `moveNext` / `movePrev` | exercises `reorderedRing` |
| **focus-only** (must NOT enumerate) | ⌃⌥K / ⌃⌥J / ⌃⌥Tab | 40 / 38 / 48 | `focusNext` / `focusPrev` | acceptance: `reconcile.skip`, **zero `allWindows`** |
| **cols / resize** (double-setSize clamp path) | ⌃⌥1 / 2 / 3 | 18 / 19 / 20 | `cols(n)` | width change → real resize writes |
| resize | ⌃⌥= / ⌃⌥− | 24 / 27 | `focusWider` / `focusNarrower` | |
| height / gaps | ⌃⌥↑ ↓ / ⌃⌥[ ] | 126 125 / 33 30 | `taller`/`shorter`, `gapTighter`/`gapLooser` | |
| **pin** (cold-path `resolve()`) | ⌃⌥P | 35 | `togglePin` | once-per-gesture |
| emphasis / transition | ⌃⌥E / ⌃⌥T | 14 / 17 | `toggleEmphasis` / `cycleTransition` | |
| **reseed** (max animate-seeding) | ⌃⌥0 | 29 | `releaseAll` | the apples-to-apples reseed storm |
| overview / help | ⌃⌥Space / ⌃⌥/ | 49 / 44 | `toggleOverview` / `toggleHelp` | |

- `key code 37` = ⌃⌥L (slideNext); `key code 29` = ⌃⌥0 (releaseAll / reseed-all = max
  animate-seeding workload). Loop with `sleep 0.22` between for a "storm"; a **tight AppleScript
  `repeat` loop** (no sleep) simulates a flood/backlog:
  ```sh
  osascript -e 'tell application "System Events"
    repeat 80 times
      key code 37 using {control down, option down}
    end repeat
  end tell'
  ```

**Two caveats learned the hard way:**
1. **Synthetic keystrokes carry `autorepeat = 0`.** They can *only* exercise the discrete/tap code
   path — never the OS key-repeat (held-key) path. So anything gated on auto-repeat (e.g. held-slide
   pacing, `minNavInterval`) **cannot be validated synthetically** — a physically held key is
   required, and **the user is the oracle** for that feel.
2. **Synthetic timestamps are delivery-time**, so `chordLatency` reads ~0 under synthetic load. That
   metric only measures *real* hardware-key latency (including main-thread block time).

### 5.1 Named workloads (the campaign recipes)

Keep these constant across the campaign (§6). Each row is one reproducible scenario: what it targets,
the exact recipe, the signpost(s) that read it, and the healthy result. **Always the same window set**
(the campaign reference is 4 windows / 4 apps — Ghostty×2 / Slack / Firefox — unless noted).

**Motion / animation path** (R2 — springs, `setFrame`, seeding):

| Workload | Recipe | Reads | Healthy |
| --- | --- | --- | --- |
| **slide storm** | 30× ⌃⌥L spaced `@0.22s` (canonical recipe, §10) | `frame`, `apply`, `setFrame.enqueue` | `frame` ~6.9 ms floor @144 Hz; `apply` max under a frame |
| **held-slide flood** | 80× ⌃⌥L tight `repeat` (no sleep) | `apply`, `frame` | no freeze; spring chases an advancing target |
| **held-slide pacing** | a *physically* held ⌃⌥L | — (feel) | clean glide ~5 win/s, no mid-flight bunching — **synthetic can't exercise this; user is oracle** |
| **reseed / release-all storm** | ⌃⌥0, settle-based repeat | `animate`, `apply` | `animate` sub-ms (post-`33273ea`); correct A/B base for `inFlightDrop` |
| **continuous-motion storm** | back-to-back slides, no settle between | `inFlightDrop` ratio | drops *evenly distributed* across window ids (healthy coalescing, not a slow-app pathology) |
| **cols / resize burst** | ⌃⌥1 / 2 / 3 cycled | `setFrame.done` | resize defeats clamping; no size drift on a pure slide |

**Enumeration / reconcile path** (R1·R3 — `allWindows`, observers):

| Workload | Recipe | Reads | Healthy |
| --- | --- | --- | --- |
| **activation / Cmd-Tab storm** | `open -a Firefox` / `open -a Slack` ×30 = 60 activations | `allWindows`, `watchWindows`, `refresh`, `reconcile`/`.skip` | **n=0** `allWindows`/`watchWindows`; skips dominate |
| **focus-only storm** | ⌃⌥J / ⌃⌥K / ⌃⌥Tab repeated | `reconcile.skip`, `allWindows` | `reconcile.skip`, **zero `allWindows`** |
| **membership change** | open / close real windows | `refresh`, `reconcile` | new window centers; close hands center to a neighbor; ~25 ms typical / ~50 ms tail (infrequent) |
| **insert burst** | synthetic 50-new-vs-50-existing reconcile | `refresh`, `insertManaged` loop (`StripController.swift:177`) | open-right-of-focus ordering preserved; **currently O(k·n)** per-insert (each hits `assignment()`+`reorderedRing()`) — Task 2.3 would make it O(n+k) |

**Input / overlay / idle:**

| Workload | Recipe | Reads | Healthy |
| --- | --- | --- | --- |
| **chord-latency / tap-disable** (R4) | idle vs a reconcile storm hammering main | `chordLatency`, `tapDisabled` | `tapDisabled` = **0**; `chordLatency` meaningful only on a *physical* key |
| **overlay burst** (R5) | the slide storm above | `overlayRender` | p50 ≈ 0.1–0.2 ms; no forced layout on the slide path |
| **drag bracket** | mouse down → move → up on a window | `refresh` | no reconcile during drag; snap-back glides from the drop point |
| **idle baseline** | no input (display link auto-stops) | `frame` gaps | large `frame` gaps with **zero applies inside them** = idle, *not* a freeze (§8) |

---

## 6. A/B testing methodology

- **Identical controlled workload both runs** — same window set, same chord count + cadence — so
  before/after is comparable. Keep the recipe constant across the whole campaign.
- **`git stash` for a true before/after** (rather than trusting a stale doc estimate):
  1. `git stash push -u` → working tree is the old (committed) code.
  2. Add *just* the measuring signpost to the old code path.
  3. Build, run the identical workload, record the "before" number.
  4. `git checkout -- <file>` to drop the temp signpost edit.
  5. `git stash pop` to restore the new work.
  This is how the real "before" `overlayRender` (3.54 ms) was obtained.
- **Pick the workload that actually exercises the thing.** `inFlightDrop` looked *worse* (52%) under a
  continuous-motion slide storm but was 5.6% under a settle-based reseed storm — the reseed was the
  correct apples-to-apples comparison. The wrong workload gives the wrong verdict.
- **Commit discipline:** every perf commit body carries the measured before/after **with the exact
  workload**, so the result is reproducible and reviewable.

---

## 7. Visual verification (screen recording)

```sh
screencapture -x /tmp/shot.png   # then Read the image
```

- How the overlay was confirmed to actually render: the rail highlight *moved* between slides, the
  pill app-name/clock updated, the focus ring tracked, chips stayed centered.
- **Requires Screen Recording permission** for the CLI/terminal — fails with "could not create image
  from display" until granted.
- **Prove change, not just presence.** Capture *across* a state change (e.g. slide to a *different*
  app, then compare two screenshots) so a stale first render can't masquerade as a working one.

---

## 8. Derived metrics & their traps

- **FPS from `frame` interval gaps:** `1000 / (median inter-frame gap in ms)`.
  ```sql
  WITH g AS (SELECT start_ns - lag(start_ns) OVER (ORDER BY start_ns) AS gap_ns
             FROM os_signpost_intervals WHERE name='frame')
  SELECT round(1000.0/(quantile_cont(gap_ns,0.5)/1e6),0) fps_p50,
         round(1000.0/(quantile_cont(gap_ns,0.9)/1e6),0) fps_p90
  FROM g WHERE gap_ns IS NOT NULL AND gap_ns < 100000000;
  ```
  Peak ≈ display refresh (a ~6.9 ms floor confirmed 144 Hz; a sub-1 ms outlier is just two signposts
  landing back-to-back, not a real frame).
- **Freeze detector — but filter out legitimate idle pauses.** The display link `stop()`s (pauses)
  when all springs settle, so large `frame` gaps with **zero applies during them** are idle, not
  freezes. Cross-check by counting applies inside each gap, and/or restrict to the active-burst window:
  ```sql
  WITH g AS (
    SELECT start_ns, lag(start_ns) OVER (ORDER BY start_ns) AS prev_ns,
           start_ns - lag(start_ns) OVER (ORDER BY start_ns) AS gap_ns
    FROM os_signpost_intervals WHERE name='frame')
  SELECT round(gap_ns/1e6,1) gap_ms,
         (SELECT count(*) FROM os_signpost_intervals a
          WHERE a.name='apply' AND a.start_ns BETWEEN g.prev_ns AND g.start_ns) applies_during_gap
  FROM g WHERE gap_ns IS NOT NULL ORDER BY gap_ns DESC LIMIT 6;
  ```
- **Backpressure ratio:** `inFlightDrop / (setFrame.enqueue + inFlightDrop)`, broken down per window id
  (via `os_signpost_arg`) to distinguish healthy *distributed coalescing* (drops spread evenly across
  all windows under continuous motion) from a *single-slow-app pathology* (drops concentrated on one
  pid).
- **Membership vs activation:** in a Cmd-Tab / activation trace, count `allWindows` intervals vs
  `reconcile.skip` events — skips should dominate (pure focus does no enumeration). Enumeration should
  only run on real window-membership changes.

---

## 9. Correctness / regression guardrails alongside perf

- **`make test`** every change (pure engine tests, no permissions). Single test/suite:
  `swift test --filter StripLayoutTests/testRingWrapsAround`.
- **Extract pure logic to keep it headless-testable** even for AppKit/SwiftUI-heavy work — e.g.
  `RailItem` / `StatusFields` `Equatable`, `railNeedsRefit(oldCount:newCount:)`, `reconcileKind(for:)`,
  `batchAction(…)`. AppKit views themselves can't be meaningfully unit-tested; the *decisions* around
  them can.
- **Keep Swift language mode v5** (`Package.swift`) — avoids Swift 6 Sendable friction with
  CoreFoundation/AX types.
- **Record the verdict AND the platform constraint** in the memory notes (`perf-review-2026-06` and
  engram) so a future session doesn't re-attempt a proven dead end. The two big constraints:
  - **`kAXWindows` enumeration is main-thread-only** (off-main returns degraded data). Per-element AX
    reads/writes on an already-obtained window element *do* work off-main on a per-pid serial queue.
  - **SwiftUI/AppKit view rendering is main-thread-only** — it can't move off-thread; the lever is
    making it cheap (incremental updates, no forced layout), not relocating it.

---

## 10. The canonical measurement recipe (end to end)

```sh
# 1. Build + launch the trusted instance.
make open && sleep 4 && pgrep -x Strip

# 2. Start the trace in the background (pin the pid!).
PID=$(pgrep -x Strip)
xcrun xctrace record --template Logging --attach "$PID" --time-limit 16s --output .build/run.trace &

# 3. Lead-in, then drive an identical, controlled workload.
sleep 2
for i in $(seq 1 30); do
  osascript -e 'tell application "System Events" to key code 37 using {control down, option down}'
  sleep 0.22
done
wait

# 4. Export + query.
.agents/skills/instruments-analyzer/scripts/export_to_duckdb.py .build/run.trace .build/run.duckdb
duckdb .build/run.duckdb -c "SELECT name, count(*) n,
  round(quantile_cont(duration_ns,0.5)/1e6,3) p50_ms,
  round(quantile_cont(duration_ns,0.9)/1e6,3) p90_ms,
  round(max(duration_ns)/1e6,3) max_ms
  FROM os_signpost_intervals GROUP BY name ORDER BY name;"

# 5. (If it's a visual change) confirm with eyes.
screencapture -x /tmp/shot.png   # then inspect
```
