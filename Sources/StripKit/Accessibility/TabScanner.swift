import AppKit
import ApplicationServices

/// A tab discovered in a window's tab bar, with the AX element needed to switch to it.
public struct WindowTab {
    public let windowID: CGWindowID
    public let title: String
    public let selected: Bool
    /// AppKit native window tab (each tab is its own window) — not peekable (`tabsAreSeparateWindows`).
    public let separateWindow: Bool
    /// Position in the scanned tab bar, and the window it lives in — used to find the tab *again*
    /// right before pressing it (`press`).
    let index: Int
    let window: AXWindow
    let element: AXUIElement
    let pid: pid_t

    /// Switch to this tab. Synchronous cross-process AX — call off-main (`StripController.pressTab` /
    /// `centerTab` run it on the app's AX queue).
    ///
    /// The tab bar is **re-read first** and the button looked up by title (index as the tie-break):
    /// the element captured at scan time can be dead by now — Firefox tears its tab bar out of the AX
    /// tree whenever Enhanced UI is toggled off for a motion, and any re-tile mid-search does that.
    /// Falls back to the scanned element when the fresh read finds nothing (e.g. mid-motion).
    func press() {
        let fresh = TabScanner.currentTabButtons(of: window)
        let match: AXUIElement?
        if fresh.indices.contains(index), fresh[index].1.title == title {
            match = fresh[index].0
        } else {
            match = fresh.first { $0.1.title == title }?.0
        }
        let target = match ?? element
        AXUIElementSetMessagingTimeout(target, 0.5)
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if err != .success || match == nil {
            Log.line("search: tab press id=\(windowID) \(match == nil ? "stale-element" : "fresh") "
                     + "err=\(err.rawValue) freshTabs=\(fresh.count)")
        }
    }
}

/// Discovers the tabs inside managed windows through the Accessibility tree — generic across any app
/// that exposes tab buttons (`isTabButton`): verified Firefox, Safari, Terminal and Finder (native
/// NSWindow tabs); expected Chromium-family. Apps that draw their own tab bar (WezTerm, Electron
/// editors) expose nothing and simply yield no tabs.
///
/// Cost model: a bounded walk of each window's AX tree, **never** descending into web content or big
/// content views (the walk is ~36 nodes / 15–20ms for a Firefox window, dominated by per-app AX
/// round-trip latency, not tree size). Per-element AX reads work off-main, so each app is scanned on
/// its own serial queue — a slow app can't stall the others or the main thread. (Enumerating
/// `kAXWindows` is main-bound; this never does — it walks the elements Strip already holds.)
/// Runs only when the Overview enters search, never on a hot path. Measured with the `tabScan`
/// signpost interval.
final class TabScanner {
    /// Roles never descended into: web content (huge, and only rendered by Chromium when AX is forced
    /// on) and large content containers that never hold a window's tab bar.
    private static let skipRoles: Set<String> = [
        "AXWebArea", "AXOutline", "AXTable", "AXBrowser", "AXList", "AXTextArea", "AXGrid",
    ]
    /// Walk bounds per window: depth, node count, and wall-clock (a stuck app gives up fast).
    private static let maxDepth = 9
    private static let maxNodes = 600
    private static let budget: CFAbsoluteTime = 0.25
    /// Per-call AX timeout. The default is seconds, and the wall-clock budget is only checked between
    /// calls — so without this one hung app would hold its queue (and `onDone`) for many seconds.
    private static let callTimeout: Float = 0.15

    private var queues: [pid_t: DispatchQueue] = [:]

    /// One window to scan: its id, AX element, title (to pick the real tab group) and app name (logs).
    struct Request {
        let id: CGWindowID
        let ax: AXWindow
        let title: String
        let appName: String
    }

    /// Scan `requests` concurrently (one serial queue per app). `onWindow` fires on the main thread as
    /// each window finishes — so results stream in — and `onDone` once all have.
    ///
    /// `gate` delays each window's scan until its app is safe to read (`StripController.whenAXSettled`
    /// — Enhanced UI back on after a motion); the default scans immediately.
    func scan(_ requests: [Request],
              gate: @escaping (CGWindowID, @escaping () -> Void) -> Void = { _, go in go() },
              onWindow: @escaping (CGWindowID, [WindowTab]) -> Void,
              onDone: @escaping () -> Void) {
        let group = DispatchGroup()
        let started = CFAbsoluteTimeGetCurrent()
        var withTabs = 0, tabTotal = 0, ambiguous = 0 // touched on main only
        for r in requests {
            group.enter()
            gate(r.id) { [self] in self.queue(for: r.ax.pid).async {
                let sp = Signpost.log
                // Scans overlap across apps, so each interval needs its own id (not `.exclusive`).
                let state = sp.beginInterval("tabScan", id: sp.makeSignpostID(), "id=\(r.id)")
                let t0 = CFAbsoluteTimeGetCurrent()
                let outcome = Self.scanWindow(r)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                sp.endInterval("tabScan", state)
                DispatchQueue.main.async {
                    if !outcome.tabs.isEmpty { withTabs += 1; tabTotal += outcome.tabs.count }
                    if outcome.ambiguous { ambiguous += 1 }
                    if outcome.groups > 0 {
                        Log.line("search: tabs \(r.appName) id=\(r.id) groups=\(outcome.groups) "
                                 + "tabs=\(outcome.tabs.count) nodes=\(outcome.nodes) "
                                 + String(format: "%.1fms", ms)
                                 + (outcome.ambiguous ? " AMBIGUOUS" : ""))
                    }
                    onWindow(r.id, outcome.tabs)
                    group.leave()
                }
            } }
        }
        group.notify(queue: .main) {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            Log.line("search: tab scan done windows=\(requests.count) withTabs=\(withTabs) "
                     + "tabs=\(tabTotal) ambiguous=\(ambiguous) " + String(format: "%.1fms", ms))
            onDone()
        }
    }

    // MARK: - Walk

    private struct Outcome {
        var tabs: [WindowTab] = []
        var groups = 0
        var nodes = 0
        var ambiguous = false
    }

    /// The window's current tab buttons (the picked tab bar), read now. Off-main only.
    static func currentTabButtons(of window: AXWindow) -> [(AXUIElement, TabInfo)] {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window.element, kAXTitleAttribute as CFString, &title)
        let outcome = scanWindow(Request(id: 0, ax: window, title: title as? String ?? "", appName: ""))
        return outcome.tabs.map { ($0.element, TabInfo(title: $0.title, selected: $0.selected)) }
    }

    private static func scanWindow(_ r: Request) -> Outcome {
        var out = Outcome()
        let deadline = CFAbsoluteTimeGetCurrent() + budget
        // Tab buttons grouped by their parent (the tab bar), keyed by the parent's visit index, in
        // discovery order — BFS visits siblings in order, so tabs keep their tab-bar order.
        var bars: [Int: [AXUIElement]] = [:]
        var barOrder: [Int] = []
        var barSeparate: [Int: Bool] = [:]
        // Breadth-first: tab bars sit near the top of a window's tree, so BFS finds them before
        // spending the node budget deep inside toolbars or content.
        var frontier: [(el: AXUIElement, depth: Int, parent: Int, parentRole: String, grandRole: String)] =
            [(r.ax.element, 0, -1, "", "")]
        var head = 0
        while head < frontier.count, out.nodes < maxNodes, CFAbsoluteTimeGetCurrent() < deadline {
            let node = frontier[head]
            let index = head
            head += 1
            out.nodes += 1
            // The root is Strip's own window element (shared with the animator): never change its
            // messaging timeout — only the elements this walk creates get the short one.
            let own = node.depth > 0
            let role = string(node.el, kAXRoleAttribute, timeout: own) ?? ""
            if role == (kAXRadioButtonRole as String) {
                if isTabButton(role: role, subrole: string(node.el, kAXSubroleAttribute), parentRole: node.parentRole) {
                    if bars[node.parent] == nil {
                        barOrder.append(node.parent)
                        barSeparate[node.parent] = tabsAreSeparateWindows(barRole: node.parentRole,
                                                                          barParentRole: node.grandRole)
                    }
                    bars[node.parent, default: []].append(node.el)
                }
                continue
            }
            if skipRoles.contains(role) || node.depth >= maxDepth { continue }
            // Cap the frontier too: a huge container's children would otherwise all be queued.
            for child in children(node.el, timeout: own) where frontier.count < maxNodes {
                frontier.append((child, node.depth + 1, index, role, node.parentRole))
            }
        }
        out.groups = barOrder.count
        guard !barOrder.isEmpty else { return out }

        let read: [[(AXUIElement, TabInfo)]] = barOrder.map { tabInfo(for: bars[$0] ?? []) }
        // The *live* title: Strip's stored one goes stale whenever a tab switches (title changes
        // aren't observed), and a stale title can't tell Firefox's tab bar from its sidebar.
        let title = string(r.ax.element, kAXTitleAttribute, timeout: false) ?? r.title
        guard let pick = pickTabGroup(read.map { $0.map(\.1) }, windowTitle: title) else {
            out.ambiguous = read.contains { !$0.isEmpty }
            return out
        }
        let separate = barSeparate[barOrder[pick]] ?? false
        out.tabs = read[pick].enumerated().map { i, pair in
            WindowTab(windowID: r.id, title: pair.1.title, selected: pair.1.selected, separateWindow: separate,
                      index: i, window: r.ax, element: pair.0, pid: r.ax.pid)
        }
        return out
    }

    /// Title + selected state for each tab button of one tab bar (untitled buttons are dropped).
    private static func tabInfo(for tabs: [AXUIElement]) -> [(AXUIElement, TabInfo)] {
        tabs.compactMap { el in
            let title = string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute) ?? ""
            guard !title.isEmpty else { return nil }
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
            let selected = (v as? NSNumber)?.boolValue ?? false
            return (el, TabInfo(title: title, selected: selected))
        }
    }

    private static func children(_ el: AXUIElement, timeout: Bool = true) -> [AXUIElement] {
        if timeout { AXUIElementSetMessagingTimeout(el, callTimeout) }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String, timeout: Bool = true) -> String? {
        if timeout { AXUIElementSetMessagingTimeout(el, callTimeout) }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        guard let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    /// The app's serial scan queue (created on demand, main-thread only).
    private func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "io.github.shidil.strip.tabs.\(pid)", qos: .userInitiated)
        queues[pid] = q
        return q
    }
}
