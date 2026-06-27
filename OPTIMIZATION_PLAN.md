# OPTIMIZATION_PLAN.md — Strip performance: living backlog

The **working source of truth for actioning Strip performance work.** It captures the off-repo
"Performance Review & Optimization Plan" artifact (now historical — see Provenance) and tracks every
task through to a measured verdict. When you pick up, ship, defer, or close an item, **update this
file** — it is meant to drift forward with the code, not freeze.

- *How to measure / reproduce any number here* → `MEASURING.md` (signposts, named workloads §5.1,
  DuckDB queries, A/B recipe).
- *Why measure-first is mandatory* → `CLAUDE.md` "Performance work — MEASURE FIRST (enforced)".
- *Deeper rationale / verdict history* → engram note `perf-review-2026-06`.

> **Provenance.** The external artifact was the *pre-campaign* plan; its premise ("zero `os_signpost`
> exists") is now false. Its risk IDs (R1–R10) and task IDs (0.x–3.x) are preserved here and mapped to
> shipped commits. The artifact is history; **this file is the live state.**

> **Working-set caveat (kept from the review).** Strip is a niri-style film strip; the real working set
> is `cols` (default 3) centered windows plus parked neighbors — **not** 50–100. Layout
> (`placements` p50 ≈ 0.07 ms) was never a bottleneck. Findings that only bite at unrealistic window
> counts stay low-priority no matter how "incomplete" they look.

## How to action an item

1. **Measure first.** Baseline the hot path with the workload from `MEASURING.md` §5.1 that actually
   exercises it. If it isn't measurable, the first change is a signpost, not a fix.
2. **A/B via `git stash`** (MEASURING.md §6) — same window set, same workload, before vs after.
3. **Commit with the numbers** — every perf commit body states measured before→after + the exact
   workload.
4. **Update this doc** — move the item from _Open backlog_ to _Shipped ledger_ with its commit + numbers
   (or to _Closed without code_ with the decision). Keep the at-a-glance table in sync.

---

## Status at a glance (snapshot 2026-06-27)

**10 done · 1 partial · 7 closed/deferred · 0 open — the campaign is complete.** Every task reached a
terminal state: shipped with measured numbers, or closed/deferred with the measurement (or correctness
argument) that justifies it. The 7 closures were all confirmed *measure-first* — each was profiled or
microbenched and found cold/cheap, not assumed. Verified task-by-task against source + git history.

| ID | Task | Status | Commit |
|---|---|---|---|
| 0.1 | Command-path signposts (apply/placements/animate) | ✅ done | `c79b659` |
| 0.2 | Tick/write signposts + `inFlightDrop` counter | ✅ done | `c79b659` |
| 0.3 | Enumeration signposts (refresh/allWindows) | ✅ done | `c79b659` |
| 1.1 | Cut redundant reconciles (self-activation + focus-only skip) [OPP-1] | ✅ done | `bc6bdd1`+`44510a5` |
| 1.2 | Stop re-writing settled windows [OPP-2] | ✅ done | `41d9fcd` |
| 1.3 | Dedup double frame read | ✅ done | `293f656` |
| 1.4 | `watchAllWindows` re-activation skip | ✅ done | `382b45d` |
| 1.5 | Gate `logState` + static `DateFormatter` | ✅ done | `5a7d68b` |
| 1.6 | Focus-ring dedup + `display:false` | 🚫 not-needed | — |
| 2.1 | One `resolve()` per `apply()` + reverse index [OPP-3] | 🚫 not-needed | — |
| 2.2 | Overlay snapshot `Equatable` early-out [R5] | ✅ done | `f6efcc8` |
| 2.3 | Batch `insertManaged` bursts | 🚫 not-needed | — |
| 2.4 | AX write completion: batch bookkeeping | 🚫 not-needed | — |
| 2.5 | Off-main enumeration | 🟡 partial | `1b3f884` (2.5a) / `b7ae9f2` (2.5b reverted) |
| 3.1 | Move ⌃⌥ tap off main run loop | 🚫 not-needed | `e166ea7` |
| 3.2 | Drop dead per-pid `queues` | 🚫 not-needed | — |
| 3.3 | CI stage 1 — `swift test` on PR | ✅ done | `32979df` |
| 3.4 | Layout `measure` baseline | 🚫 deferred | — |

---

## Open backlog

**Empty — 0 open items.** Every task is shipped (see _Shipped ledger_) or closed/deferred (see _Closed
without code_). New ideas go here, then through the _How to action an item_ loop above. When picking one
up, measure first; don't reopen a _Closed without code_ item without a measurement that contradicts the
one that closed it.

---

## Shipped — verdict ledger (measured before → after)

Each row is a controlled A/B with the exact workload (`MEASURING.md` §5.1/§6) and the os_signpost it was
read from. Durations p50 / p90 / max unless noted.

| Task (risk) | Change | Commit | Workload | Signpost | Before → After |
| --- | --- | --- | --- | --- | --- |
| 0.1–0.3 | Phase 0 hot-path os_signpost instrumentation | `c79b659` | — | — | enables every number below (zero-cost when not tracing) |
| 1.1 (R1) | Skip full `allWindows()` on pure focus/activation + self-activation suppression | `bc6bdd1`+`44510a5` | 60 activations (`open -a` Firefox/Slack ×30) | `allWindows` | n=40 · 16.4 / 18.2 / 19.6 ms → **n=0** (37 of 38 → `reconcile.skip`) |
| 1.2 (R2) | Settled-window write-skip + pure-move setSize elision | `41d9fcd` | reseed storm | `inFlightDrop` | ~38% baseline (55% during settle) → settled windows pay 0 IPC/frame |
| 1.3 (R1) | Read window frame once per scan | `293f656` | activation storm | `allWindows` | 2 frame IPC/window → 1 (behavior-identical) |
| 1.4 (R1·R3) | Don't re-`watchAllWindows` on every activation | `382b45d` | same 60-activation storm | `watchWindows` | n=35 · 21.1 / 48.2 / 50.5 ms (887 ms total main) → **n=0** |
| 2.2 (R5) | Overlay `Equatable` early-out + incremental SwiftUI (concrete hosting views) | `f6efcc8` | 30-slide storm | `overlayRender` | 3.54 / 4.93 / 5.14 ms → 2.40 / 2.88 / 4.01 ms |
| 2.2 cont. (R5·R7) | Fixed-geometry status pill (drop last forced layout) | `850d768` | same 30-slide storm | `overlayRender` | 2.40 / 2.88 / 4.01 ms → **0.13 / 0.18 / 0.24 ms** (~96% below original) |
| 2.5a (R1) | Cache immutable per-window AX attrs across scans | `1b3f884` | activation storm, fixed set (apps=11, win=4) | `allWindows` | 74.6 / 216.7 / 235.1 ms → 34.0 / 44.4 / 66.4 ms (**−54 / −80 / −72%**) |
| (seeding) (R2·R10) | Remove synchronous AX IPC from spring seeding | `33273ea` | release-all reseed storm, 4-win/4-app, 16 s | `animate` | 6.70 / 8.16 / 9.45 ms → 0.72 / 1.12 / 1.17 ms (**−89 / −86 / −88%**); `apply` max 12.92 → 6.40 ms |
| (slide fix) | Coalesce slide commands; focus off the hot path | `96e4bbd` | 30 spaced @0.22s + 80-chord tight hold | `apply`, `frame` | `apply` max **428 → 61 ms** (p50 20 → 6.4); held key: **freeze → 162 frames/2.2 s (~73 fps)**; `frame` p90 0.73 ms |
| (held pacing) | Pace held-key scroll ~5 win/s (autorepeat-aware) | `81fa701` | physically held key (user is oracle) | — (feel) | mid-flight bunching → clean glide; synthetic keys can't exercise (`autorepeat=0`) |

## Closed without code (decisions — do not re-open lightly)

| Item | Decision | Commit | Basis |
| --- | --- | --- | --- |
| 3.1 — ⌃⌥ tap off main | **NOT-NEEDED** | `e166ea7` | A/B: 0 `tapDisabled` drops idle + under reconcile storm; worst main block ~25–53 ms (membership-only), well under tap timeout. Off-main adds concurrency cost for no measured gain. Added `chordLatency`/`tapDisabled` instrumentation to catch regressions. Revisit only if large/frequent synchronous main-thread spans return. |
| 3.2 — drop dead per-pid `queues` | **NOT-NEEDED (correctness hazard)** | — | The per-pid serial queue is **deliberately durable** (`WindowAnimator.swift:166-167`): all AX writes for a pid — frame writes *and* the Enhanced-UI suppress/restore toggles — share it "so they stay ordered." Pruning a pid's queue while a restore (`EnhancedUI.set(true)`) or frame write is still pending, then re-animating the same pid, would create a *second* serial queue and lose the cross-queue FIFO ordering → EnhancedUI could be left enabled during motion (constraint-clamping returns). Benefit is a few hundred bytes per dead pid, bounded by distinct apps ever animated. Not worth a concurrency regression. Revisit only if a real unbounded-memory problem is ever measured. |
| 2.4 — AX write completion bookkeeping | **NOT-NEEDED (measured cold)** | — | Measured under a max-stress continuous slide storm (3× 80-chord tight floods, 16 s, `wch24.trace`): **460** `setFrame.enqueue`/completion-hops total; each hop is `inFlight.remove` + `failures.record`, both O(1), no loop/alloc beyond the closure. Frame tick stayed sub-ms (p50 0.31 / p90 0.66 ms); fps p50 143 (≈144 Hz). The only fps dip (p90 32) tracks the `apply`/`animate` coalescing burst tail (127 ms, from `96e4bbd`), **not** the completion hop. Skipping `failures.record` on success would save ~one dict op per write, and `inFlight.remove` must stay on main regardless — unmeasurable. |
| 1.6 — focus-ring dedup + `display:false` | **NOT-NEEDED (measured cold / obviated)** | — | `tick()` calls `emitFocusFrame()` → `onFocusFrame` → `updateFocusRing` → `NSPanel.setFrame(display:true)` **synchronously** on main (`onMain` runs inline on the main thread), so its cost is inside the `frame` signpost interval. Same `wch24.trace`: `frame` p50 0.31 / p90 0.66 / max 3.03 ms at **143 fps**, with the ring redrawing **every tick** (the centered window is in motion, so its frame changes each frame — a dedup couldn't skip those anyway). Dedup would only skip the minority of tail frames where focus settled before siblings — a fraction of an already-sub-ms op. Focus was already made cheap by off-main debounce (`96e4bbd`) + incremental overlay (`f6efcc8`). |
| 2.3 — batch `insertManaged` bursts | **NOT-NEEDED (measured cheap)** | — | Headless burst microbench (best-of-5, pure `StripState.insertManaged` `.focusCenter`): existing→insert 3→10 = **0.11 ms**, 20→20 = 0.40 ms, 50→50 = 1.91 ms, 100→100 = 6.75 ms (the O(k·n) is visible only at 50+). A realistic burst (session-restore / app un-hide, working set `cols`=3) is ≤10–20 windows → **sub-0.5 ms, once per membership reconcile** (not per frame). The partial-hoist refactor + required new multi-insert tests aren't worth a sub-ms one-time cost. Revisit only if 50+ window strips ever become real (they contradict the working-set caveat). |
| 2.1 — one `resolve()` per `apply()` + reverse index [OPP-3] | **NOT-NEEDED (measured cheap)** | — | Headless microbench of `placements(in:)` (best-of-5, 1000×/sample): n=3 = 0.009 ms/call, n=10 = 0.016, n=50 = 0.097, n=100 = 0.30. `apply()` runs ~5 resolves, so at the real working set (`cols`=3, ring ~3–10) the **entire** layout cost — the 5× redundancy *and* the O(n²) `firstIndex` — is **~0.05–0.08 ms/apply**, negligible vs. focus/AX/overlay. OPP-3 would save ~0.04 ms/apply (unmeasurable) while the refactor (threading one `Resolved` through `railSnapshot` + the focus guard, adding `unpinnedIndex`) risks a behavior regression. O(n²) only bites at n=50–100, ruled out by the working-set caveat. |
| 3.4 — layout `measure` baseline | **DEFERRED** | — | Its only rationale was to bolt onto 2.1 (now closed). `XCTClockMetric` is cross-runner noisy — the same reason 3.3 (CI) defers perf-baseline gating — so a wall-clock layout test would flap on hosted runners. Layout is already covered by the `placements` signpost (p50 ~0.07 ms live), and this campaign recorded the absolute baseline via microbench (0.009 ms/call @ n=3). Revisit only if a layout regression is ever observed. |

## Proven dead ends (measured, reverted — DO NOT re-fight)

- **2.5b — off-main `kAXWindows` enumeration** (`6395ddb` → reverted `b7ae9f2`). `kAXWindows` enumeration
  is **main-thread-only**; off-main returns degraded/stale data. Only the per-element attr-cache (2.5a)
  that cuts per-window IPC could ship; `allWindows` still runs ~34 ms p50 on main and that is the floor.
  Per-element reads/writes on an already-obtained window element *do* work off-main on a per-pid queue.
- **SwiftUI/AppKit view rendering off-thread** — impossible; the lever is making it cheap (incremental
  `@Published`, no forced `layoutSubtreeIfNeeded`/rootView rebuild), which 2.2 did.

## The three hot spots (context)

1. **R1 — synchronous AX enumeration per reconcile.** Main-bound; lever is **frequency** (1.1/1.3/1.4)
   + per-window IPC cost (2.5a), not threading (2.5b dead end).
2. **R2 — display-link spring loop writing windows via AX IPC.** Addressed by settled-write-skip (1.2)
   and zero-sync-IPC seeding (`33273ea`). The frame tick is now sub-ms (p50 0.31 ms @ 143 fps under a
   max slide storm); the completion-bookkeeping trim (2.4) was measured cold and closed.
3. **R4 — ⌃⌥ `CGEventTap` on the main run loop.** A *dependent* of R1; closed not-needed (3.1) once main
   stopped blocking.
