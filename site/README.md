# Website

The public landing page for Strip: a static, dependency-free site (HTML, CSS, vanilla JS).
No build step.

```
site/
  index.html              all page content, including every walkthrough scene's text
  assets/css/site.css     design tokens (top of file), components, and the walkthrough stage
  assets/js/explainer.js  animated walkthrough stage + hero film (progressive enhancement)
  assets/img/             favicon.svg (source), og-image.png + apple-touch-icon.png (generated)
  robots.txt, sitemap.xml
```

The README banner lives at `docs/assets/strip-banner.svg`. It's a standalone animated SVG and is
also the source of the social card.

## Preview locally

```bash
python3 -m http.server --directory site 8000   # then open http://localhost:8000
```

Opening `index.html` directly from disk also works.

## Editing

- **Copy:** edit `index.html`. Every scene's text is plain HTML, so search engines and readers
  without JavaScript see all of it. With JavaScript on, the scenes become a player.
- **Walkthrough animation:** each `<li data-scene="…">` in `index.html` pairs with an entry in the
  `SCENES` table in `explainer.js`. That entry's `frame(phase)` describes what the stage shows at
  each step. To add a scene, add both the `<li>` and a matching `SCENES` entry.
- **Geometry:** the tile size and film step appear in both `explainer.js` (top constants) and the
  `.stage` rules in `site.css`. Change them together.
- **Colors:** use the tokens at the top of `site.css`. `data-tone="rose|mint|…"` sets an
  element's accent.
- **Motion:** autoplay is off and transitions are disabled under `prefers-reduced-motion`. The
  player pauses on hover, off-screen, and in background tabs.

## Images

`og-image.png` and `apple-touch-icon.png` are generated from the SVGs. Regenerate them after
editing the banner or the favicon (requires Google Chrome):

```bash
scripts/site/render-images.sh
```

## Deploying

The site assumes it's served at `https://shidil.github.io/strip/`. If the URL changes, update:

- the `canonical`, `og:url`, `og:image` and JSON-LD `url` in `index.html`
- `robots.txt`
- `sitemap.xml`

`.github/workflows/pages.yml` publishes `site/` (minus this README) to GitHub Pages on every push
to `main` that touches `site/`. It can also be run by hand from the Actions tab. One-time setup:
**Settings → Pages → Build and deployment → Source: GitHub Actions**.
