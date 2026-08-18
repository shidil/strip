# Spike 0001: Multiplexed Window Sessions

**Status:** Active  
**Started:** 2026-07-17  
**Branch:** `multiplex-sessions-spike`  
**Decision record:** [ADR-0005](../adr/0005-use-per-user-window-session-server.md)

## Question

Can Strip provide tmux-style named sessions with safe attach and detach semantics while keeping the
current Accessibility-only architecture, stable TCC identity, and recoverable window placement?

## Working Definition

- A **session** is a named collection of live macOS windows plus independent `StripState` and layout
  settings.
- **Attach** makes one session active on the current display and restores its windows to Strip slots.
- **Detach** persists the session state and parks its windows off-screen while their applications
  continue running.
- The display is the initial equivalent of a tmux client. A later `stripctl` process may command the
  same session manager.

## Hypotheses

1. Existing parking and reclaim behavior can hide inactive sessions without minimizing or hiding an
   entire application.
2. Session ownership can be modeled as pure state above `StripState` and tested without AppKit or AX.
3. Switching sessions can be an atomic controller operation: park old, bind new state, reconcile,
   apply, then focus.
4. A live window can belong to exactly one session, with new windows assigned to the attached
   session by default.
5. Persisting recovery frames before parking is sufficient to make a `rescue` operation safe after a
   failed attach or an agent restart.

## Spike Scope

### In Scope

- Pure `SessionID`, `WindowSession`, and `SessionManager` models.
- Two or more named in-memory sessions.
- Create, list, rename, attach, detach, and move-focused-window commands.
- One attached session on the active display.
- Independent center, ring, pins, layout, and last-focused state per session.
- Per-window ownership, including two windows from the same application in different sessions.
- Parking detached-session windows with the current animator/controller seams.
- Emergency `rescue` behavior that makes every session window visible again.
- Unit tests for state transitions and integration logging for live AX verification.
- A command protocol that can later back menu items, hotkeys, or `stripctl`; no IPC transport yet.

### Out of Scope

- Separate daemon, LaunchAgent, XPC service, or Unix-domain socket.
- Remote graphical attachment.
- Native macOS Space assignment.
- Concurrent attachment of one session to multiple displays.
- Surviving logout or reboot with application processes intact.
- Relaunching applications or reopening documents.
- Final configuration-file syntax and user-facing hotkey selection.
- Renaming Strip or changing `io.github.shidil.strip`.

## Proposed Model

```swift
struct WindowSession: Equatable {
    let id: SessionID
    var name: String
    var state: StripState
    var windowIDs: [CGWindowID]
    var lastFocusedWindowID: CGWindowID?
    var attachment: SessionAttachment
}

struct SessionManager {
    var sessions: [SessionID: WindowSession]
    var activeSessionID: SessionID?
}
```

The production model may use a dictionary plus an explicit order. The spike should optimize for
clear invariants, not persistence format or command-line ergonomics.

## Required Invariants

1. A live managed window belongs to at most one session.
2. At most one session is attached to the active display during the spike.
3. Attaching a session detaches the currently attached session first.
4. Detached windows remain tracked and recoverable even while parked.
5. Removing a dead AX window removes its membership without corrupting another session.
6. Moving a focused window between sessions preserves the source and destination ring invariants.
7. `rescue` never leaves a known live window parked.
8. Session switching never enumerates `kAXWindows` off the main thread.

## Experiments

### E1 — Pure Session State

Implement the session model and command transitions without AppKit. Prove create, rename, attach,
detach, move-window, window-loss, and rescue state with unit tests.

**Pass:** deterministic state transitions with no AX types beyond stable window identifiers.  
**Fail:** session semantics require live frame or observer state inside the model.

### E2 — Controller Binding

Refactor the minimum controller seam needed to bind the active `WindowSession` while keeping one
shared observer, animator, and overlay.

**Pass:** existing single-session tests remain green and an attached session uses the unchanged
layout/animation pipeline.  
**Fail:** each session requires its own observer or animator.

### E3 — Live Attach/Detach

Create two sessions containing windows from at least two applications, including two windows owned
by one application. Repeatedly attach and detach both sessions.

**Pass:** only the attached session is visible; applications remain running; focus and layout return
correctly; no windows are stranded.  
**Fail:** application-level hiding/minimizing is required or parking loses ownership.

### E4 — Failure and Rescue

Interrupt switching at each transition boundary and simulate a stale AX element.

**Pass:** `rescue` restores every live window to a visible display and dead windows are dropped.  
**Fail:** a crash can leave windows inaccessible without manual OS intervention.

### E5 — Command Boundary

Express every spike action through a small command enum and result type rather than direct menu or
hotkey callbacks.

**Pass:** a future `stripctl` or XPC client can invoke the same commands without importing AppKit.  
**Fail:** commands leak UI or AX implementation details.

## Validation

- `make test` remains green after every experiment.
- Add pure tests for all invariants and state transitions.
- Add targeted integration logging for session ID, command, window membership, and attachment state.
- Run `make e2e-vm` before accepting ADR-0005.
- Manually verify repeated attach/detach and rescue on a clean desktop.
- No performance change lands without measurement under `MEASURING.md`; the spike should initially
  measure switching rather than optimize it.

## Exit Criteria

The spike is complete when it produces evidence for one of these decisions:

1. **Accept ADR-0005:** in-process session server is safe and provides a stable future client seam.
2. **Revise ADR-0005:** session semantics work but require a per-user LaunchAgent/XPC boundary.
3. **Reject ADR-0005:** macOS window ownership or recovery makes attach/detach unsafe; retain simpler
   M8 workspace switching.

Record measured behavior, failed experiments, and the final decision in this document before
changing the ADR status.
