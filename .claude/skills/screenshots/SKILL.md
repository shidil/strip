---
name: screenshots
description: Recapture Strip's website and README screenshots (3-up hero, monocle, pinned, Overview, window & tab search with tab peek, keyboard help) from a RELEASE build in the strip-shots Tart VM (fixed 3440×1440 ultrawide), check them by eye, and publish the web JPEGs. Use when a UI change makes the published screenshots stale, when adding a new shot, or when asked for fresh screenshots or marketing images. Never captures the host's live Strip.
---

# screenshots

`make screenshots` builds a release bundle, pushes it into the `strip-shots` VM, re-signs it there,
stages a fixed desktop (Safari, Preview, Terminal, Chrome, Finder, with local pages as browser tabs),
drives Strip into each state and screencaptures it, then writes JPEGs to
`site/assets/img/screenshots/`. The website (`site/index.html`) and `README.md` both use those
files, so one run updates both.

## The VM

`strip-shots` is a clone of `strip-e2e` (same grants, same guest signing identity) with a **fixed
3440×1440pt display** — Strip's target ultrawide. `strip-e2e` refits its display to its window, so
shots taken there change size with the window. One-time setup (stop strip-e2e first for a clean copy):

```sh
tart clone strip-e2e strip-shots
tart set strip-shots --display 3440x1440pt --no-display-refit --random-mac
```

The user starts it in their own terminal: `tart run strip-shots`. A tool-driven `tart run` never
shows its window and the guest needs a real display. If it isn't running, ask; never capture on the
host.

## Run

```sh
make screenshots                              # every shot (~2 min)
make screenshots SHOTS="search help"          # a subset
SHOT_HEIGHT=0.80 make screenshots             # window height (0.05 steps; default 0.85)
scripts/screenshots/capture.sh --no-build --raw-only strip   # iterate on the scene: reuse the build, skip publishing
scripts/screenshots/publish.sh strip          # publish a raw capture you've checked
```

Shots: `strip` (hero, 3-up), `monocle`, `pinned` (Finder pinned right, the film rolled), `overview`,
`search` (Chrome tab peeked), `search-peek` (Safari tab peeked; not published by default), `help`.
Raw 6880×2880 PNGs land in `.build/screenshots/raw/`, and the run's Strip log in
`.build/screenshots/strip.log`.

`publish.sh` frames them two ways: layout shots (`strip`, `monocle`, `pinned`) keep the whole
ultrawide (2400×1004), because the width is the point; UI shots (`overview`, `search`, `help`) are a
centered 1600×900pt crop (2000×1125), because those panels keep their size on any display and would
be tiny in the full frame. If dimensions change, update the `width`/`height` attributes in
`site/index.html`.

## Always look before publishing

Metrics can't tell a good shot from a broken one. Downscale each raw PNG and Read it:
`sips -Z 1600 .build/screenshots/raw/strip.png --out .build/screenshots/view/strip.png`. Check:
- **No system dialog** over the content (see below).
- **Overview cards show thumbnails**, not accent placeholders.
- **search** shows the "Tab preview" caption and the peeked page in Chrome's card.
- **pinned**: the status pill reads "Hybrid" and Finder is still on the right.
- **The windows fit**: grep the log for `constraint-learned` / `constraint-unsatisfiable`.

Then publish, check the site with `scripts/site/preview.sh screenshots search features`, and update
the `alt` text in `site/index.html` and `README.md` if the content changed.

## Known traps (each cost a run)

- **"Strip is requesting to bypass the system private window picker…"**: macOS's recurring
  ScreenCaptureKit confirmation. It covers the middle of every Overview shot. Ask the user to click
  **Allow** in the VM window; don't click security prompts yourself.
- **Terminal needs Screen Recording in the guest** (scripts/e2e/vm/setup.sh step 7). Without it,
  `screencapture` writes nothing. A golden snapshot made before 2026-10-28 lacks this grant.
- **Never resize a window Strip already manages.** Strip reads the size back and learns it as the
  app's minimum width (a 60% resize became Terminal `min=905`). `scene.sh` stages and positions every
  window *before* launching Strip; the film order is the windows' left-to-right on-screen order.
- **Window height 0.85 is the ceiling.** Strip's default (1.0) puts the status pill over the windows'
  tab bars and the rail over their content; 0.90 lets the rail cover the bottom of the windows; 0.80
  leaves visibly empty bands. Windows are centered vertically, so each step moves both edges.
- **Small displays clip 3-up.** On a 1512pt-wide display the real minimum widths (Finder 501,
  Chrome 500, Safari 574, Preview 708) don't fit three slots, and a side window spills off screen.
  That's why the shots use the ultrawide VM.
- **Typing never peeks a tab.** Peek follows ↑/↓ only, so the scene presses ↓ then ↑.
- **Parked windows can't be captured.** The scene opens the Overview once with each window on
  screen, to warm the thumbnail cache, before the real Overview shot.

## Adding a shot

Add a `wants <name>` block to `scripts/screenshots/scene.sh`. Drive Strip with the e2e driver
(`send_hotkey`, `send_key`, `type_text`, `click_menu`), wait on a log line with `wait_for_line` /
`wait_for_cols` rather than a bare sleep where one exists, then call `shot <name>`. Add it to the
default `SHOTS` list and to `publish.sh`'s default names (pick its framing there), reference
`assets/img/screenshots/<name>.jpg` from the page, and run `make screenshots SHOTS=<name>`.
