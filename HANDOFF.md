# HANDOFF — active task brief

> **This doc is the brief for one task handed to an agent. It is replaced wholesale each time a new
> task starts — it is NOT the roadmap or status record.** For roadmap, milestone status, architecture,
> the verified-seam map, and the do-not-relearn gotchas, read **`PLAN.md`** (the source of truth).
> Engram memory: `mem_context` for project `wm`, or `mem_search "strip-wm-spike"`.
>
> Fill the `<…>` placeholders below for the current task; delete this quote block when you do.

---

## Task

<One line: what to build/fix. e.g. "M8 — workspaces (multiple strips)" or "Bug: minimize-on-close
leaves a gap in the layout (Slack).">

## Why / outcome

<What the user gets when this is done, and why it matters. 1–3 sentences.>

## Acceptance

<Concrete, checkable conditions. e.g.:>
- `make test` stays green; new pure logic is unit-tested headlessly.
- <observable live behavior, verified via `make open` + `/tmp/strip.log` and/or the author's eyes>

## Scope / seams to touch

<The specific files/methods this task hooks into. Cross-reference PLAN.md's "Verified seams" map.
Name the seam, not just the file. e.g.:>
- `StripController` — owns the ring + `refreshAndApply()`; <what changes here>.
- `<file>` — <what changes here>.

## Constraints / watch-outs

<Task-specific traps. Pull the relevant ones from PLAN.md "Critical gotchas" and CLAUDE.md, e.g.:>
- Keep pure layout/state logic in `Layout/` + `Model/` so it stays headless-testable.
- Coordinates are **Quartz global** internally; convert to Cocoa only at the AppKit boundary.
- Perf-sensitive paths (`Animation/`, AX enumeration/reconcile) need a MEASURE-FIRST justification
  (`MEASURING.md`) — and will be checked by the `measurement-enforcer` agent.
- AX/coordinate/animation/identity edits will be checked by the `ax-invariant-reviewer` agent.

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
