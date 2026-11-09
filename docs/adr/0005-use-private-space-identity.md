---
status: accepted
date: 2026-11-06
---

# Use Private Space Identity

## Context and Problem Statement

Strip delegates separating unrelated work to macOS native Spaces and keeps one `Table` (seats +
pile, see [Seats & Pile](../design/seats-and-pile.md)) per Space. To key that state, Strip must know
which Space is active. Public APIs only announce *that* the Space changed
(`NSWorkspace.activeSpaceDidChangeNotification`), not *which* Space is now active.

## Considered Options

1. **Read-only private CGS Space id** — read the active Space identifier; never assign windows to
   Spaces or move them through private API.
2. **Fingerprint heuristic** — identify a Space by the set of on-screen window ids after a change.
3. **One global strip** — ignore Spaces (today's behavior).

## Decision Outcome

Chosen option: **read-only private CGS Space id, with the fingerprint heuristic as a fallback**,
because a fingerprint is ambiguous for empty or shared Spaces and a global strip drops and re-admits
every window on a Space round trip. This follows the same policy as
[ADR-0002](0002-use-private-window-identity-bridge.md): private symbols for identity only.

### Consequences

- Good, because per-Space state survives Space switches without heuristics in the common case.
- Good, because the private call is read-only and never moves windows or changes Space membership.
- Bad, because it can break on future macOS versions; the fallback keeps Strip functional.
- Bad, because it is a second private symbol, reinforcing the no-App-Store constraint.

## Scope

Space detection, per-Space state, compatibility docs, and release policy.

## Revisit When

- Apple exposes a public active-Space identifier.
- The fallback proves sufficient in practice.

## More Information

- [Seats & Pile design](../design/seats-and-pile.md)
- Supersedes the direction of the unmerged, proposed ADR-0005 on `origin/multiplex-sessions-spike`
  (per-user window session server); Strip workspaces/sessions are dropped in favor of native Spaces.
