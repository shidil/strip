# Design: Seats & Pile

**Status:** Accepted (owner decisions recorded 2026-11-06). Slices 0–1 shipped.
**Replaces:** M8 "Workspaces" and M10 "2-D film" in [`PLAN.md`](../../PLAN.md)
**Origin:** design debate on 2026-11-05: four designer agents (card-table, posture & calm motion,
macOS-native realist, spatial memory) proposed, then each critiqued the other three, then a judge
converged. This document is the converged design with the owner's answers applied.

## Why

Strip exists to keep the important window centered with no conscious effort and to avoid
distracting window movement. The wrapping film fails both goals. An endless slide is niri scrolling
with fixed slots: you still hunt left and right, you still forget to center, and a click on the
right-slot window leaves you working off-center. The owner's brief is **"switch which window is on
any slot, like drawing a card from a pile"**.

Unrelated work is separated with **macOS native Spaces**, not with Strip workspaces.

## The model

- **Seats.** These are the fixed slots: L C R for 3-up, L R for 2-up, C for monocle. Each seat
  shows one window face-up. Seats are places. Windows have no neighbors.
- **One pile.** Every other managed window is face-down in a single pile ordered by recency, most
  recent first. This is the same order ⌘Tab uses. `pile[0]` is the next draw.
- **Three verbs.**
  - **Draw:** put a pile card into a seat.
  - **Promote:** the window you commit to trades into C.
  - **Pass:** the old H/L slide, now bounded and reversible.
- **One motion rule:** **content changes cut; position changes spring.** A cut is an instant
  in-place swap: the incoming window is pre-sized while parked, then placed, and the outgoing
  window is then parked.
- **Displaced windows go back where the replacement came from.** If C's new window came from the
  pile (a draw, a pick, ⌘Tab to a parked window, a new window), the old C goes to the top of the
  pile. If it came from a seat (a promote), the two windows trade seats. *(Owner decision 2.)*

### Pure state (replaces `ring` / `centerId` / `pins` in `StripState`)

```swift
struct Table: Equatable {
  var seats: [Slot: CGWindowID]       // keys ⊆ slots(cols)
  var pile: [CGWindowID]              // MRU; pile[0] = next draw
  var holes: [Slot: CGWindowID]       // seat reserved for a hidden/minimized window
  var hidden: [CGWindowID]            // hidden/minimized windows that own no seat (step 2)
  var locks: Set<Slot>                // today's pins become seat locks
  var focusSeat: Slot
  var lastTrade: (CGWindowID, CGWindowID)?
  var cols: Int; var emphasis: Emphasis; var config: LayoutConfig   // unchanged
}
```

**Invariants (each one a unit test):**

- Every managed window id is in exactly one of `seats`, `pile`, `holes` or `hidden`.
- C is never empty while any card exists.
- No automatic operation changes a locked seat.
- `trade ∘ trade = id`.
- `pass(h) ∘ pass(l) = id`.

**Layout** becomes geometry only: seats map onto the unchanged `SlotGeometry` rects, and pile cards
park off an edge that has no neighboring display. The `resolve()` posMod rotation goes away. A new
pure `transitions(from:to:) -> [id: .stay | .spring | .cut | .snapOffscreen]` turns every motion
budget below into a unit test.

**Migration:** seed `seats` from today's `resolve()` assignment. The pile is the rest of the ring,
ordered outward from the center. From then on, real recency takes over.

## Interactions

| Action | Trigger | Behavior | Windows moved |
|---|---|---|---|
| Draw into a satellite | ⌃⌥U (L) / ⌃⌥O (R) | `pile[0]` takes the seat; the old card goes to the top of the pile, so pressing again toggles back. Focus stays in C. Nothing is activated. An explicit draw works on a locked seat too. | 2, cut |
| Swap the center | ⌃⌥I | The same draw, into C. Focus goes to C. Straight after a new window or a pick, this flips back to the previous center. | 2, cut |
| Choose a deeper card | Hold ⌃⌥ and tap a seat key. **The same** seat key steps one card deeper. **A different** seat key moves the panel to that seat and keeps the card. ⇧ steps back. Releasing ⌃⌥ commits. ⌃⌥Esc cancels. A 1.5 s idle commits. | A hand panel over the target seat shows a frozen MRU row (icon and title). **No window moves while you browse.** | 0, then 2 on commit |
| Any card into any seat | Overview / search / rail chip | See *Picking a target seat*. A window from the pile is drawn; a window already in a seat trades. | 2 (cut from the pile; spring for neighbors; cut for L↔R) |
| Trade with a seat | ⌃⌥⇧U / I / O | The focused window trades with that seat's window, and focus goes with it. ⌃⌥⇧I from a satellite is **promote**. | 2: spring for neighbors, cut for L↔R |
| Promote explicitly | ⌃⌥↩ (alias of ⌃⌥⇧I) | The focused satellite trades with C. If focus is on C, this undoes `lastTrade`. | 2, about 1 seat each |
| **Click a satellite** *(on by default once slice 5 lands; owner decision 1. Until then it sits behind the "Center on click or ⌘Tab" setting, off by default; owner decision 2026-11-06)* | Mouse | Focus follows immediately with 0 motion. A promote fires on a **committed click**: on mouse-up, with less than 4 px of travel, clickCount 1, and no new mouseDown or scroll within `NSEvent.doubleClickInterval`. It never fires on a locked seat, a drag, a text selection or a double-click. A setting turns it off. | 0, then 2 |
| External focus into a visible satellite | ⌘Tab / Dock / notification / ⌘` | Focus follows. A promote fires after a 250 ms trailing settle, **only when the user caused it**: a ⌘-keyDown or a mouseDown within the last 1 s. An app that activates itself only moves focus. | 0, then 2 |
| External focus into a parked window | Same triggers | If the user caused it: after a 120 ms coalesce, draw the window into C as a cut. If not: nothing moves, and the pill says "Focus is in parked ‹App› — ⌃⌥I". | 2, cut |
| New window | `refresh()` | A focused new window (⌘N, app launch) goes into C, and the old C goes to `pile[0]`. A background or batch window goes to the pile with a static "new" dot. If C is locked, the window takes the first unlocked seat, R then L. Small windows still float. | 1 visible + 1 parked |
| Close | Window destroyed | A face-up window's seat refills with the window macOS just focused, if that window is in the pile, otherwise with `pile[0]`, as a cut. A face-down window is simply dropped. If the pile is empty, an empty satellite stays empty, and an empty C promotes the most recently used satellite. | 1 or 0 |
| Hide / minimize | didHide / miniaturized | A satellite becomes a **hole**: no refill, so nothing collides when macOS restores the window to its own frame. A vacancy in C is refilled by a cut. | 0 |
| Restore a window that was in C | Unhide / un-minimize | The restore is user-caused, so the window promotes into C as a cut, and the window that refilled C goes to the top of the pile. Without this, two windows would share the seat. | 1 visible (the restored window is already in the C rect) |
| Pass (old slide) | ⌃⌥H / ⌃⌥L | Shifts the unlocked seats one step. The draw comes from `pile[0]`. Holding the key cycles only the cols+1 most recent cards. A move from off-screen to off-screen snaps. **In monocle, H/L open the hand panel on C instead** (see *Monocle and 2-up*). | 4, 1 seat each (the only fan-out, always explicit) |
| Look without moving | ⌃⌥J / ⌃⌥K / ⌃⌥Tab | Moves focus only. Never promotes. | 0 |
| Bury / put away | ⌃⌥B / ⌃⌥⌫ | Bury sends the card to the bottom of the pile and refills the seat. Put away leaves a **satellite** empty, for deep focus without monocle. On C, put away acts as bury, because C is never empty. | 2 / 1 |
| Lock seat | ⌃⌥P | A locked seat is skipped by pass, new windows, close-refill and every automatic promote. **Exception:** a summon you caused always lands somewhere visible. If every seat is locked, it takes C and the pill says the lock was overridden. | 0 |
| Columns | ⌃⌥1 / 2 / 3 | Shrinking sends the satellites to the pile. Going to monocle, the **focused** window becomes C and the old C goes to the top of the pile. Growing draws `pile[0]` into R, then `pile[1]` into L. In 2-up, L acts as the center. | Up to 2 cuts, plus C resized in place |

### Picking a target seat

U / I / O name the seats L / C / R everywhere. **Choosing a window for a seat is a draw if the
window is in the pile, and a trade if it is already in another seat.** Either way, the displaced
window goes back where its replacement came from.

| Picker | Into C | Into a chosen seat |
|---|---|---|
| Hand panel | Open it with I | The same seat key steps deeper; a different seat key moves the panel to that seat and keeps the card |
| Overview | ↩ or click | u / i / o (plain keys) |
| Search | ↩ | ⌃⌥U / I / O. These join `allowedWhileSearching`, because typed letters are query text. |
| Rail chip | Click | Drag the chip onto a seat (Strip's own panel, no AX) |

- A pick into C focuses it. A pick into a satellite leaves focus where it was, like a plain draw.
- There is no "into the focused seat" shortcut: every target is named, so there is no hidden mode.
- Trading seats directly, without a picker, is ⌃⌥⇧U / I / O (see the interaction table).

### Monocle and 2-up

**Monocle** is C plus the pile:
- ⌃⌥I toggles between your two most recent windows. The hand panel picks deeper.
- ⌃⌥U / I / O all draw into C, and every picker's seat key means C.
- **⌃⌥H / ⌃⌥L open the hand panel on C** and step through the recency list (H back, L forward).
  Nothing moves until you release ⌃⌥ to commit. This replaces today's walk through the whole film
  with zero-motion browsing. *(Owner decision, 2026-11-06.)*
- Trades (⌃⌥⇧U / I / O) and click-to-center do nothing, because there are no satellites.
- Put away on C acts as bury. A lock on C still lets a summon you caused take C (see Lock seat).
- `monocleWidthFraction` and resizing it by dragging the window are unchanged.

**2-up** has seats L and R, and L acts as the center:
- U and I both target L. O targets R.

**Satellite draws are instant cuts by default** *(owner decision 3)*. An optional "Deal" spring
preset slides the card in from the seat's own edge. A "Cut" preset makes promote and pass instant
too.

## What changes vs today

- **Slide** becomes a bounded, reversible **pass**.
- **Ring wrap** is dropped.
- **Pins** become **seat locks**.
- **cols** and **emphasis** are kept.
- **Spring presets** now govern only promote and pass. New "Cut" and "Deal" presets are added.
- **Overview** shows a row of seats plus the pile in MRU order.
- **Search** is kept. ↩ sends the pick to C; ⌃⌥U / I / O send it to a named seat.
- **Exchange with neighbor** (⌃⌥⇧H / ⌃⌥⇧L, today's `moveFocused`) is replaced by trading with a
  named seat (⌃⌥⇧U / I / O), which covers every pair, including L↔R.
- **Rail** becomes TABLE | PILE:
  - Seat chips show a lock glyph, a dashed chip for a hole, and an outline for focus.
  - Pile chips are dimmed, with a "next" caret on the first chip and "+N" past about 8.
  - No pulses and no reorder animation.
- **Focus ring** shows a static amber style on an unlocked satellite, as the "you're working
  sideways" cue.
- **Horizontal/vertical strips sketch:** rows become **macOS Spaces**, with one Table per Space.
  The vertical strip becomes drawing into a chosen seat from the one pile. No vertical parking is
  needed.

## Spaces

There is one `Table` per macOS Space, kept in a `[SpaceKey: Table]` map.

- **SpaceKey:** read the current Space with a read-only private CGS call. It is identity only and
  never moves windows, the same policy as `_AXUIElementGetWindow` (ADR-0002, ADR-0005). If it is
  unavailable, fall back to a fingerprint of the on-screen window set. *(Owner decision 4.)*
- Windows that go missing because of a Space switch are **frozen, not dropped**.
- No AX writes while a Space transition is in progress.
- Suspend management in fullscreen Spaces and under Stage Manager.
- **The automatic behaviors (click-promote, summon, parked draw) do not ship before this guard.**
  Slice 1 ships click-promote and the ⌘Tab-into-satellite promote behind a setting that stays off
  by default until this guard lands (owner decision 2026-11-06). Slice 0's parked-window summon
  shipped without the guard; revisit it with slice 5.
  Today a Space round trip probably drops every window and re-adds it as new, which would set off
  those behaviors by mistake.

## Alternatives rejected

- **Ring with adjacent insertion ("Calm Center v1").** This is still the niri scroll. Park side
  comes from ring distance, which sends parked windows across the screen.
- **Three per-seat decks (spatial designer).** Decks drift, and filing brings back "where is it?".
  In 2-up a whole deck is hidden. The owner's image is a single pile. This design keeps the
  spatial designer's cut rule and the auto-promote on summon.
- **Engagement-only auto-center (typing spans, dwell).** The timing is unpredictable and it needs
  keystroke observation. It may come back later as an opt-in setting for click-promote.
- **Moving windows live while browsing the pile.** That costs 2 real moves per step, right where the
  eyes rest. The hand panel moves nothing until you commit.
- **Draw by MRU number (⌃⌥⇧1–9).** The numbers change after every draw.
- **Picks go into the focused seat by default.** That is an invisible mode. ↩ always means C.
- **A fixed 350–600 ms click settle.** That can be shorter than the user's double-click setting. The
  settle uses `doubleClickInterval`.
- **Refilling a seat on hide or minimize.** That guarantees two windows in one seat when the window
  is restored.
- **Strip workspaces / tmux-style sessions** (`origin/multiplex-sessions-spike`, its proposed
  ADR-0005). Native Spaces cover separating unrelated work.

## Still open (lean recorded; revisit with evidence)

- **Slot affinity in pile order.** Lean: no. First log redraws across seats and look at the counts.
- **Keystroke guard:** hold the first key typed into a parked focused window, summon the window,
  then release the key. Lean: an experiment, off by default, because it touches the tap's swallow
  path.
- **Click-promote round-trip cost** (the posture designer's dissent): glancing at a reference
  window by clicking it costs 4 moves for the round trip. Mitigations: trades are self-inverse, and
  a lock opts a seat out. Acid hand test: copy a line from R into C.

## Experiments to run first (strip-e2e VM)

1. **Wrap sweep:** log intermediate frames of parked windows during slides with 4 and 6 windows.
   By code reading, slide-next with 4 windows springs the L window across C and R.
2. **Space-switch drop:** do a Space round trip and check the log for windows dropped and
   re-admitted. Also check that the VM supports multiple Spaces and that the CGS Space id is
   readable.
3. **Two-phase cut across two pids:** take a screencapture burst and look for a frame showing
   wallpaper. Then check for stale frames on reveal in Chrome, Electron and Xcode, which needs eyes
   on the host.
4. **Attribution:** check that ⌘Tab or `osascript activate` to a parked window delivers the focused
   window id, and that the posted ⌘-keyDown reaches the tap.
5. **Hide/minimize:** check that the window restores to its seat frame with 0 writes.
6. **flagsChanged in the tap mask:** commit on modifier release, and recover after a tap timeout.
7. **`kAXRaise` on a background app's window** (matters only for the Deal preset).

## Core architecture (slice 2 onward)

Strip evolves in place; only the stateful core is rewritten ([ADR-0006](../adr/0006-evolve-in-place-with-pure-event-driven-core.md)).
The platform layer (AX, observer, animator, hotkeys, overlay, search, tab scanner, thumbnails)
and the safety net (e2e VM suite, signing identity, signposts) are reused.

- **`StripCore` target: pure, no AppKit, no AX.**
  - Holds `Table`, `transitions()`, and one reducer:
    `reduce(state, event, now) -> (state, MovePlan, [SideEffect])`.
  - Time is an input, so every debounce, grace window and settle becomes a tested policy rather
    than a timer scattered through the controller. That covers the 75 ms reconcile, the 0.2 s
    self-activation grace, `doubleClickInterval`, the 250 ms ⌘Tab promote settle and the 120 ms parked
    coalesce.
  - `StripCore` must not import `StripKit`; `StripKit` depends on `StripCore`.
- **Typed events, one serial queue (main)** (as built in step 2; see *Step 2 as built*):
  - `windowsEnumerated(front to back, focused:)`, `tabReplaced`, `displayChanged`.
  - `focusChanged(id?, pid)`, `userInput(.mouseDown | .mouseUp | .scroll | .commandKey)`,
    `membershipHint(pid)`, `setting(.clickToCenter)`.
  - `chord(Command, repeated:)`, `dragEnded(id, wasResize, frame)`, `writeFailed(id)`.
  - `frameClamped(id, requested, actual)`, `tick`. `spaceChanged(SpaceKey)` comes with step 5.

  Every event is logged in a replayable form, so a recorded session from `/tmp/strip.log` becomes a
  unit test.
- **`MovePlan` is ordered phases, with a barrier between phases.**
  - Each phase lists `(id, target, kind: .spring | .cut | .snap)`.
  - A cut is two phases: place the incoming window, then park the outgoing one after the incoming
    window's pid queue confirms its write.
  - Motion budgets are asserted on the plan in unit tests.
- **The executor is what `StripController` shrinks to.**
  - It turns observer, hotkey and overlay inputs into events.
  - It runs plans through `WindowAnimator`, which learns phases and per-pid completion barriers.
  - It runs side effects: focus/activate, overlay snapshot, persist, enumerate. Enumeration stays
    main-thread and is requested by the reducer, not called ad hoc (ADR-0003).
- **Edge changes:**
  - The observer emits user/app attribution (from a recent ⌘-keyDown or mouseDown) and Space
    changes.
  - The animator gains phase barriers.
  - Nothing else in the platform layer changes contract.
- **Perf guard:** the reducer and plan sit on the hot path of every event. Add `reduce` and
  `planExecute` signposts in slice 2. Compare to the current `apply`/`animate` baseline before the
  slice 3 swap (MEASURING.md).

### Step 2 as built (deviations from the sketch above)

Step 2 (`seats-and-pile-core`, 2026-11-09) built the pure core. Where it departs from this doc:

- **`Table.hidden`.** A hidden or minimized window that owns no seat (a minimized pile card, or a
  hole whose seat a column change removed) moves to `hidden`. It is never drawn, picked or written;
  a restore summons it. Keeping such windows in the pile let a draw deal out a minimized window. The
  place invariant covers four places: `seats`, `pile`, `holes`, `hidden`.
- **Lifecycle events are one enumeration diff.** `windowCreated/Destroyed/Hidden/Minimized/Restored`
  are not events. The observer's notifications become `membershipHint(pid)`, the reducer debounces
  them (75 ms) into `SideEffect.enumerate`, and `windowsEnumerated` is diffed for new, closed, hidden
  and restored windows: the policy needs what only the snapshot has (the window macOS focused, sizes,
  visibility).
- **Attribution and committed clicks live in the reducer.** `focusChanged` carries the app's pid,
  not an attribution; the reducer attributes it from the last `userInput` (a mouseDown or ⌘ key
  within 1 s). There is no `committedClick` event: the reducer runs the click detector from
  mouseDown / mouseUp, with the hit-test done by the executor at mouseUp. A committed click is judged
  against the focus the reducer tracked, without a fresh focus read.
- **Extra events:** `tabReplaced`, `displayChanged`, `userInput`, `membershipHint`, `setting`.
  `writeFailed` carries no error.
- **Effects:** `focus`, `wake(at:)` (the executor keeps one timer), `render`, `persist`,
  `reseed` (a dragged window springs back from where it was dropped), `log` (`LogLine`, formatted
  with app names by the executor, same texts the e2e suite greps), `enumerate`, `queryFocus`, `pill`.
- **The presize phase.** `MovePlan` has up to three phases: *prepare* (invisible snaps: an incoming
  card pre-sized while still parked, parked cards changing edge or size), *show* (springs and cuts on
  screen), *clear* (the displaced card parks after its replacement is placed). Whether the presize
  earns its write is decided in step 3, with a measurement.
- **Pass skips empty seats.** Pass shifts only occupied, unlocked, hole-free seats. With one such
  seat (monocle), pass is a draw toggle until step 4's hand panel.
- **Focus timing choices:**
  - Focus into an unknown window arms the 75 ms re-scan instead of enumerating at once, so it
    coalesces with the window-created hint that usually comes with it. A focused window the reducer
    thinks is hidden re-scans too.
  - App-caused focus into a parked window moves it to the top of the pile (no write), so the pill's
    ⌃⌥I draws it.
  - A summon focuses its landing seat (R past a locked C), so nothing hands focus back to C.
  - Strip's own-activation grace (0.2 s) ends early if the user clicks or presses ⌘ after it.
  - Automatic promotes, summons and committed clicks skip while Strip's own hand-off is pending.
  - An app activation inside a pending hand-off still loses to it (owner decision 2026-11-09,
    BUGS.md); the reducer ignores the stale focus change, so its model agrees with the OS.
  - A Strip command cancels a pending committed click and ⌘Tab promote (as today's `handle` does).
- **Replay and signpost.** The executor logs `ST <json>` (display and settings) once, then
  `EV <t> <json>` per event; `Replay.run` replays a session from the log and checks every invariant
  after every step. `CoreDriver` (StripKit) wraps `reduce` in the `reduce` signpost; `planExecute`
  comes with the executor in step 3. Headless baseline: `reduce` p50 0.2 µs, p90 ≈ 21 µs, max
  ≤ 0.16 ms over 10k mixed events (release, M1 Pro).

**Full-rewrite tripwire:** reopen ADR-0006 only if slice 3 produces measured or captured evidence
that the animator or observer contract cannot support ordered, attributed, Space-aware moves without
being rebuilt. Scope any rewrite to that layer.

## Build order (each slice ships on its own, pure model first)

0. **Fixes on today's ring**, each with a log line and an e2e scenario:
   - A pure rule that snaps any move into a park when the move starts off-screen or on the opposite
     half of the screen.
   - focusFollow: a click on a managed window sets `focusSlot` and `lastFocusedId` with 0 motion.
     Today `handleExternalActivation` returns early for managed windows, so J/K go stale.
   - A user mouseDown or ⌘-keyDown cancels the pending focus work.
   - A user-caused activation of a parked window does a two-entry ring swap into C.
1. **Promote and draw on the ring:**
   - promote = `moveFocused` toward the anchor.
   - A committed-click detector in the `WindowObserver` mouse monitor, plus a pure `PromotePolicy`
     with injectable time.
   - An `mru` list; draw = a two-entry ring swap; chords ⌃⌥U / I / O and ↩.
   - Trade with a named seat (⌃⌥⇧U / I / O) as a two-entry ring swap; retire ⌃⌥⇧H / L.
2. **`StripCore`:** the `Table` model, the reducer, typed events, `MovePlan`/`transitions()`,
   motion-budget and invariant tests, a replay harness, and the `reduce` signpost (`make test` only;
   see *Core architecture*).
3. **Controller and animator:**
   - Shrink `StripController` to the event executor and swap in `StripCore`.
   - Add phase barriers to the animator.
   - A two-phase `.cut` in the animator, measured against slide per `MEASURING.md`.
   - The new/close/hole policy in `refresh()`.
   - Startup adoption by slot rect, then z-order.
4. **Hand panel** (flagsChanged) with seat retargeting, monocle H/L browsing, seat-targeted picks
   in Overview / search / rail drag, ⌃⌥Esc, bury (⌃⌥B), put away (⌃⌥⌫), and the Cut and Deal
   presets.
5. **Spaces:** the `[SpaceKey: Table]` map, freezing windows instead of dropping them, and
   suspending management in fullscreen Spaces and under Stage Manager. Must land before automatic
   promotes are enabled by default on a multi-Space setup.
6. **Chrome:**
   - The TABLE | PILE rail, the amber focus ring and the pill messages.
   - The Overview spread and the help overlay.
   - A "Draw into ▸" submenu in the status menu.

Every behavior slice gets an e2e scenario. Click feel, double-click safety and cut flicker on real
browsers are hand tests (TESTING.md §2).
