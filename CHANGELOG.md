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

- Draw a window from the pile into a seat: ⌃⌥U / ⌃⌥I / ⌃⌥O put the next parked window into the
  left / center / right seat and park the one that was there, both instantly. Press again to swap
  back. In monocle, ⌃⌥I flips between your two most recent windows.
- Trade the focused window with a named seat: ⌃⌥⇧U / ⌃⌥⇧I / ⌃⌥⇧O. Focus goes with it. These replace
  ⌃⌥⇧H / ⌃⌥⇧L, which are retired.
- ⌃⌥↩ promotes the focused side window to the center; on the center it undoes the last trade.
- "Center on click or ⌘Tab" (status menu, off by default): clicking a side window, or ⌘Tab / a Dock
  click into one, moves it to the center. A double-click, a drag, a text selection or a scroll never
  does, and a pinned seat never moves. It stays off by default until Strip understands macOS Spaces.

### Fixed

- Sliding no longer drags a window across the screen. The wrapping film could flip a parked window
  from one screen edge to the other (monocle, or 3-up with 4+ windows) or bring it in from the far
  side of its new slot (2-up), springing it through every slot in between; those moves now snap
  (`MotionPolicy.sweepsAcross`, e2e `scenario_no_park_sweep`).
- Focus that arrives from outside Strip (a click, ⌘Tab, the Dock) into a visible side window is
  now followed: Strip's focused slot moves to it with no window motion, so ⌃⌥J/K continue from the
  window you're actually in instead of the stale one (e2e `scenario_focus_follow`).
- Clicking another window or pressing a ⌘ shortcut (⌘Tab, ⌘`) right after a slide or ⌃⌥J/K no
  longer gets overridden: Strip used to activate the newly centered window ~170 ms later and steal
  the focus back. The pending hand-off is now cancelled and Strip follows where focus really went
  (e2e `scenario_focus_handoff_cancel`).
- ⌘Tab (or a Dock or notification click) to a window that Strip had parked off-screen now brings
  it to the center, swapping it with the window that was there. Nothing else moves. Before, the
  app took the keyboard while its window stayed off-screen. An app that activates itself without
  your input leaves its parked window where it is (e2e `scenario_summon_parked`).
- e2e fixture: windows are moved before being resized, so an app that reopens against the right
  screen edge (Console, left there by a previous run) still grows past the tileable size.

## [0.1.0] - Unreleased

- Initial experimental source release.
