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

    /// How far the ring sits outside the window's frame, and its corner radius.
    private static let ringInset: CGFloat = 2
    private static let ringWidth: CGFloat = 3
    private static let ringRadius: CGFloat = 11

    /// Invoked with the window id when a rail chip is clicked.
    public var onCenter: ((CGWindowID) -> Void)?

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
                Log.line("overview: closed")
                return
            }
            guard let snapshot = self.lastSnapshot,
                  let screen = self.lastScreen ?? NSScreen.main else {
                Log.line("overview: no windows to show")
                return
            }
            Log.line("overview: open — \(snapshot.rail.count) window(s)")
            let panel = Self.makePanel(level: .popUpMenu)
            self.renderOverview(into: panel, snapshot)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            self.overviewPanel = panel
        }
    }

    /// (Re)build the overview's SwiftUI content for the given snapshot.
    private func renderOverview(into panel: NSPanel, _ snapshot: OverlaySnapshot) {
        let hosting = NSHostingView(rootView: AnyView(
            OverviewView(
                items: snapshot.rail,
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
