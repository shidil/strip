import AppKit
import SwiftUI

/// Observable state for the Overview's search field: query, ranked results, the selected row, and
/// the scanned tabs. Held by `OverlayController` (not as view `@State`) so it survives the overview's
/// per-snapshot hosting-view rebuild — the same pattern as `OverviewSelection`.
final class SearchModel: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var query = ""
    @Published private(set) var results: [SearchResult] = []
    @Published var selected = 0
    /// Total tabs discovered (excluding each window's active tab, which the window row covers).
    @Published private(set) var tabCount = 0
    @Published private(set) var scanning = false

    /// Scanned tabs per window, in tab-bar order. `SearchTarget.tab(index:)` indexes into these.
    private(set) var tabs: [CGWindowID: [WindowTab]] = [:]
    private var rail: [RailItem] = []

    /// The window the selected result lives in (cards highlight it while searching).
    var selectedWindowID: CGWindowID? {
        results.indices.contains(selected) ? results[selected].candidate.target.windowID : nil
    }

    /// Windows that have at least one hit (non-matching cards dim while a query is typed).
    var matchedWindowIDs: Set<CGWindowID> { Set(results.map(\.candidate.target.windowID)) }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The selected result's target, if any.
    var selectedTarget: SearchTarget? {
        results.indices.contains(selected) ? results[selected].candidate.target : nil
    }

    /// The scanned tab a target points at (nil for window targets / stale indices).
    func tab(for target: SearchTarget?) -> WindowTab? {
        guard case .tab(let w, let i)? = target, let list = tabs[w], list.indices.contains(i) else { return nil }
        return list[i]
    }

    /// Index of each scanned window's originally-active tab (what a peek restores to).
    var originalTabs: [CGWindowID: Int] {
        tabs.compactMapValues { $0.firstIndex(where: \.selected) }
    }

    func begin() {
        active = true
        query = ""
        selected = 0
        recompute()
    }

    func end() {
        active = false
        query = ""
        selected = 0
        results = []
        // Tab elements can go stale (closed tab/window, Space change) — every session rescans.
        tabs = [:]
        tabCount = 0
        scanning = false
    }

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        selected = 0 // a new query always starts on the best hit
        recompute()
    }

    func setRail(_ items: [RailItem]) {
        guard items != rail else { return }
        rail = items
        recompute()
    }

    func setScanning(_ on: Bool) { scanning = on }

    func setTabs(_ windowTabs: [WindowTab], for id: CGWindowID) {
        guard active else { return }
        tabs[id] = windowTabs
        // Drop tabs of windows that left the ring.
        let live = Set(rail.map(\.id))
        tabs = tabs.filter { live.contains($0.key) }
        recompute()
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = posMod(selected + delta, results.count)
    }

    /// Re-rank against the current rail + tabs, keeping the selected *target* when it's still present
    /// (so tabs streaming in don't yank the selection out from under the user).
    private func recompute() {
        let keep = results.indices.contains(selected) ? results[selected].candidate.target : nil
        var candidates: [SearchCandidate] = []
        var order = 0
        var tabTotal = 0
        for item in rail {
            candidates.append(SearchCandidate(target: .window(item.id), title: item.title,
                                              appName: item.appName, order: order))
            order += 1
            for (i, tab) in (tabs[item.id] ?? []).enumerated() where !tab.selected {
                candidates.append(SearchCandidate(target: .tab(window: item.id, index: i), title: tab.title,
                                                  appName: item.appName, context: item.title, order: order))
                order += 1
                tabTotal += 1
            }
        }
        tabCount = tabTotal
        results = active ? rankSearch(query, candidates) : []
        if let keep, let i = results.firstIndex(where: { $0.candidate.target == keep }) {
            selected = i
        } else {
            selected = min(selected, max(0, results.count - 1))
        }
    }
}
