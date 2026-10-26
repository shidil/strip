import AppKit
import ApplicationServices

/// A tab discovered in a window's tab bar, with the AX element needed to switch to it.
public struct WindowTab {
    public let windowID: CGWindowID
    public let title: String
    public let selected: Bool
    /// AppKit native window tab (each tab is its own window) — not peekable (`tabsAreSeparateWindows`).
    public let separateWindow: Bool
    let element: AXUIElement
    let pid: pid_t

    /// Switch to this tab (AXPress on its tab button). Synchronous cross-process AX — call off-main
    /// (`StripController.centerTab` runs it on the app's AX queue).
    func press() {
        AXUIElementSetMessagingTimeout(element, 0.5)
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if err != .success { Log.line("search: tab press failed id=\(windowID) err=\(err.rawValue)") }
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
    func scan(_ requests: [Request],
              onWindow: @escaping (CGWindowID, [WindowTab]) -> Void,
              onDone: @escaping () -> Void) {
        let group = DispatchGroup()
        let started = CFAbsoluteTimeGetCurrent()
        var withTabs = 0, tabTotal = 0, ambiguous = 0 // touched on main only
        for r in requests {
            group.enter()
            queue(for: r.ax.pid).async {
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
            }
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
            let role = string(node.el, kAXRoleAttribute) ?? ""
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
            for child in children(node.el) where frontier.count < maxNodes {
                frontier.append((child, node.depth + 1, index, role, node.parentRole))
            }
        }
        out.groups = barOrder.count
        guard !barOrder.isEmpty else { return out }

        let read: [[(AXUIElement, TabInfo)]] = barOrder.map { tabInfo(for: bars[$0] ?? []) }
        guard let pick = pickTabGroup(read.map { $0.map(\.1) }, windowTitle: r.title) else {
            out.ambiguous = read.contains { !$0.isEmpty }
            return out
        }
        let separate = barSeparate[barOrder[pick]] ?? false
        out.tabs = read[pick].map { el, info in
            WindowTab(windowID: r.id, title: info.title, selected: info.selected, separateWindow: separate,
                      element: el, pid: r.ax.pid)
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

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(el, callTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        AXUIElementSetMessagingTimeout(el, callTimeout)
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
