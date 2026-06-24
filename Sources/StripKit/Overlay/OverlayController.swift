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
    private let railHosting: NSHostingView<AnyView>
    private let statusPanel: NSPanel
    private let statusHosting: NSHostingView<AnyView>
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
    /// `@ObservedObject` identity stays stable across re-renders while the overview is open.
    private let thumbnails = ThumbnailStore()
    /// Whether we've already asked for Screen Recording this process (prompt at most once).
    private var didRequestScreenRecording = false

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

    public init() {
        railHosting = NSHostingView(rootView: AnyView(EmptyView()))
        statusHosting = NSHostingView(rootView: AnyView(EmptyView()))
        railPanel = Self.makePanel(level: .statusBar)
        statusPanel = Self.makePanel(level: .statusBar)
        focusRingPanel = Self.makePanel(level: .statusBar)
        railPanel.contentView = railHosting
        statusPanel.contentView = statusHosting

        // The ring is a non-interactive layer border that frames the focused window.
        focusRingPanel.ignoresMouseEvents = true
        let ringView = NSView()
        ringView.wantsLayer = true
        ringView.layer?.borderWidth = Self.ringWidth
        ringView.layer?.cornerRadius = Self.ringRadius
        ringView.layer?.borderColor = NSColor.white.cgColor
        focusRingPanel.contentView = ringView
    }

    /// Re-render the rail + status pill for the latest state and reposition them on the active display.
    public func update(_ snapshot: OverlaySnapshot) {
        onMain {
            self.lastScreen = snapshot.screen
            self.lastSnapshot = snapshot
            self.focusAccent = snapshot.activeAccent ?? .white
            // Keep an open overview in sync with the live ring.
            if self.overviewPanel != nil { self.renderOverview(into: self.overviewPanel!, snapshot) }
            self.focusRingPanel.contentView?.layer?.borderColor = self.focusAccent.cgColor
            let vis = snapshot.screen.visibleFrame

            self.railHosting.rootView = AnyView(
                FilmRailView(items: snapshot.rail) { [weak self] id in self?.onCenter?(id) }
            )
            let railSize = self.fit(self.railHosting, in: self.railPanel)
            self.railPanel.setFrameOrigin(NSPoint(x: vis.midX - railSize.width / 2, y: vis.minY + 16))
            self.show(self.railPanel)

            self.statusHosting.rootView = AnyView(StatusPillView(snapshot: snapshot))
            let statusSize = self.fit(self.statusHosting, in: self.statusPanel)
            self.statusPanel.setFrameOrigin(NSPoint(x: vis.midX - statusSize.width / 2,
                                                    y: vis.maxY - statusSize.height - 6))
            self.show(self.statusPanel)
        }
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
            if let panel = self.overviewPanel {
                panel.orderOut(nil)
                self.overviewPanel = nil
                self.onOverviewVisibility?(false)
                Log.line("overview: closed")
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

    /// (Re)build the overview's SwiftUI content for the given snapshot.
    private func renderOverview(into panel: NSPanel, _ snapshot: OverlaySnapshot) {
        // Keep the selection in range — the rail count can shrink between renders.
        if !snapshot.rail.isEmpty {
            overviewSelection.index = min(max(0, overviewSelection.index), snapshot.rail.count - 1)
        }
        let hosting = NSHostingView(rootView: AnyView(
            OverviewView(
                items: snapshot.rail,
                thumbnails: thumbnails,
                selection: overviewSelection,
                onCenter: { [weak self] id in self?.onCenter?(id) },
                onClose: { [weak self] in self?.toggleOverview() }
            )
        ))
        panel.contentView = hosting
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
    private func fit(_ hosting: NSHostingView<AnyView>, in panel: NSPanel) -> NSSize {
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
