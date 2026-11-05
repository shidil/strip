# Changelog

Notable user-visible changes are recorded here. Public versions use semantic versioning once
releases begin. Until then, `Resources/Info.plist` identifies experimental snapshots only.

## [Unreleased]

### Added

- Window & tab search in the Overview (⌃⌥F, or `/` inside the Overview): type to filter windows and
  the tabs inside them (Firefox, Safari, Chrome, and native Terminal/Finder tabs), ↑↓ to preview a
  browser tab in its card, ↩ to go there. ⌘Tab / ⌘Space close the Overview.
- e2e coverage for search in the isolated Tart VM (`make e2e-vm`), including browser tab peek and
  native-tab picks; the VM re-signs each build so its permission grants survive rebuilds.
- Public onboarding, privacy, security, contribution, release, and architecture decision docs.
- Static project website (`site/`) with an animated walkthrough of the film-strip concept.
- Animated README banner (`docs/assets/strip-banner.svg`).
- Website and README: real screenshots (three-up strip, Overview, search with tab peek, keyboard
  help), a window & tab search section, a "Find anything" walkthrough scene, the complete shortcut
  list including Overview and search keys, features that were missing (drag handling, learned size
  limits, focus following), a roadmap and tab-search FAQ, and the signing step in Get started.
- `make screenshots`: recaptures those screenshots from a release build in the e2e VM
  (`scripts/screenshots/`), and `scripts/site/preview.sh` renders the site for a visual check.
- Seats & Pile design (`docs/design/seats-and-pile.md`), ADR-0005 (private Space identity) and
  ADR-0006 (evolve in place with a pure event-driven core); the roadmap replaces workspaces and the
  2-D film with Seats & Pile.

### Fixed

- Sliding no longer drags a window across the screen. The wrapping film could flip a parked window
  from one screen edge to the other (monocle, or 3-up with 4+ windows) or bring it in from the far
  side of its new slot (2-up), springing it through every slot in between; those moves now snap
  (`MotionPolicy.sweepsAcross`, e2e `scenario_no_park_sweep`).
- e2e fixture: windows are moved before being resized, so an app that reopens against the right
  screen edge (Console, left there by a previous run) still grows past the tileable size.

## [0.1.0] - Unreleased

- Initial experimental source release.
