---
status: accepted
date: 2026-11-06
---

# Evolve in Place with a Pure Event-Driven Core

## Context and Problem Statement

The [Seats & Pile](../design/seats-and-pile.md) design replaces the wrapping ring with seats and an
MRU pile, needs ordered cross-window moves (cuts), user-vs-app focus attribution, and per-Space
state. The question was whether to start a new project with a fresh architecture, optimized for
performance, reliability and glitch-freedom.

Evidence at decision time: 6,571 lines of Swift; ring concepts confined to `StripController`,
`StripState` and `StripLayout` (~1,340 lines, ~20%); the remaining platform layer encodes the
project's hard-won AX learnings (double `setSize`, Enhanced UI toggling, never-pruned per-pid queues,
main-thread enumeration, transient-miss resilience, clamp learning, write-failure tracking, drag
handshake). No measured performance bottleneck exists (`placements` p50 0.07 ms; `animate` max
1.17 ms after `33273ea`; perf backlog empty). Glitch risk concentrates in `StripController`'s
interacting timers and handshakes.

## Considered Options

1. **New project** — fresh repo and architecture.
2. **Evolve in place with a pure event-driven core** — rewrite only the stateful core as a new pure
   target; reuse the platform layer and safety net.
3. **Incremental edits to `StripController`** — no structural change.

## Decision Outcome

Chosen option: **evolve in place with a pure event-driven core**. A new `StripCore` target holds the
`Table`, a reducer `reduce(state, event, now) -> (state, MovePlan, [SideEffect])` with injected time,
typed events, and ordered `MovePlan`s. `StripController` shrinks to an executor. A new project would
re-buy the platform learnings (second-system risk), lose or duplicate the e2e/signing/measurement
safety net, reset TCC grants on a new bundle id (ADR-0004), and pause improvements to a daily-driver
WM — while justifying itself on performance with no measurement (contrary to MEASURE FIRST).
Incremental edits would leave the timing heuristics untestable.

### Consequences

- Good, because coordination and timing — where glitches originate — become pure, deterministic and
  replayable from logged events.
- Good, because the platform layer, e2e suite, signing identity and perf tooling carry over intact.
- Good, because slices 0–1 validate the design on today's ring before the core swap.
- Bad, because the reducer adds work to every event's hot path; it must be signposted and measured
  against the current baseline before the swap.
- Bad, because during migration two models coexist (ring for slices 0–1, `Table` from slice 3).

## Scope

`StripController`, `StripState`, `StripLayout`, the new `StripCore` target, animator phase barriers,
observer attribution and Space events.

## Revisit When

- Slice 3 produces measured or captured evidence that the animator or observer contract cannot
  support ordered, attributed, Space-aware moves without being rebuilt — then scope a rewrite to
  that layer.

## More Information

- [Seats & Pile design](../design/seats-and-pile.md)
- Related: [ADR-0003](0003-keep-ax-enumeration-on-main-thread.md),
  [ADR-0004](0004-use-stable-public-bundle-identity.md),
  [ADR-0005](0005-use-private-space-identity.md)
