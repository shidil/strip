---
status: accepted
date: 2026-07-13
---

# Use Stable Public Bundle Identity

## Context and Problem Statement

TCC permissions bind to a bundle identifier and signature. The spike identifier `com.spike.strip`
is not a durable maintainer namespace, and changing it after publication would reset user permissions.

## Considered Options

1. **`io.github.shidil.strip`** — use the maintainer's public namespace before release.
2. **Keep `com.spike.strip`** — retain a provisional identity.
3. **Delay the decision** — allow inconsistent public build identities.

## Decision Outcome

Chosen option: **`io.github.shidil.strip`**, because it is stable and attributable before public
users create TCC records. Keeping or delaying the spike identity creates avoidable migration cost.

### Consequences

- Good, because preferences, signing, docs, and TCC instructions share one identity.
- Bad, because existing development permissions and preferences under `com.spike.strip` reset once.

## Scope

Info.plist, signing, preferences, queue/signpost labels, tests, scripts, and documentation.

## Revisit When

- Project ownership moves to an organization with a different durable namespace.

## More Information

- [Development Signing](../DEVELOPMENT_SIGNING.md)
