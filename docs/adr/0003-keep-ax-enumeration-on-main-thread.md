---
status: accepted
date: 2026-07-13
---

# Keep AX Enumeration on Main Thread

## Context and Problem Statement

Measured experiments showed `kAXWindows` enumeration returns degraded data off-main. AX operations
on already-obtained elements can still run on per-process serial queues.

## Considered Options

1. **Main-thread enumeration with reduced frequency** — preserve correctness and avoid extra scans.
2. **Background enumeration** — move all AX work off-main.
3. **Continuous polling** — enumerate frequently and absorb the cost.

## Decision Outcome

Chosen option: **main-thread enumeration with reduced frequency**, because correctness is mandatory
and measurement showed off-main enumeration is unreliable. Frequency is the safe optimization lever.

### Consequences

- Good, because window snapshots remain complete and predictable.
- Good, because per-element animation writes still execute off-main.
- Bad, because enumeration remains a main-thread cost.
- Bad, because future changes require workload-specific measurement.

## Scope

Enumeration, reconciliation scheduling, animation queues, and performance work.

## Revisit When

- A macOS release makes off-main enumeration reliable.
- Measurement shows frequency control no longer meets latency goals.

## More Information

- [Performance Measurement](../../MEASURING.md)
