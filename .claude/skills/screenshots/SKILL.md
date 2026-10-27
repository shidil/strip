---
name: screenshots
description: Recapture Strip's website and README screenshots (3-up strip, Overview, window & tab search with tab peek, keyboard help) from a RELEASE build in the strip-e2e Tart VM, check them by eye, and publish the web JPEGs. Use when a UI change makes the published screenshots stale, when adding a new shot, or when asked for fresh screenshots or marketing images. Never captures the host's live Strip.
---

# screenshots

`make screenshots` builds a release bundle, pushes it into the `strip-e2e` VM, re-signs it there,
stages a fixed desktop (Safari, Preview, Terminal, Chrome, Finder, with local pages as browser tabs),
drives Strip into each state and screencaptures it, then writes 2000px JPEGs to
`site/assets/img/screenshots/`. The website (`site/index.html`) and `README.md` both use those
files, so one run updates both.

## Run

```sh
make screenshots                              # every shot (~1.5 min)
make screenshots SHOTS="search help"          # a subset
scripts/screenshots/capture.sh --no-build --raw-only strip   # iterate on the scene: reuse the build, skip publishing
scripts/screenshots/publish.sh strip          # publish a raw capture you've checked
```

Shots: `strip` (hero, 3-up), `overview`, `search` (Chrome tab peeked), `search-peek` (Safari tab
peeked; not published by default), `help`. Raw full-resolution PNGs land in
`.build/screenshots/raw/`, and the run's Strip log in `.build/screenshots/strip.log`.

## Always look before publishing

Metrics can't tell a good shot from a broken one. Downscale each raw PNG and Read it:
`sips -Z 1400 .build/screenshots/raw/strip.png --out .build/screenshots/view/strip.png`. Check:
- **No system dialog** over the content (see below).
- **Overview cards show thumbnails**, not accent placeholders.
- **search** shows the "Tab preview" caption and the peeked page in Chrome's card.
- **The hero's windows fit**: grep the log for `constraint-learned` / `constraint-unsatisfiable`.

Then publish, and update the `alt` text in `site/index.html` and `README.md` if the content changed.

## Known traps (each cost a run)

- **"Strip is requesting to bypass the system private window picker…"**: macOS's recurring
  ScreenCaptureKit confirmation. It covers the middle of every Overview shot. Ask the user to click
  **Allow** in the VM window; don't click security prompts yourself.
- **Terminal needs Screen Recording in the guest** (scripts/e2e/vm/setup.sh step 7). Without it,
  `screencapture` writes nothing. A golden snapshot made before 2026-10-28 lacks this grant.
- **Never resize a window Strip already manages.** Strip reads the size back and learns it as the
  app's minimum width (a 60% resize became Terminal `min=905`). `scene.sh` stages and positions every
  window *before* launching Strip; the film order is the windows' left-to-right on-screen order.
- **Real minimum widths on the VM's 1512pt display:** Finder 501, Chrome 500, Safari 574, Preview 708.
  Only Terminal fits a narrow side slot, which is why Preview and Safari stay parked in the hero.
- **Typing never peeks a tab.** Peek follows ↑/↓ only, so the scene presses ↓ then ↑.
- **Parked windows can't be captured.** The scene opens the Overview once with each window on
  screen, to warm the thumbnail cache, before the real Overview shot.
- If the VM isn't running, ask the user to `tart run strip-e2e`. Don't capture on the host.

## Adding a shot

Add a `wants <name>` block to `scripts/screenshots/scene.sh`. Drive Strip with the e2e driver
(`send_hotkey`, `send_key`, `type_text`, `click_menu`), wait on a log line with `wait_for_line`
rather than a bare sleep where one exists, then call `shot <name>`. Add it to the default `SHOTS`
list, reference `assets/img/screenshots/<name>.jpg` from the page, and run
`make screenshots SHOTS=<name>`.
