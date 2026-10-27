import AppKit
import SwiftUI

/// The Spotlight-style search panel shown at the top of the Overview while searching: a query line
/// and a ranked list of window + tab hits. Keyboard input arrives through the hotkey tap (the panel
/// never takes key focus — Strip never steals focus from managed windows), so the "field" is a
/// rendered string with a caret, not an `NSTextField`.
struct SearchPanelView: View {
    @ObservedObject var search: SearchModel
    /// Rail items by window id — for each hit's app icon / accent.
    let items: [CGWindowID: RailItem]
    let onPick: (Int) -> Void

    private static let width: CGFloat = 720
    private static let rowHeight: CGFloat = 50
    private static let maxVisibleRows = 7

    var body: some View {
        VStack(spacing: 0) {
            field
            if search.hasQuery {
                Divider().overlay(Color.white.opacity(0.08))
                if search.results.isEmpty {
                    Text("No matching windows or tabs")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.55))
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    resultList
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 22 / 255, green: 22 / 255, blue: 28 / 255).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Color(white: 0.6))
            HStack(spacing: 1) {
                if search.query.isEmpty {
                    caret
                    Text("Search windows & tabs").foregroundColor(Color(white: 0.42))
                } else {
                    Text(search.query).foregroundColor(.white)
                    caret
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 22, weight: .regular))
            .lineLimit(1)
            Text(search.scanning ? "scanning tabs…" : "\(items.count) windows · \(search.tabCount) tabs")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.45))
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var caret: some View {
        Rectangle().fill(Color.accentColor).frame(width: 2, height: 24)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(search.results.enumerated()), id: \.offset) { i, result in
                        SearchResultRow(result: result, item: items[result.candidate.target.windowID],
                                        selected: i == search.selected)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(i) }
                            .id(i)
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(search.results.count), CGFloat(Self.maxVisibleRows))
                   * (Self.rowHeight + 2) + 12)
            .onChange(of: search.selected) { _, i in proxy.scrollTo(i) }
        }
    }

    private var footer: some View {
        (Text("↑↓").bold().foregroundColor(.white) + Text(" select · ")
            + Text("↩").bold().foregroundColor(.white) + Text(" go · ")
            + Text("⌫").bold().foregroundColor(.white) + Text(" on empty → grid · ")
            + Text("Esc").bold().foregroundColor(.white) + Text(" clear / close"))
            .font(.system(size: 11))
            .foregroundColor(Color(white: 0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let item: RailItem?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                highlighted(result.candidate.title.isEmpty ? result.candidate.appName : result.candidate.title,
                            result.candidate.title.isEmpty ? result.appMatches : result.titleMatches,
                            base: Color(white: 0.86))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                subtitle
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.candidate.target.isTab ? "TAB" : "WINDOW")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Color(white: result.candidate.target.isTab ? 0.75 : 0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
            if selected {
                Text("↩").font(.system(size: 13, weight: .semibold)).foregroundColor(Color(white: 0.7))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(selected ? 0.12 : 0)))
    }

    private var icon: some View {
        ZStack {
            if let image = item?.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: item?.accent ?? .gray))
                Text(item?.letter ?? "?").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var subtitle: Text {
        let app = highlighted(result.candidate.appName, result.appMatches, base: Color(white: 0.5))
        if result.candidate.target.isTab {
            let context = result.candidate.context.isEmpty ? "window" : "“\(result.candidate.context)”"
            return app + Text(" · tab in \(context)").foregroundColor(Color(white: 0.42))
        }
        return app + Text(" · window").foregroundColor(Color(white: 0.42))
    }

    /// `text` with the characters at `indices` bold + white (the fuzzy-matched letters).
    private func highlighted(_ text: String, _ indices: [Int], base: Color) -> Text {
        let hits = Set(indices)
        var out = Text("")
        var run = ""
        var runIsHit = false
        func flush() {
            guard !run.isEmpty else { return }
            out = out + (runIsHit ? Text(run).bold().foregroundColor(.white) : Text(run).foregroundColor(base))
            run = ""
        }
        for (i, ch) in text.enumerated() {
            let hit = hits.contains(i)
            if hit != runIsHit { flush(); runIsHit = hit }
            run.append(ch)
        }
        flush()
        return out
    }
}
