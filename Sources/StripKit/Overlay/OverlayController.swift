import AppKit
import SwiftUI

/// Hosts Strip's always-on-top overlay chrome — the milestone that makes Strip *look* like the
/// prototype. M4 renders three pieces, each in its own borderless, **non-activating** panel so the
/// chrome floats over the managed windows without stealing their keyboard focus:
///   • **film rail** (bottom-center) — chip per window; white outline = focused, gold dot = pinned.
///   • **status pill** (top-center) — active app · layout · mode · transition · clock.
///   • **help overlay** (⌃⌥/) — a dimmed modal keyboard cheat-sheet.
///
/// Clicking a rail chip centers that window (`onCenter`).
public final class OverlayController {
    private let railPanel: NSPanel
    private let railHosting: NSHostingView<RailHost>
    private let statusPanel: NSPanel
    private let statusHosting: NSHostingView<StatusHost>
    /// Stable backing store for the two hosted SwiftUI views — set once, mutated per render so SwiftUI
    /// updates incrementally instead of rebuilding the tree (the render-cost fix).
    private let model = OverlayModel(rail: [], status: .empty)
    /// Last rail geometry inputs, so we only re-fit/reposition the rail panel when they actually change
    /// (a slide keeps the count constant → the panel frame is untouched, the highlight moves inside it).
    private var lastRailCount = -1
    private weak var lastRailScreen: NSScreen?
    private var lastRailEdge: RailEdge?
    /// The status panel is fixed-geometry (full visible width, fixed height) so the pill never forces a
    /// synchronous layout on a slide — it's only (re)positioned when the display changes.
    private weak var lastStatusScreen: NSScreen?
    /// Height of the full-width transparent strip the status pill is centered within (tall enough to
    /// not clip the pill's drop shadow). The extra space is click-through (`ignoresMouseEvents`).
    private static let statusStripHeight: CGFloat = 70
    private let focusRingPanel: NSPanel
    private var helpPanel: NSPanel?
    private var overviewPanel: NSPanel?
    private var lastScreen: NSScreen?
    /// Latest snapshot, so the overview (opened on demand) can render a card per ring window.
    private var lastSnapshot: OverlaySnapshot?
    /// Accent of the focused window, captured from the latest snapshot so the per-tick ring updates
    /// (which carry only a frame) can tint the border without re-deriving it.
    private var focusAccent: NSColor = .white

    /// Live window thumbnails for the overview cards. A single shared instance so the SwiftUI
    /// `@ObservedObject` identity stays stable across re-renders while the overview is open. Also
    /// backs the rail hover preview (below), which passes `evictOthers: false` so it doesn't wipe
    /// Overview's cached images.
    private let thumbnails = ThumbnailStore()
    /// Whether we've already asked for Screen Recording this process (prompt at most once).
    private var didRequestScreenRecording = false

    /// The hover-preview panel (lazily created), the chip currently hovered, and the debounce work
    /// item that fires the actual capture + panel show after a settle delay.
    private var previewPanel: NSPanel?
    private var hoveredId: CGWindowID?
    private var hoverWork: DispatchWorkItem?
    private static let previewSettleDelay: TimeInterval = 0.3
    private static let previewThumbSize = CGSize(width: 220, height: 140)
    private static let previewGap: CGFloat = 10

    /// Behind-window blur radius for the overview backdrop. Light enough that the windows behind stay
    /// recognizable (NSVisualEffectView is effectively ~30–50); tune here for more/less blur.
    private static let overviewBlurRadius = 22

    /// Max point size of a card's content (thumbnail) region used to bound capture resolution. Height
    /// is the shared card body height (156); width covers the widest card (body height × max aspect ≈
    /// 2.2) so wide windows capture crisply. The capture itself is sized to each window's own aspect
    /// within this box (see `WindowThumbnailer`).
    private static let cardThumbSize = CGSize(width: 688, height: 312)

    /// How far the ring sits outside the window's frame, and its corner radius.
    private static let ringInset: CGFloat = 2
    private static let ringWidth: CGFloat = 3
    private static let ringRadius: CGFloat = 11

    /// Invoked with the window id when a rail chip is clicked.
    public var onCenter: ((CGWindowID) -> Void)?

    /// Fired with `true` when the overview opens and `false` when it closes, so the hotkey tap can
    /// gate its chordless navigation keys to exactly the window the overview is showing.
    public var onOverviewVisibility: ((Bool) -> Void)?

    /// Keyboard-selection state for the overview. Lives here (not as SwiftUI `@State`) because
    /// `renderOverview` rebuilds the hosting view on every snapshot, which would reset view state.
    private let overviewSelection = OverviewSelection()

    /// Spotlight-style search inside the Overview (⌃⌥F, or `/` while it's open): query, ranked window
    /// + tab hits, and the AX tab scan that feeds it.
    private let search = SearchModel()
    private let tabScanner = TabScanner()
    /// How the current search session was opened and whether it ended in a pick — logged (counts and
    /// ranks only, never query text or titles) so prototype feedback has numbers behind it.
    private var searchOpenedVia = ""
    private var searchPicked = false
    /// Bumped per search session so a scan still running from an earlier session can't write its
    /// (possibly stale) tabs or clear the `scanning` flag of the current one.
    private var scanGeneration = 0

    /// Resolves a ring window's AX element, for the search's tab scan. Set by `AppDelegate`.
    public var windowLookup: ((CGWindowID) -> AXWindow?)?

    /// Switch to a tab (run the press) and center its window. Set by `AppDelegate`
    /// (`StripController.centerTab`, which orders the press on the app's AX queue).
    public var onCenterTab: ((CGWindowID, @escaping () -> Void) -> Void)?

    /// Switch to an AppKit native tab and center the window it shows (a different window id). Set by
    /// `AppDelegate` (`StripController.centerNativeTab`).
    public var onCenterNativeTab: ((CGWindowID, @escaping () -> ShownTabWindow?) -> Void)?

    /// Defer `work` until window `id`'s app isn't mid-motion (Enhanced UI suppressed hides tab bars from
    /// AX). Set by `AppDelegate` (`StripController.whenAXSettled`).
    public var whenAXSettled: ((CGWindowID, @escaping () -> Void) -> Void)?

    /// Run a tab press without moving windows (tab peek). Set by `AppDelegate` (`StripController.pressTab`).
    public var onPressTab: ((CGWindowID, @escaping () -> Void) -> Void)?

    /// Tab peek: while ↑↓ rests on a tab result, the real tab is switched and its window re-captured
    /// so the card previews it; peeked windows go back to their original tab when the selection moves
    /// on or search ends without picking them. `peekShown` = window → tab index a peek left showing.
    private var peekShown: [CGWindowID: Int] = [:]
    private var peekWork: DispatchWorkItem?
    private var peekCount = 0
    /// Pause on a result before peeking, so scrolling fast through results doesn't flip tabs.
    private static let peekSettleDelay: TimeInterval = 0.12
    /// Re-captures after a peek press: most warm tabs paint within ~40–80 ms (measured); the second
    /// catches slower ones.
    private static let peekCaptureDelays: [TimeInterval] = [0.09, 0.3]
    /// Longest a tab scan waits for an app's motion to finish (Enhanced UI back on) before scanning
    /// anyway. A normal re-center settles well inside this.
    private static let scanSettleTimeout: TimeInterval = 1.5

    /// Fired with `true`/`false` as the search field starts/stops taking input, so the hotkey tap
    /// routes plain keys as text exactly while it is.
    public var onSearchActive: ((Bool) -> Void)?

    public init() {
        // Stable roots: set once, then drive incremental updates by mutating `model` (perf: overlay
        // render). The rail's onTap reads `self?.onCenter` dynamically, so it stays correct even though
        // `onCenter` is assigned later by AppDelegate.
        let model = self.model
        railHosting = NSHostingView(rootView: RailHost(model: model, onTap: { _ in }, onOverview: {},
                                                        onHoverChange: { _, _ in }))
        statusHosting = NSHostingView(rootView: StatusHost(model: model))
        railPanel = Self.makePanel(level: .statusBar)
        statusPanel = Self.makePanel(level: .statusBar)
        // The ring sits at `.floating` (above managed app windows, level 0) but BELOW system UI like
        // notification banners — at `.statusBar` it painted over notifications (BUGS.md #3).
        focusRingPanel = Self.makePanel(level: .floating)
        railPanel.contentView = railHosting
        statusPanel.contentView = statusHosting
        // The status pill is display-only; its wide fixed panel must not eat clicks meant for windows.
        statusPanel.ignoresMouseEvents = true

        // The ring is a non-interactive layer border that frames the focused window.
        focusRingPanel.ignoresMouseEvents = true
        let ringView = NSView()
        ringView.wantsLayer = true
        ringView.layer?.borderWidth = Self.ringWidth
        ringView.layer?.cornerRadius = Self.ringRadius
        ringView.layer?.borderColor = NSColor.white.cgColor
        focusRingPanel.contentView = ringView

        // Now that all stored properties exist, install the real tap handler once (reads onCenter live).
        railHosting.rootView = RailHost(model: model, onTap: { [weak self] id in self?.onCenter?(id) },
                                         onOverview: { [weak self] in self?.toggleOverview() },
                                         onHoverChange: { [weak self] id, hovering in
                                             self?.handleChipHover(id, hovering: hovering)
                                         })
    }

    /// Latest snapshot awaiting render, and whether a coalesced render is already queued. Re-rendering
    /// the rail rebuilds two `NSHostingView` rootViews and forces synchronous layout twice — ~5–8ms on
    /// the main thread — and the rail's active chip moves on every slide step, so an unthrottled render
    /// per `apply()` is the residual hitch under a fast/held slide. We throttle to ~display rate with a
    /// leading + trailing edge: render immediately if idle, else coalesce into one trailing render that
    /// carries the *latest* snapshot, so the final state is always correct but intermediates drop.
    private var pendingSnapshot: OverlaySnapshot?
    private var renderScheduled = false
    private var lastRenderAt = Date.distantPast
    private static let minRenderInterval: TimeInterval = 1.0 / 60.0

    /// Re-render the rail + status pill for the latest state and reposition them on the active display.
    public func update(_ snapshot: OverlaySnapshot) {
        onMain {
            self.pendingSnapshot = snapshot
            // Keep an open overview perfectly in sync with the live ring (cheap; not throttled).
            if let panel = self.overviewPanel { self.renderOverview(into: panel, snapshot) }
            guard !self.renderScheduled else { return } // a trailing render will pick up this snapshot
            let since = Date().timeIntervalSince(self.lastRenderAt)
            if since >= Self.minRenderInterval {
                self.renderNow()
            } else {
                self.renderScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minRenderInterval - since)) {
                    [weak self] in
                    self?.renderScheduled = false
                    self?.renderNow()
                }
            }
        }
    }

    /// Render the latest pending snapshot now (must be on the main thread). The expensive rail/status
    /// rebuild lives here so `update(_:)` can throttle how often it runs.
    private func renderNow() {
        guard let snapshot = pendingSnapshot else { return }
        let sp = Signpost.log
        let renderState = sp.beginInterval("overlayRender")
        defer { sp.endInterval("overlayRender", renderState) }
        lastRenderAt = Date()
        lastScreen = snapshot.screen
        lastSnapshot = snapshot
        focusAccent = snapshot.activeAccent ?? .white
        focusRingPanel.contentView?.layer?.borderColor = focusAccent.cgColor
        let vis = snapshot.screen.visibleFrame

        // Incremental updates: mutate the model only when its content actually changed, so SwiftUI
        // diffs a few chips / strings instead of rebuilding the tree (perf: overlay render).
        if model.rail != snapshot.rail { model.rail = snapshot.rail }
        let status = StatusFields(snapshot)
        if model.status != status { model.status = status }
        if model.railEdge != snapshot.railEdge { model.railEdge = snapshot.railEdge }

        // The rail is center-anchored and constant-width during a slide, so only re-fit + reposition
        // it when the chip count, display, or edge changed; otherwise the moving highlight repaints
        // in place.
        if railNeedsRefit(oldCount: lastRailCount, newCount: snapshot.rail.count)
            || lastRailScreen !== snapshot.screen || lastRailEdge != snapshot.railEdge {
            let railSize = fit(railHosting, in: railPanel)
            railPanel.setFrameOrigin(railOrigin(for: snapshot.railEdge, size: railSize, in: vis))
            lastRailCount = snapshot.rail.count
            lastRailScreen = snapshot.screen
            lastRailEdge = snapshot.railEdge
        }
        show(railPanel)

        // The pill lives in a fixed full-width strip at the top and centers itself inside (StatusHost),
        // so a changing app-name width no longer forces a synchronous layout here — we only place the
        // panel when the display changes. SwiftUI re-centers the pill on its own async pass.
        if lastStatusScreen !== snapshot.screen {
            statusPanel.setFrame(NSRect(x: vis.minX, y: vis.maxY - Self.statusStripHeight,
                                        width: vis.width, height: Self.statusStripHeight), display: false)
            lastStatusScreen = snapshot.screen
        }
        show(statusPanel)
    }

    /// The rail panel's origin for a given screen edge, within the display's visible frame. `.top`
    /// offsets below the status pill's strip so the two never overlap; `.left`/`.right` center the
    /// (now-vertical, see `FilmRailView`) rail on the cross-axis instead of the horizontal midpoint.
    private func railOrigin(for edge: RailEdge, size: NSSize, in vis: NSRect) -> NSPoint {
        switch edge {
        case .bottom: return NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 16)
        case .top:    return NSPoint(x: vis.midX - size.width / 2,
                                      y: vis.maxY - Self.statusStripHeight - 16 - size.height)
        case .left:   return NSPoint(x: vis.minX + 16, y: vis.midY - size.height / 2)
        case .right:  return NSPoint(x: vis.maxX - 16 - size.width, y: vis.midY - size.height / 2)
        }
    }

    /// Hover a rail chip → after a short settle delay, capture and show a live thumbnail preview
    /// adjacent to the whole rail (not positioned per-chip — see `RailPreviewView`'s doc comment).
    /// Hover-away cancels any pending capture and hides the preview.
    private func handleChipHover(_ id: CGWindowID, hovering: Bool) {
        hoverWork?.cancel()
        guard hovering else {
            if hoveredId == id {
                hoveredId = nil
                previewPanel?.orderOut(nil)
            }
            return
        }
        hoveredId = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredId == id,
                  let item = self.lastSnapshot?.rail.first(where: { $0.id == id }) else { return }
            self.thumbnails.refresh(ids: [id], pointSize: Self.previewThumbSize, evictOthers: false)
            self.showPreview(for: item)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewSettleDelay, execute: work)
    }

    /// (Re)build and position the hover-preview panel, adjacent to the rail on the screen-interior
    /// side of whichever edge it's anchored to — generalizing "centered above the rail" to any
    /// `RailEdge` so the preview works the same regardless of where the user moved the minimap.
    private func showPreview(for item: RailItem) {
        let panel = previewPanel ?? Self.makePanel(level: .popUpMenu)
        let hosting = NSHostingView(rootView: RailPreviewView(item: item, thumbnails: thumbnails))
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        let rail = railPanel.frame
        let origin: NSPoint
        switch lastRailEdge ?? .default {
        case .bottom: origin = NSPoint(x: rail.midX - size.width / 2, y: rail.maxY + Self.previewGap)
        case .top:    origin = NSPoint(x: rail.midX - size.width / 2, y: rail.minY - Self.previewGap - size.height)
        case .left:   origin = NSPoint(x: rail.maxX + Self.previewGap, y: rail.midY - size.height / 2)
        case .right:  origin = NSPoint(x: rail.minX - Self.previewGap - size.width, y: rail.midY - size.height / 2)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        previewPanel = panel
    }

    /// Reposition the focus ring around the focused window's live frame (Quartz global), or hide it
    /// when `quartzFrame` is `nil`. Driven from the animator's per-tick callback so it tracks motion.
    public func updateFocusRing(_ quartzFrame: CGRect?) {
        onMain {
            guard let q = quartzFrame else { self.focusRingPanel.orderOut(nil); return }
            let cocoa = Coordinates.toCocoa(q).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
            self.focusRingPanel.setFrame(cocoa, display: true)
            if !self.focusRingPanel.isVisible { self.focusRingPanel.orderFrontRegardless() }
        }
    }

    /// Show/hide the keyboard cheat-sheet (⌃⌥/). Covers the active display with a dimmed modal that
    /// closes on click or another toggle.
    public func toggleHelp() {
        onMain {
            if let panel = self.helpPanel {
                panel.orderOut(nil)
                self.helpPanel = nil
                return
            }
            guard let screen = self.lastScreen ?? NSScreen.main else { return }
            let panel = Self.makePanel(level: .popUpMenu)
            let hosting = NSHostingView(rootView: AnyView(
                HelpOverlayView { [weak self] in self?.toggleHelp() }
            ))
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            self.helpPanel = panel
        }
    }

    /// Show/hide the overview (⌃⌥Space): a dimmed full-screen grid with a card per ring window.
    /// Clicking a card centers that window (`onCenter`) and dismisses. No-op until a snapshot exists.
    public func toggleOverview() {
        onMain {
            if self.overviewPanel != nil {
                self.closeOverview(reason: self.searchPicked ? "pick" : "close")
                return
            }
            guard let snapshot = self.lastSnapshot,
                  let screen = self.lastScreen ?? NSScreen.main else {
                Log.line("overview: no windows to show")
                return
            }
            // Start the keyboard selection on the active (focused) window, else the first card.
            self.overviewSelection.index = snapshot.rail.firstIndex(where: { $0.active }) ?? 0
            self.onOverviewVisibility?(true)
            Log.line("overview: open — \(snapshot.rail.count) window(s)")
            let panel = Self.makePanel(level: .popUpMenu)
            self.renderOverview(into: panel, snapshot)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            // Tunable behind-window blur (window-server level). Light radius keeps the windows behind
            // recognizable — unlike NSVisualEffectView's fixed, heavy blur. Applied after the panel is
            // on screen so it has a valid window number.
            setWindowBackgroundBlur(window: panel.windowNumber, radius: Self.overviewBlurRadius)
            self.overviewPanel = panel
            self.loadThumbnails(for: snapshot)
        }
    }

    /// Close the Overview if it's open — ⌘Tab / ⌘` / ⌘Space passed through to the system (`reason`
    /// "left"). Leaving isn't a pick, so any peeked tab is restored.
    public func dismissOverview(reason: String) {
        onMain {
            guard self.overviewPanel != nil else { return }
            self.closeOverview(reason: reason)
        }
    }

    /// Hide the Overview panel, ending any search session with `reason`. Main thread.
    private func closeOverview(reason: String) {
        guard let panel = overviewPanel else { return }
        endSearch(reason: reason)
        panel.orderOut(nil)
        overviewPanel = nil
        onOverviewVisibility?(false)
        Log.line("overview: closed (\(reason))")
    }

    /// A card or rail-chip click: center that window and close. While searching the click is a pick
    /// and goes through `pickSearchResult` (`clickedResult` says which row), so a peeked tab is kept
    /// rather than restored and the session logs `pick`, not `close`. Main thread.
    private func openFromClick(_ id: CGWindowID) {
        guard overviewPanel != nil else { return }
        if search.active {
            let targets = search.results.map(\.candidate.target)
            if let i = clickedResult(window: id, selected: search.selected, targets: targets) {
                pickSearchResult(i, via: "click")
                return
            }
            // No row for this window: center it as it is. Still a pick (rank -1), and any peeked
            // tab — necessarily in another window — goes back.
            Log.line("search: pick kind=window rank=-1 via=click qlen=\(search.query.count) "
                     + "results=\(search.results.count)")
            searchPicked = true
            peekWork?.cancel()
            applyPeek(selected: nil)
        }
        onCenter?(id)
        toggleOverview()
    }

    /// Kick off thumbnail capture for the windows in `snapshot`. If Screen Recording isn't granted
    /// yet, prompt for it once (the cards keep their accent placeholders meanwhile, and thumbnails
    /// appear on a later open once the grant lands).
    private func loadThumbnails(for snapshot: OverlaySnapshot) {
        if WindowThumbnailer.screenRecordingAuthorized() {
            thumbnails.refresh(ids: snapshot.rail.map(\.id), pointSize: Self.cardThumbSize)
        } else if !didRequestScreenRecording {
            didRequestScreenRecording = true
            Log.line("overview: Screen Recording not granted — requesting; thumbnails will appear once allowed (placeholders for now)")
            WindowThumbnailer.requestScreenRecording()
        }
    }

    /// Move the overview's keyboard selection (arrows / vim h j k l), wrapping at the edges. No-op
    /// unless the overview is open. Only mutates the selection model — managed windows don't move.
    public func navigateOverview(_ nav: OverviewNav) {
        onMain {
            guard self.overviewPanel != nil, let count = self.lastSnapshot?.rail.count, count > 0 else { return }
            self.overviewSelection.index = nextOverviewIndex(
                from: self.overviewSelection.index, count: count, perRow: OverviewView.perRow, nav)
        }
    }

    /// Center the keyboard-selected window (same as clicking its card) and dismiss the overview.
    public func confirmOverview() {
        onMain {
            guard self.overviewPanel != nil, let rail = self.lastSnapshot?.rail, !rail.isEmpty else { return }
            let i = min(max(0, self.overviewSelection.index), rail.count - 1)
            self.onCenter?(rail[i].id)
            self.toggleOverview() // close
        }
    }

    // MARK: - Search

    /// ⌃⌥F / menu: open the Overview straight into search; from browse mode, switch to search; while
    /// already searching, close.
    public func toggleSearch(via: String = "hotkey") {
        onMain {
            if self.overviewPanel != nil {
                if self.search.active { self.toggleOverview() } else { self.beginSearch(via: via) }
                return
            }
            self.toggleOverview()
            if self.overviewPanel != nil {
                self.beginSearch(via: via)
            } else {
                self.onOverviewVisibility?(false) // the tap set its flags optimistically — undo them
            }
        }
    }

    /// Switch the open Overview into search (`/`), and kick off the tab scan.
    public func beginSearch(via: String = "slash") {
        onMain {
            guard self.overviewPanel != nil, !self.search.active else { return }
            self.searchOpenedVia = via
            self.searchPicked = false
            if let rail = self.lastSnapshot?.rail { self.search.setRail(rail) }
            self.search.begin()
            self.onSearchActive?(true)
            Log.line("search: begin via=\(via)")
            self.scanTabs()
        }
    }

    /// Apply one search-field key (typing, selection, confirm, escape) while searching.
    public func handleSearchKey(_ key: SearchKey) {
        onMain {
            guard self.overviewPanel != nil, self.search.active else { return }
            switch key {
            case .edit(.deleteBackward) where self.search.query.isEmpty:
                self.endSearch(reason: "grid") // ⌫ on an empty query → back to the card grid
            case .edit(let e):
                self.search.setQuery(applying(e, to: self.search.query))
            case .up:
                self.search.moveSelection(-1)
            case .down:
                self.search.moveSelection(1)
            case .confirm:
                self.pickSearchResult(self.search.selected, via: "key")
            case .escape:
                if self.search.query.isEmpty { self.toggleOverview() } else { self.search.setQuery("") }
            case .paste:
                let line = NSPasteboard.general.string(forType: .string)?
                    .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if !line.isEmpty { self.search.setQuery(self.search.query + line) }
            case .ignore:
                break
            }
            // Peek only follows deliberate ↑↓ moves. Typing never switches a real tab (a pause while
            // typing used to peek whatever tab ranked first); it puts back anything peeked earlier.
            switch key {
            case .up, .down: self.schedulePeek()
            case .edit, .paste, .escape: if !self.peekShown.isEmpty { self.schedulePeek(restoreOnly: true) }
            case .confirm, .ignore: break
            }
            if Log.verbose { self.logSearchState(after: key) }
        }
    }

    /// e2e oracle (`STRIP_VERBOSE` only): what a search key did, as counts plus the selected row's kind
    /// and app name — never the query text or a title (scripts/e2e asserts on this line).
    private func logSearchState(after key: SearchKey) {
        guard key != .ignore else { Log.line("search: key ignored"); return }
        guard search.active else { return }
        let sel = search.results.indices.contains(search.selected) ? search.results[search.selected] : nil
        let kind = sel.map { $0.candidate.target.isTab ? "tab" : "window" } ?? "none"
        Log.line("search: state qlen=\(search.query.count) results=\(search.results.count) "
                 + "sel=\(search.selected) kind=\(kind) app=\(sel?.candidate.appName ?? "-")")
    }

    /// After the selection settles, peek the selected tab result (restoring any other peeked window),
    /// or with `restoreOnly` just restore every peeked window.
    private func schedulePeek(restoreOnly: Bool = false) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.search.active else { return }
            var target = restoreOnly ? nil : self.search.selectedTarget
            if let tab = self.search.tab(for: target), tab.separateWindow { target = nil } // native tabs: no peek
            self.applyPeek(selected: target)
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekSettleDelay, execute: work)
    }

    /// Press whatever tabs `peekPresses` says, then re-capture each touched window so its card shows
    /// the tab now visible. Main thread.
    private func applyPeek(selected: SearchTarget?) {
        applyPresses(peekPresses(selected: selected, shown: peekShown, original: search.originalTabs))
    }

    /// Press each window's tab in `presses` (window → tab index) and re-capture it. Main thread.
    private func applyPresses(_ presses: [CGWindowID: Int]) {
        let original = search.originalTabs
        for (window, index) in presses {
            guard let tab = search.tabs[window].flatMap({ $0.indices.contains(index) ? $0[index] : nil }) else { continue }
            onPressTab?(window) { tab.press() }
            if index == original[window] { peekShown.removeValue(forKey: window) } else { peekShown[window] = index; peekCount += 1 }
            let pressedAt = CFAbsoluteTimeGetCurrent()
            for delay in Self.peekCaptureDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.thumbnails.captureNow(window, pointSize: Self.cardThumbSize) { ok in
                        if !ok { Log.line("search: peek capture failed id=\(window)") }
                        else if delay == Self.peekCaptureDelays.first {
                            Log.line("search: peek id=\(window) captured "
                                     + String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - pressedAt) * 1000))
                        }
                    }
                }
            }
        }
    }

    /// Go to result `i`: switch to its tab (if it's a tab hit), center its window, close the Overview.
    /// `via` is how it was picked (key, click, row) — for the feedback log.
    private func pickSearchResult(_ i: Int, via: String) {
        guard search.results.indices.contains(i) else { return }
        let target = search.results[i].candidate.target
        Log.line("search: pick kind=\(target.isTab ? "tab" : "window") rank=\(i) via=\(via) "
                 + "qlen=\(search.query.count) results=\(search.results.count)")
        searchPicked = true
        peekWork?.cancel()
        // Put back every *other* peeked window; the picked tab is pressed once, below.
        applyPresses(pickRestores(picked: target, shown: peekShown, original: search.originalTabs))
        if case .tab(let id, let index) = target, let tabs = search.tabs[id], tabs.indices.contains(index) {
            let tab = tabs[index]
            if tab.separateWindow {
                onCenterNativeTab?(id) { tab.pressShowingNativeTab() }
            } else {
                onCenterTab?(id) { tab.press() }
            }
        } else {
            onCenter?(target.windowID)
        }
        toggleOverview()
    }

    /// Leave search mode (back to the grid, or as part of closing). Logs the session outcome.
    private func endSearch(reason: String) {
        guard search.active else { return }
        peekWork?.cancel()
        if !searchPicked { applyPeek(selected: nil) } // leaving without a pick → every peeked tab restored
        Log.line("search: end reason=\(reason) via=\(searchOpenedVia) qlen=\(search.query.count) "
                 + "results=\(search.results.count) tabs=\(search.tabCount) peeks=\(peekCount)")
        peekShown = [:]
        peekCount = 0
        search.end()
        scanGeneration += 1 // orphan any scan still in flight
        onSearchActive?(false)
    }

    /// Scan every ring window's tab bar (off-main, per app); hits stream into the results as each
    /// window finishes.
    private func scanTabs() {
        guard let rail = lastSnapshot?.rail, let lookup = windowLookup else { return }
        let requests = rail.compactMap { item in
            lookup(item.id).map { TabScanner.Request(id: item.id, ax: $0, title: item.title, appName: item.appName) }
        }
        guard !requests.isEmpty else { return }
        scanGeneration += 1
        let generation = scanGeneration
        search.setScanning(true)
        let settled = whenAXSettled
        tabScanner.scan(requests,
                        gate: { id, go in
                            guard let settled else { return go() }
                            let asked = CFAbsoluteTimeGetCurrent()
                            // Motion end is global (every window's last write), so a hung app or a
                            // paused display link could hold it forever — scan anyway after a deadline.
                            // Main-thread only, so a plain flag makes it run exactly once.
                            var started = false
                            let start = { (why: String) in
                                guard !started else { return }
                                started = true
                                let waited = (CFAbsoluteTimeGetCurrent() - asked) * 1000
                                if waited > 5 { Log.line("search: tab scan id=\(id) waited \(Int(waited))ms (\(why))") }
                                go()
                            }
                            settled(id) { start("motion settled") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSettleTimeout) {
                                start("timed out — scanning mid-motion")
                            }
                        },
                        onWindow: { [weak self] id, tabs in
                            guard let self, generation == self.scanGeneration else { return }
                            self.search.setTabs(tabs, for: id)
                        },
                        onDone: { [weak self] in
                            guard let self, generation == self.scanGeneration else { return }
                            self.search.setScanning(false)
                        })
    }

    /// (Re)build the overview's SwiftUI content for the given snapshot.
    private func renderOverview(into panel: NSPanel, _ snapshot: OverlaySnapshot) {
        // Keep the selection in range — the rail count can shrink between renders.
        if !snapshot.rail.isEmpty {
            overviewSelection.index = min(max(0, overviewSelection.index), snapshot.rail.count - 1)
        }
        let retitled = search.setRail(snapshot.rail)
        if retitled > 0 {
            Log.line("search: \(retitled) window title(s) changed mid-search (rows keep their session titles)")
        }
        let root = AnyView(
            OverviewView(
                items: snapshot.rail,
                thumbnails: thumbnails,
                selection: overviewSelection,
                search: search,
                onOpen: { [weak self] id in self?.onMain { self?.openFromClick(id) } },
                onClose: { [weak self] in self?.toggleOverview() },
                onPick: { [weak self] i in self?.onMain { self?.pickSearchResult(i, via: "row") } }
            )
        )
        // Update the existing hosting view in place: replacing it on every snapshot (any re-tile while
        // the Overview is open) threw away view state — the search list's scroll position reset, so
        // the selected row could vanish off the list.
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.rootView = root
        } else {
            panel.contentView = NSHostingView(rootView: root)
        }
    }

    // MARK: - Panel plumbing

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// Size a panel to its SwiftUI content's fitting size and return that size.
    private func fit<V: View>(_ hosting: NSHostingView<V>, in panel: NSPanel) -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        return size
    }

    private func show(_ panel: NSPanel) {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
