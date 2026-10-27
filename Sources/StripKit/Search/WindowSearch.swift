import CoreGraphics
import Foundation

// Window & tab search (Spotlight-style, inside the Overview). Everything in this file is pure — no
// AppKit, no AX — so matching, ranking, query editing and tab-group selection are unit-tested
// headlessly, like `StripLayout`. The AX tab discovery lives in `Accessibility/TabScanner.swift`
// and the UI in `Overlay/SearchPanelView.swift`.

/// What a search hit points at: a whole window, or one tab inside a window's tab bar.
public enum SearchTarget: Hashable {
    case window(CGWindowID)
    /// `index` is the tab's position in the window's scanned tab list (`TabScanner`).
    case tab(window: CGWindowID, index: Int)

    public var windowID: CGWindowID {
        switch self {
        case .window(let id): return id
        case .tab(let id, _): return id
        }
    }

    public var isTab: Bool {
        if case .tab = self { return true }
        return false
    }
}

/// One searchable thing. `order` is a stable tie-break (ring order, tabs after their window) so equal
/// scores never shuffle between keystrokes.
public struct SearchCandidate: Equatable {
    public let target: SearchTarget
    public let title: String
    public let appName: String
    /// The parent window's title, for a tab (shown as context, matched only weakly). Empty for windows.
    public let context: String
    public let order: Int

    public init(target: SearchTarget, title: String, appName: String, context: String = "", order: Int) {
        self.target = target
        self.title = title
        self.appName = appName
        self.context = context
        self.order = order
    }
}

/// A ranked hit, with the matched `Character` offsets in `title` / `appName` for highlighting.
public struct SearchResult: Equatable {
    public let candidate: SearchCandidate
    public let score: Int
    public let titleMatches: [Int]
    public let appMatches: [Int]
}

/// A fuzzy subsequence match: its score and the matched `Character` offsets into the text.
public struct FuzzyMatch: Equatable {
    public let score: Int
    public let indices: [Int]
}

// MARK: - Fuzzy matching

/// Case- and diacritic-insensitive subsequence match of `pattern` in `text`, scored fzf-style:
/// every matched character scores, runs of consecutive matches and matches at word starts score
/// extra, skipped characters cost a little, and longer texts cost a little (so "Mail" beats
/// "Mailchimp – Campaign dashboard" for `mail`). Tries every start position of the first pattern
/// character and greedily matches forward from each, keeping the best — good enough for the tens of
/// candidates a strip holds. Returns nil when `pattern` isn't a subsequence of `text`.
public func fuzzyMatch(_ pattern: String, in text: String) -> FuzzyMatch? {
    let p = pattern.map(fold)
    guard !p.isEmpty else { return nil }
    let raw = Array(text)
    let t = raw.map(fold)
    guard t.count >= p.count else { return nil }

    var best: FuzzyMatch?
    for start in t.indices where t[start] == p[0] {
        var indices = [start]
        var ti = start + 1
        var pi = 1
        while pi < p.count, ti < t.count {
            if t[ti] == p[pi] { indices.append(ti); pi += 1 }
            ti += 1
        }
        guard pi == p.count else { break } // no later start can finish either
        let score = scoreMatch(indices, in: raw)
        if best == nil || score > best!.score { best = FuzzyMatch(score: score, indices: indices) }
    }
    return best
}

private func scoreMatch(_ indices: [Int], in raw: [Character]) -> Int {
    var score = 0
    for (k, i) in indices.enumerated() {
        score += 16
        if i == 0 { score += 8 }
        if isWordStart(i, in: raw) { score += 10 }
        if k > 0 {
            let gap = i - indices[k - 1] - 1
            if gap == 0 { score += 12 } else { score -= min(gap, 12) }
        }
    }
    score -= min(raw.count, 200) / 20
    return score
}

/// A match at the start of a "word": after a separator, or a lower→upper camel-case hump.
private func isWordStart(_ i: Int, in raw: [Character]) -> Bool {
    guard i > 0 else { return true }
    let prev = raw[i - 1], cur = raw[i]
    if !(prev.isLetter || prev.isNumber) { return true }
    if prev.isLowercase && cur.isUppercase { return true }
    return false
}

private func fold(_ c: Character) -> String {
    String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

// MARK: - Ranking

/// Rank `candidates` against `query`. The query is split on whitespace and **every** token must
/// match somewhere (title, app name, or — weakly — a tab's parent-window title), so `fire hades`
/// finds the Firefox tab titled "Hades …". A contiguous whole-query hit in the title and whole-window
/// hits get a small bonus. Highest score first; ties keep candidate order. Empty query → no results.
public func rankSearch(_ query: String, _ candidates: [SearchCandidate], limit: Int = 50) -> [SearchResult] {
    let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else { return [] }
    let phrase = query.trimmingCharacters(in: .whitespaces)

    var results: [SearchResult] = []
    for c in candidates {
        var total = 0
        var titleHits = Set<Int>()
        var appHits = Set<Int>()
        var matchedAll = true
        for token in tokens {
            let title = fuzzyMatch(token, in: c.title)
            let app = fuzzyMatch(token, in: c.appName)
            let context = c.context.isEmpty ? nil : fuzzyMatch(token, in: c.context)
            let titleScore = title?.score ?? Int.min
            let appScore = app.map { $0.score * 3 / 4 } ?? Int.min
            let contextScore = context.map { $0.score / 3 } ?? Int.min
            let best = max(titleScore, appScore, contextScore)
            guard best != Int.min else { matchedAll = false; break }
            total += best
            if best == titleScore, let title { titleHits.formUnion(title.indices) }
            else if best == appScore, let app { appHits.formUnion(app.indices) }
        }
        guard matchedAll else { continue }
        if tokens.count > 1,
           c.title.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            total += 20
        }
        if !c.target.isTab { total += 4 }
        results.append(SearchResult(candidate: c, score: total,
                                    titleMatches: titleHits.sorted(), appMatches: appHits.sorted()))
    }
    results.sort { $0.score != $1.score ? $0.score > $1.score : $0.candidate.order < $1.candidate.order }
    return Array(results.prefix(limit))
}

// MARK: - Query editing

/// One edit to the search query, produced by `searchKey(...)` from a raw keyDown.
public enum QueryEdit: Equatable {
    case insert(String)
    case deleteBackward
    case deleteWord      // ⌥⌫ / ⌃W
    case clear           // ⌘⌫ / ⌃U
}

/// Apply `edit` to `query`. The search field has no cursor — edits always happen at the end, like
/// typing into Spotlight without moving the caret.
public func applying(_ edit: QueryEdit, to query: String) -> String {
    switch edit {
    case .insert(let s):
        return query + s
    case .deleteBackward:
        return String(query.dropLast())
    case .deleteWord:
        var q = Substring(query)
        while let last = q.last, last.isWhitespace { q = q.dropLast() }
        while let last = q.last, !last.isWhitespace { q = q.dropLast() }
        return String(q)
    case .clear:
        return ""
    }
}

// MARK: - Tab-group selection

/// Whether an AX element is a tab button. Two shapes exist in the wild (probed 2026-10-26):
/// Firefox, Terminal and Finder put `AXRadioButton`s inside an `AXTabGroup`; Safari puts
/// `AXRadioButton`/`AXTabButton`s inside an `AXOpaqueProviderGroup` ("Tab bar, N tabs") — and its
/// only `AXTabGroup` wraps the *page content*, holding no buttons at all. So a tab bar is identified
/// by its buttons, not by its container's role: the buttons' parent is the tab bar.
public func isTabButton(role: String, subrole: String?, parentRole: String) -> Bool {
    role == "AXRadioButton" && (subrole == "AXTabButton" || parentRole == "AXTabGroup")
}

/// One tab button read from a window's AX tab group.
public struct TabInfo: Equatable {
    public let title: String
    public let selected: Bool

    public init(title: String, selected: Bool) {
        self.title = title
        self.selected = selected
    }
}

/// Whether each tab of this tab bar is its own window — AppKit's native window tabbing (Terminal,
/// Finder, TextEdit): the bar is an `AXTabGroup` directly under the `AXWindow` (probed with a
/// two-tab NSWindow 2026-10-26: `AXWindow > AXTabGroup "tab bar" > AXRadioButton/AXTabButton`, and
/// `kAXWindows` lists only the visible tab). Switching such a tab swaps the on-screen window (new
/// `CGWindowID`), so it can't be *peeked* without the strip re-adopting windows under the Overview.
/// Browser bars sit deeper (Firefox) or aren't `AXTabGroup`s at all (Safari).
public func tabsAreSeparateWindows(barRole: String, barParentRole: String) -> Bool {
    barRole == "AXTabGroup" && barParentRole == "AXWindow"
}

// MARK: - Tab peek

/// Tab peek (preview while ↑↓ through tab results): which windows need a tab press so each touched
/// window shows the right tab for `selected`. A selected tab is shown in its window; every other
/// window we switched earlier (`shown`: window → tab index currently shown because of a peek) goes
/// back to its `original` tab — except the selected tab's own window, whose press replaces it.
/// `selected == nil` (closing, back to grid, picking a window) restores everything.
/// Returns window → tab index to press; empty when nothing needs to change.
public func peekPresses(selected: SearchTarget?, shown: [CGWindowID: Int],
                        original: [CGWindowID: Int]) -> [CGWindowID: Int] {
    var out: [CGWindowID: Int] = [:]
    var selectedWindow: CGWindowID?
    if case .tab(let w, let i)? = selected {
        selectedWindow = w
        if (shown[w] ?? original[w]) != i { out[w] = i }
    }
    for (w, i) in shown where w != selectedWindow {
        if let o = original[w], o != i { out[w] = o }
    }
    return out
}

/// After pressing an AppKit native tab in `barWindow`'s tab bar, is the app's focused window `focused`
/// the window that tab shows? Only if it's neither the bar's own window (now hidden) nor the window
/// that was focused before the press — the app may have had *another* window focused (a second tab
/// group), which is not the tab we switched to. `focusedBefore` nil (unreadable) can't rule that out.
public func isShownNativeTab(focused: CGWindowID, focusedBefore: CGWindowID?, barWindow: CGWindowID) -> Bool {
    focused != barWindow && focused != focusedBefore
}

/// The tab presses a pick needs before going to `picked`: every peeked window goes back to its
/// original tab — except the picked tab's own window, whose tab the pick itself presses (once; this
/// used to press it a second time). A window pick restores its own window too.
public func pickRestores(picked: SearchTarget, shown: [CGWindowID: Int],
                         original: [CGWindowID: Int]) -> [CGWindowID: Int] {
    guard case .tab(let w, _) = picked else { return peekPresses(selected: nil, shown: shown, original: original) }
    return peekPresses(selected: nil, shown: shown.filter { $0.key != w }, original: original)
}

/// Which result a click on window `id`'s card (or rail chip) picks while searching: the selected
/// result when it lives in that window — so clicking a card that shows a peeked tab lands on that
/// tab, like ↩ — else that window's own row. nil when the window has neither (no query, or only
/// other tabs of it matched): the click just centers the window as it was.
public func clickedResult(window id: CGWindowID, selected: Int, targets: [SearchTarget]) -> Int? {
    if targets.indices.contains(selected), targets[selected].windowID == id { return selected }
    return targets.firstIndex(of: .window(id))
}

/// Which of a window's AX tab groups is its real tab bar. A window can expose more than one
/// `AXTabGroup` — Firefox's sidebar ("Bookmarks", "History", "Customize sidebar") is a second one
/// with identical roles/subroles. The real tab bar is the group whose **selected tab's title matches
/// the window title** (browsers and native NSWindow tabs title the window after the active tab).
/// The title often doesn't say — Firefox titles a New Tab window just "Mozilla Firefox", and private
/// or untitled pages differ too — so failing that, the real bar is the **only group with exactly one
/// selected tab** (a tab bar always has one; the sidebar's buttons are all unselected while no panel
/// is open). A lone group is trusted as-is. Anything else is ambiguous → nil (no tabs, not junk).
public func pickTabGroup(_ groups: [[TabInfo]], windowTitle: String) -> Int? {
    let wt = windowTitle.trimmingCharacters(in: .whitespaces)
    if !wt.isEmpty {
        for (i, group) in groups.enumerated() {
            guard let sel = group.first(where: \.selected) else { continue }
            let st = sel.title.trimmingCharacters(in: .whitespaces)
            guard !st.isEmpty else { continue }
            if wt.hasPrefix(st) || st.hasPrefix(wt) || wt.contains(st) { return i }
        }
    }
    if groups.count == 1 { return 0 }
    let oneSelected = groups.indices.filter { i in groups[i].filter(\.selected).count == 1 }
    return oneSelected.count == 1 ? oneSelected[0] : nil
}
