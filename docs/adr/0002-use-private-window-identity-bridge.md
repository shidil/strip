---
status: accepted
date: 2026-07-13
---

# Use Private Window Identity Bridge

## Context and Problem Statement

Strip needs an identity shared by Accessibility and ScreenCaptureKit. Public AX APIs do not expose
`CGWindowID`, while ScreenCaptureKit uses it.

## Considered Options

1. **`_AXUIElementGetWindow` bridge** — use the private symbol only for identity.
2. **Heuristic identity** — match by process, title, and geometry.
3. **Drop identity-dependent features** — remove reliable reconciliation and thumbnails.

## Decision Outcome

Chosen option: **`_AXUIElementGetWindow` bridge**, because it provides stable identity with a small,
isolated compatibility surface. Heuristics are ambiguous; dropping identity breaks lifecycle
correctness.

### Consequences

- Good, because AX, Core Graphics, and ScreenCaptureKit share one identifier.
- Good, because the private symbol never moves or resizes windows.
- Bad, because it can break on future macOS versions.
- Bad, because private API use prevents Mac App Store distribution.

## Scope

Window identity, reconciliation, thumbnails, compatibility docs, and release policy.

## Revisit When

- Apple exposes a public AX-to-window identifier.
- The project targets Mac App Store distribution.

## More Information

- [Privacy and Permissions](../../PRIVACY.md)
