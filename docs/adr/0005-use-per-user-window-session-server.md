---
status: proposed
date: 2026-07-17
---

# Use Per-User Window Session Server

## Context and Problem Statement

M8 introduces multiple independent strips. A tmux-style model would also let users name those
window sets, detach them from a display, and attach them later while the owning applications keep
running. macOS application windows remain owned by their application processes, so Strip can
persist membership, layout, and visibility but cannot own or preserve GUI processes like tmux owns
pseudo-terminals. The process boundary must also preserve Strip's stable Accessibility/TCC identity.

## Considered Options

1. **Session manager inside `Strip.app`** — keep Accessibility, observation, animation, menu UI, and
   session ownership in the existing long-running agent; add a command interface after semantics are
   proven.
2. **Separate per-user LaunchAgent immediately** — move session ownership into a dedicated server and
   connect the menu app and CLI over XPC from the first implementation.
3. **Workspace switching without a server model** — keep N `StripState` values but expose no named
   sessions, attach/detach lifecycle, command protocol, or independent client concept.
4. **Map sessions onto native macOS Spaces** — delegate visibility and attachment to system Spaces
   rather than Strip's existing per-window parking mechanism.

## Decision Outcome

Proposed option: **session manager inside `Strip.app` for the spike**, because Strip is already a
long-running per-user agent with the required Accessibility identity and proven window parking. A
separate LaunchAgent is premature until session ownership, recovery, and command semantics are
validated. Workspace-only switching does not test the tmux-style lifecycle, and native Spaces do not
fit the project's public-Accessibility-only boundary.

The spike will determine whether this proposal should be accepted, revised toward a separate server,
or rejected.

### Consequences

- Good, because the spike reuses the existing TCC identity, observer, animator, and recovery paths.
- Good, because session logic can be extracted as pure `StripKit` state and tested headlessly.
- Good, because a future CLI or XPC boundary can be designed against proven commands rather than
  guessed requirements.
- Bad, because the first spike does not prove independent server and menu-process lifetimes.
- Bad, because detached GUI sessions survive client exit but cannot preserve application processes
  across logout or reboot; later restoration must reconstruct windows.
- Bad, because parking windows makes crash recovery and an emergency rescue command mandatory.

## Scope

M8 workspace/session state, `StripController`, window membership, parking and rescue behavior,
future command protocol boundaries, persistence guarantees, and per-user process ownership.

## Revisit When

- The spike completes its attach/detach and rescue acceptance gates.
- A CLI must continue after the menu application exits.
- Multiple displays need concurrent session attachment.
- Durable relaunch and document restoration requirements are defined.

## More Information

- [Multiplex sessions spike](../spikes/0001-multiplex-sessions.md)
- [M8 roadmap](../../PLAN.md)
- Related: [ADR-0001](0001-use-accessibility-for-window-control.md)
- Related: [ADR-0002](0002-use-private-window-identity-bridge.md)
- Related: [ADR-0004](0004-use-stable-public-bundle-identity.md)
