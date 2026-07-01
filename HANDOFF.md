# HANDOFF — active task brief

> **This doc is the brief for one task handed to an agent. It is replaced wholesale each time a new
> task starts — it is NOT the roadmap or status record.** For roadmap, milestone status, architecture,
> the verified-seam map, and the do-not-relearn gotchas, read **`PLAN.md`** (the source of truth).
> Engram memory: `mem_context` for project `wm`, or `mem_search "strip-wm-spike"`.

---

## Task

Backlog item "Swap focused ↔ neighbor" — generalize the film-carry command (⌃⌥⇧H/L) from the
*centered* window to whichever window actually has keyboard focus.

## Why / outcome

PLAN.md already documents ⌃⌥⇧H/L as "carry **focused** window along film (reorder)", but the
implementation (`StripController.moveWindow`) actually operates on `state.centerId`, not
`state.focusSlot`'s occupant. These are usually the same window, but diverge once focus is moved
off-center with J/K (`focusMove`) without re-centering. Today, pressing ⌃⌥⇧H/L in that state
silently carries the *wrong* window (the centered one, not the one the focus ring is drawn around) —
a mismatch between documented and actual behavior. Fixing this also gives the two backlog items
"modifier-click swap in the minimap" and "drag-rearrange in the minimap" a correct, reusable
ring-swap primitive to build on.

## Acceptance

- `make test` stays green; the new pure logic is unit-tested headlessly in `StripStateTests`.
- When focus is on the centered slot (the common case today), behavior is unchanged from the old
  `moveWindow` (regression safety).
- When focus has been moved off-center (J/K), ⌃⌥⇧H/L now carries the *focused* window, and keyboard
  focus follows it to its new slot ("focus rides the moved window").
- A window pinned to the focused slot is a no-op (pins stay fixed; carrying a pinned window would
  break that invariant).
- Live-verified via `make open` + `/tmp/strip.log`: J to move focus off-center, then ⌃⌥⇧L, and confirm
  the focus ring follows the window that moved (not the centered one).

## Scope / seams to touch

- `Sources/StripKit/Model/StripState.swift` — add a pure mutating method (e.g. `moveFocused(_ dir:
  Int)`) alongside `togglePin`/`setCenter`/`insertManaged`. Find the focused window via
  `StripLayout(self).assignment()[focusSlot]`, swap its ring position with its ring-neighbor at
  `dir`, then look up its new slot in the recomputed assignment and set `focusSlot` to that — "focus
  rides the moved window". No-op if `pins[focusSlot] != nil` or the ring is empty.
- `Sources/StripKit/StripController.swift` — replace `moveWindow(_ dir:)` (currently swaps
  `state.ring` directly using `state.centerId`) with a thin `moveFocused(_ dir:)` that calls
  `state.moveFocused(dir)` then `apply()`.
- `Sources/StripKit/AppDelegate.swift` — update the two call sites (`.movePrev`/`.moveNext` cases,
  lines ~76-77) from `controller.moveWindow` to `controller.moveFocused`.
- `PLAN.md` — remove the now-shipped "Swap focused ↔ neighbor" line from the "Navigation / commands"
  backlog table; note in the two dependent bullets (modifier-click swap, drag-rearrange) that the
  swap primitive now exists.

## Constraints / watch-outs

- Keep the new logic in `Model/StripState.swift` as a **pure mutating method** — no AppKit/AX — so
  it's unit-testable without a GUI (per CLAUDE.md: "extract pure logic so new decisions stay
  headless-testable").
- `moveWindow` was previously **completely untested** — don't just port it, add real coverage for
  both the regression case (focus == center) and the new case (focus off-center).
- Remember center is *sticky to `centerId`*, not to ring position: `assign[primarySlot]` always shows
  `centerId` regardless of ring reordering (as long as it's unpinned). So carrying a non-centered
  focused window can shift *other* slots by more than one visual position — that's expected, matching
  how the existing centered-window carry already behaved (verify via the manual trace in this task's
  research, not just intuition).
- This is pure `Model`/`Layout` work — no AX, no coordinates, no animation — so it does **not** need
  the `ax-invariant-reviewer` or `measurement-enforcer` agents.

---

## How to work in this repo (task-agnostic — keep)

1. **Orient first.** Read this brief + the relevant `PLAN.md` milestone + `CLAUDE.md`; run
   `mem_context` for project `wm` to recover prior design decisions and gotchas. **Plan before
   coding — the author reviews plans first.**
2. **Trust the build, not the editor.** `swift test` and `make bundle` are authoritative; the
   post-edit SourceKit "cannot find X" diagnostics in this repo are stale/false — don't chase them.
3. **Run live only via `make open`.** A shell-run binary isn't Accessibility-trusted (TCC attributes
   it to the parent shell). `open`-launched agents have no stdout — observe via `cat /tmp/strip.log`.
   Live behavior needs the **author's screen**: a headless agent's startup reconcile finds no windows.
4. **Slice the work.** Prefer independently shippable + testable slices; land pure logic + its tests
   first, wire the AppKit/AX side after.
5. **Close the loop.** Update `PLAN.md` milestone status and `BUGS.md`, `mem_save` the outcome
   (decision/bug-fix/discovery), and for perf work record the before→after + workload.

## Verification

- `make test` — engine correctness, no GUI.
- `make open`, then `cat /tmp/strip.log`; open 5–6 windows on the active display.
- Exercise the task's behavior by hand; for visual changes, verify with eyes (`screencapture`),
  captured *across* a state change so a stale render can't pass.
- Sanity: no SIP, no scripting addition; runs with only the Accessibility (+ Screen Recording) grant.
