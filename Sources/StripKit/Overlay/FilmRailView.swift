import SwiftUI

/// Observing wrapper hosted by the rail panel: it watches `OverlayModel.rail` and feeds the pure
/// `FilmRailView`, so the panel's `rootView` is set once and slide updates flow through `@Published`
/// (incremental SwiftUI diff) instead of replacing the whole view tree each render. `onTap` is set
/// once and reads the live callback via the closure passed in.
struct RailHost: View {
    @ObservedObject var model: OverlayModel
    let onTap: (CGWindowID) -> Void
    let onOverview: () -> Void
    let onHoverChange: (CGWindowID, Bool) -> Void

    var body: some View {
        FilmRailView(items: model.rail, onTap: onTap, onOverview: onOverview,
                     onHoverChange: onHoverChange, edge: model.railEdge)
    }
}

/// The film rail: a pill of one chip per ring window, anchored to `edge`. Faithful to the prototype
/// (`Strip Window Manager.dc.html`, lines 51-59 + the `rail` model, lines 269-278):
/// accent + letter/icon chip, dimmed when off the visible strip, white outline on the focused window,
/// gold pin dot when pinned. Clicking a chip centers that window. `.top`/`.bottom` lay the chips out
/// as a horizontal row (the original design); `.left`/`.right` stack them vertically instead, since
/// a horizontal pill wedged into a side edge would either clip or waste most of the screen's height.
struct FilmRailView: View {
    let items: [RailItem]
    let onTap: (CGWindowID) -> Void
    let onOverview: () -> Void
    var onHoverChange: (CGWindowID, Bool) -> Void = { _, _ in }
    var edge: RailEdge = .default

    var body: some View {
        Group {
            if edge.isVertical {
                VStack(spacing: 8) { railLabel; chips; divider(vertical: true); overviewButton }
            } else {
                HStack(spacing: 8) { railLabel; chips; divider(vertical: false); overviewButton }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: 17)
                .fill(Color(red: 17 / 255, green: 17 / 255, blue: 23 / 255).opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.42), radius: 18, y: 14)
        .fixedSize()
    }

    /// Decorative — kept unrotated even in vertical layouts (a rotated label risks clipping/layout
    /// edge cases in `NSHostingView.fittingSize` for a purely cosmetic element).
    private var railLabel: some View {
        Text("FILM")
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(Color(white: 0.48))
    }

    @ViewBuilder private var chips: some View {
        ForEach(items) { item in
            RailChip(item: item)
                .contentShape(Rectangle())
                .onTapGesture { onTap(item.id) }
                .onHover { hovering in onHoverChange(item.id, hovering) }
        }
    }

    private func divider(vertical: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: vertical ? 20 : 1, height: vertical ? 1 : 20)
    }

    private var overviewButton: some View {
        Image(systemName: "square.grid.2x2")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Color(white: 0.6))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { onOverview() }
    }
}

/// A single 44×31 rail chip.
private struct RailChip: View {
    let item: RailItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: item.accent))
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                Text(item.letter)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 44, height: 31)
        .opacity(item.assigned ? 1 : 0.4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: -1) // prototype outline-offset: 1px
                .strokeBorder(outlineColor, lineWidth: outlineWidth)
        )
        .overlay(alignment: .topTrailing) {
            if item.pinned {
                Circle()
                    .fill(Color(nsColor: Theme.pinAccent))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().strokeBorder(Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x1a / 255), lineWidth: 2)
                    )
                    .offset(x: 3, y: -3)
            }
        }
    }

    private var outlineColor: Color {
        item.active ? .white : (item.assigned ? Color.white.opacity(0.5) : .clear)
    }
    private var outlineWidth: CGFloat { item.active ? 2.5 : 2 }
}
