/**
 * Strip website: the animated "How it works" walkthrough and the hero's drifting film.
 *
 * Progressive enhancement: every scene's text is plain HTML in index.html (readable without
 * JavaScript and by crawlers). This script only adds the animated film-strip stage, scene
 * navigation, and autoplay.
 *
 * The stage is a logical canvas STAGE_HEIGHT units tall, scaled to fit its container. Inside it,
 * the film is a row of window tiles; each scene describes, per animation phase, which window is
 * focused, where the center gate sits, and which slots ("gates") are open. Tile/step sizes mirror
 * the `.stage` rules in site.css.
 */
(() => {
  'use strict';

  // Data ---------------------------------------------------------------------------------------

  const APPS = [
    { id: 'editor', label: 'Editor', glyph: 'E', accent: '#7aa2f7' },
    { id: 'terminal', label: 'Terminal', glyph: 'T', accent: '#41d18f' },
    { id: 'browser', label: 'Browser', glyph: 'B', accent: '#5b9dff' },
    { id: 'chat', label: 'Chat', glyph: 'C', accent: '#b58cf2' },
    { id: 'mail', label: 'Mail', glyph: '@', accent: '#f0a35e' },
    { id: 'music', label: 'Music', glyph: '♪', accent: '#ff7a90' },
    { id: 'calendar', label: 'Calendar', glyph: '#', accent: '#5fc9a0' },
  ];

  // Geometry, in stage units.
  const STAGE_HEIGHT = 320;
  const STAGE_MIN_WIDTH = 760; // narrowest logical width: three gates plus a little film either side
  const TILE_WIDTH = 210;
  const STEP = 228; // tile width + gap: one "frame" of film
  const GATE_WIDTH = TILE_WIDTH + 16;
  const DRIFT_OFFSET = 240; // how far off-center focus lands in the "problem" scene
  const VIEWPORT_WIDTH = 706;

  // Timing.
  const PHASE_MS = 2300;

  /** Gate layouts: each gate's offset from the stage center, in film steps. */
  const GATE_LAYOUTS = {
    mono: [{ offset: 0, kind: 'center' }],
    two: [{ offset: -0.5, kind: 'center' }, { offset: 0.5, kind: 'side' }],
    three: [{ offset: -1, kind: 'side' }, { offset: 0, kind: 'center' }, { offset: 1, kind: 'side' }],
    pin: [{ offset: -1, kind: 'side' }, { offset: 0, kind: 'center' }, { offset: 1, kind: 'pin' }],
  };
  const GATE_LABELS = { center: 'Center · fixed', side: 'Context', pin: 'Pinned' };
  const LAYOUT_NAMES = { mono: 'Monocle', two: 'Two‑up', three: 'Three‑up' };

  /** 0,1,…,max,…,1 — a sequence that rolls the film one way then back, looping cleanly. */
  function pingPong(min, max) {
    const seq = [];
    for (let i = min; i <= max; i++) seq.push(i);
    for (let i = max - 1; i > min; i--) seq.push(i);
    return seq;
  }
  const at = (seq, phase) => seq[phase % seq.length];

  /**
   * Scenes, keyed by the `data-scene` attribute in index.html. `phases` is how many animation
   * steps play before autoplay moves on; `frame(phase)` returns what the stage shows:
   *   focus       index (into `film`) of the focused window
   *   centerShift where the focused window sits, relative to the stage center (default 0)
   *   film        windows on the film, in order (default: all APPS)
   *   lit         film indices shown at full brightness (default: [focus])
   *   gates       a GATE_LAYOUTS key, or null for none
   *   pinned      id of a window held in the pin gate instead of on the film
   *   ringed      outline the focused window with its accent
   *   viewport    show the "your screen" frame
   *   keys        key caps to show; activeKey highlights one
   *   hint        text after the key caps; hintTone colors it
   */
  const SCENES = {
    problem: {
      phases: 4,
      frame(phase) {
        const drifted = phase % 2 === 0;
        return {
          focus: 2,
          centerShift: drifted ? -DRIFT_OFFSET : 0,
          ringed: true,
          viewport: true,
          keys: drifted ? [] : ['⌘', 'Center'],
          hint: drifted
            ? '← focus drifted off‑center — crane your neck'
            : 'manual re‑center — again',
          hintTone: drifted ? 'rose' : 'orange',
        };
      },
    },
    inversion: {
      phases: 6,
      frame(phase) {
        const focus = at(pingPong(0, 6), phase);
        return { focus, gates: 'mono', keys: ['H', 'L'], hint: 'roll the film' };
      },
    },
    context: {
      phases: 5,
      frame(phase) {
        const focus = at(pingPong(1, 5), phase);
        return {
          focus,
          lit: [focus - 1, focus, focus + 1],
          gates: 'three',
          keys: ['H', 'L'],
          hint: 'center stays sacred',
        };
      },
    },
    pin: {
      phases: 5,
      frame(phase) {
        const focus = at(pingPong(1, 5), phase);
        return {
          film: APPS.filter((app) => app.id !== 'terminal'),
          pinned: 'terminal',
          focus,
          lit: [focus - 1, focus],
          gates: 'pin',
          keys: ['P'],
          hint: 'pin / unpin the focused slot',
        };
      },
    },
    gates: {
      phases: 6,
      frame(phase) {
        const layout = at(['mono', 'two', 'three'], phase);
        const focus = layout === 'three' ? 3 : 2;
        const lit = { mono: [focus], two: [focus, focus + 1], three: [focus - 1, focus, focus + 1] }[layout];
        return {
          focus,
          // In two-up the left gate is the center (primary) slot.
          centerShift: layout === 'two' ? -STEP / 2 : 0,
          lit,
          gates: layout,
          keys: ['1', '2', '3'],
          activeKey: { mono: '1', two: '2', three: '3' }[layout],
          hint: `${LAYOUT_NAMES[layout]} · open more gates`,
        };
      },
    },
  };

  // DOM helpers --------------------------------------------------------------------------------

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /** Clone the window tile <template> for one app. */
  function createWindowTile(app) {
    const template = document.getElementById('window-tile-template');
    const tile = template.content.firstElementChild.cloneNode(true);
    tile.style.setProperty('--tile-accent', app.accent);
    tile.querySelector('.window-tile__title').textContent = app.label;
    tile.querySelector('.window-tile__glyph').textContent = app.glyph;
    return tile;
  }

  /** Opacity of a tile `distance` frames away from focus, when it isn't lit. */
  function dimmedOpacity(distance) {
    return [1, 0.5, 0.26, 0.12][distance] ?? 0.06;
  }

  // Stage --------------------------------------------------------------------------------------

  /** Owns the stage DOM and renders one frame at a time. */
  class Stage {
    constructor(container) {
      this.container = container;
      this.canvas = el('div', 'stage__canvas');
      this.film = el('div', 'film');
      this.film.append(el('div', 'film__sprockets film__sprockets--top'),
        el('div', 'film__sprockets film__sprockets--bottom'));

      this.tiles = new Map(APPS.map((app) => [app.id, createWindowTile(app)]));
      this.tiles.forEach((tile) => this.film.append(tile));

      // The pinned window lives outside the film so it doesn't roll with it.
      this.pinnedTiles = new Map(APPS.map((app) => {
        const tile = createWindowTile(app);
        tile.classList.add('is-pinned');
        tile.hidden = true;
        return [app.id, tile];
      }));

      this.gates = el('div', 'stage__gates');
      this.viewport = el('div', 'viewport-frame');
      this.viewport.append(el('span', 'viewport-frame__label', 'Viewport · your screen'));
      this.keys = el('div', 'stage__keys');

      this.canvas.append(
        this.film,
        ...this.pinnedTiles.values(),
        el('div', 'stage__fade stage__fade--left'),
        el('div', 'stage__fade stage__fade--right'),
        this.viewport,
        this.gates,
        this.keys,
      );
      container.append(this.canvas);

      this.width = STAGE_MIN_WIDTH;
      this.frame = null;
      new ResizeObserver(() => this.fit()).observe(container);
      this.fit();
    }

    get centerX() { return this.width / 2; }

    /** Scale the logical canvas to the container; wide containers get a wider canvas instead. */
    fit() {
      const available = this.container.clientWidth;
      if (!available) return;
      const scale = Math.min(1, available / STAGE_MIN_WIDTH);
      this.width = available / scale;
      this.container.style.setProperty('--stage-scale', scale);
      this.container.style.setProperty('--stage-width', `${this.width}px`);
      if (this.frame) this.renderInstantly(this.frame);
    }

    render(frame) {
      this.frame = frame;
      const film = frame.film ?? APPS;
      const lit = frame.lit ?? [frame.focus];
      const centerX = this.centerX;

      // Roll the film so the focused tile's center lands on the (possibly shifted) center.
      const anchorX = centerX + (frame.centerShift ?? 0);
      const offset = anchorX - (frame.focus * STEP + TILE_WIDTH / 2);
      this.film.style.transform = `translateX(${offset}px)`;

      this.tiles.forEach((tile, id) => {
        const index = film.findIndex((app) => app.id === id);
        tile.hidden = index === -1;
        if (index === -1) return;
        const distance = Math.abs(index - frame.focus);
        const isLit = lit.includes(index);
        tile.style.left = `${index * STEP}px`;
        tile.style.opacity = isLit ? 1 : dimmedOpacity(distance);
        tile.style.zIndex = isLit ? (index === frame.focus ? 32 : 22) : Math.max(2, 12 - distance);
        tile.classList.toggle('is-ringed', Boolean(frame.ringed) && index === frame.focus);
      });

      this.pinnedTiles.forEach((tile, id) => {
        tile.hidden = id !== frame.pinned;
        tile.style.left = `${centerX + STEP - TILE_WIDTH / 2}px`;
      });

      this.renderGates(frame.gates, centerX);

      this.viewport.hidden = !frame.viewport;
      this.viewport.style.left = `${centerX - VIEWPORT_WIDTH / 2}px`;

      this.renderKeys(frame);
    }

    /** Render without transitions (first paint, resizes), then re-enable them. */
    renderInstantly(frame) {
      this.container.classList.add('is-instant');
      this.render(frame);
      this.container.getBoundingClientRect(); // flush styles while transitions are off
      this.container.classList.remove('is-instant');
    }

    renderGates(layout, centerX) {
      this.gates.replaceChildren(...(GATE_LAYOUTS[layout] ?? []).map(({ offset, kind }) => {
        const gate = el('div', `gate gate--${kind}`);
        gate.style.left = `${centerX + offset * STEP - GATE_WIDTH / 2}px`;
        gate.append(el('span', 'gate__label', GATE_LABELS[kind]));
        return gate;
      }));
    }

    renderKeys({ keys = [], activeKey, hint, hintTone }) {
      const caps = keys.map((key) => {
        const cap = el('span', 'stage__key', key);
        cap.classList.toggle('is-active', key === activeKey);
        return cap;
      });
      const hintNode = el('span', 'stage__hint', hint ?? '');
      if (hintTone) hintNode.dataset.tone = hintTone;
      this.keys.replaceChildren(...caps, hintNode);
    }
  }

  // Player -------------------------------------------------------------------------------------

  /** Scene navigation, autoplay, and keyboard/pointer controls around a Stage. */
  class Explainer {
    constructor(root) {
      this.player = root.querySelector('.explainer__player');
      this.sceneList = root.querySelector('[data-scenes]');
      this.counter = root.querySelector('[data-counter]');
      this.playButton = root.querySelector('[data-action="play"]');
      this.scenes = [...root.querySelectorAll('[data-scene]')]
        .map((node) => ({ node, id: node.dataset.scene, ...SCENES[node.dataset.scene] }))
        .filter((scene) => {
          if (!scene.frame) console.warn(`explainer: no animation for scene "${scene.id}"`);
          return Boolean(scene.frame);
        });
      if (!this.scenes.length) return;

      this.stage = new Stage(root.querySelector('[data-stage]'));
      this.dots = this.createDots(root.querySelector('[data-dots]'));

      this.index = 0;
      this.phase = 0;
      this.timer = null;
      // Autoplay runs only while all of these hold.
      this.playing = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      this.hovered = false;
      this.inView = false;

      this.bindEvents(root);
      this.show(0);
      this.stage.renderInstantly(this.stage.frame);
    }

    createDots(container) {
      return this.scenes.map((scene, i) => {
        const title = scene.node.querySelector('.pill')?.textContent.trim() ?? scene.id;
        const dot = el('button', 'player-controls__dot');
        dot.type = 'button';
        dot.setAttribute('aria-label', `Scene ${i + 1} of ${this.scenes.length}: ${title}`);
        dot.addEventListener('click', () => this.goTo(i));
        container.append(dot);
        return dot;
      });
    }

    bindEvents(root) {
      root.querySelector('[data-action="prev"]').addEventListener('click', () => this.goTo(this.index - 1));
      root.querySelector('[data-action="next"]').addEventListener('click', () => this.goTo(this.index + 1));
      this.playButton.addEventListener('click', () => this.setPlaying(!this.playing));
      this.stage.container.addEventListener('click', () => this.goTo(this.index + 1));

      this.player.addEventListener('keydown', (event) => {
        if (event.target !== this.player) return; // let buttons handle their own keys
        const moves = { ArrowLeft: this.index - 1, ArrowRight: this.index + 1, Home: 0, End: this.scenes.length - 1 };
        if (event.key in moves) {
          event.preventDefault();
          this.goTo(moves[event.key]);
        } else if (event.key === ' ') {
          event.preventDefault();
          this.setPlaying(!this.playing);
        }
      });

      // Pause while the reader is pointing at or tabbing through the player.
      this.player.addEventListener('pointerenter', () => { this.hovered = true; this.sync(); });
      this.player.addEventListener('pointerleave', () => { this.hovered = false; this.sync(); });

      new IntersectionObserver(([entry]) => {
        this.inView = entry.isIntersecting;
        this.sync();
      }, { threshold: 0.35 }).observe(this.player);
      document.addEventListener('visibilitychange', () => this.sync());
    }

    /** Navigate on user request: wrap around, and announce the new scene to screen readers. */
    goTo(index) {
      this.sceneList.setAttribute('aria-live', 'polite');
      this.show((index + this.scenes.length) % this.scenes.length);
      this.restartTimer();
    }

    show(index) {
      this.index = index;
      this.phase = 0;
      const scene = this.scenes[index];
      this.scenes.forEach((s, i) => s.node.classList.toggle('is-active', i === index));
      this.dots.forEach((dot, i) => {
        if (i === index) dot.setAttribute('aria-current', 'step');
        else dot.removeAttribute('aria-current');
      });
      this.player.dataset.tone = scene.node.dataset.tone ?? 'blue';
      this.counter.textContent = `${index + 1} / ${this.scenes.length}`;
      this.renderPhase();
    }

    renderPhase() {
      this.stage.render(this.scenes[this.index].frame(this.phase));
    }

    tick() {
      this.phase += 1;
      if (this.phase >= this.scenes[this.index].phases) {
        this.sceneList.setAttribute('aria-live', 'off'); // don't narrate autoplay
        this.show((this.index + 1) % this.scenes.length);
      } else {
        this.renderPhase();
      }
    }

    setPlaying(playing) {
      this.playing = playing;
      this.playButton.textContent = playing ? 'Pause' : 'Play';
      this.playButton.setAttribute('aria-pressed', String(playing));
      this.sync();
    }

    /** Start or stop the timer to match the current play/hover/visibility state. */
    sync() {
      const shouldRun = this.playing && !this.hovered && this.inView && !document.hidden;
      if (shouldRun && !this.timer) this.timer = setInterval(() => this.tick(), PHASE_MS);
      if (!shouldRun && this.timer) {
        clearInterval(this.timer);
        this.timer = null;
      }
    }

    restartTimer() {
      if (this.timer) {
        clearInterval(this.timer);
        this.timer = null;
      }
      this.sync();
    }
  }

  // Hero ---------------------------------------------------------------------------------------

  /** Fill the hero's decorative film. Two identical runs make the CSS -50% loop seamless. */
  function renderHeroDrift(container) {
    const track = el('div', 'hero__drift-track');
    [...APPS, ...APPS].forEach((app) => track.append(createWindowTile(app)));
    container.append(track);
  }

  // Boot ---------------------------------------------------------------------------------------

  document.querySelectorAll('[data-drift]').forEach(renderHeroDrift);
  document.querySelectorAll('[data-explainer]').forEach((root) => new Explainer(root));
})();
