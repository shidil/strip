---
status: accepted
date: 2026-07-13
---

# Use Accessibility for Window Control

## Context and Problem Statement

Strip must control real macOS windows without disabling System Integrity Protection or installing a
privileged scripting addition. macOS has no other public general-purpose window-control API.

## Considered Options

1. **Accessibility API** — discover, observe, focus, move, and resize AX elements.
2. **SIP-dependent injection** — install deeper system modifications.
3. **Visual overlay only** — simulate a manager without controlling real windows.

## Decision Outcome

Chosen option: **Accessibility API**, because it controls real windows while preserving normal macOS
security configuration. Injection raises unacceptable installation and security risk; overlays do
not meet the product goal.

### Consequences

- Good, because Strip requires no SIP changes or privileged helper.
- Good, because movement and resizing use documented APIs.
- Bad, because users must grant powerful Accessibility permission.
- Bad, because application AX behavior and constraints vary.

## Scope

Discovery, observation, focus, movement, resizing, hotkeys, onboarding, and security documentation.

## Revisit When

- Apple provides a supported window-management API with equivalent capability.

## More Information

- [Privacy and Permissions](../../PRIVACY.md)
- [Architecture](../../ARCHITECTURE.md)
