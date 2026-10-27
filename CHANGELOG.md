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

## [0.1.0] - Unreleased

- Initial experimental source release.
