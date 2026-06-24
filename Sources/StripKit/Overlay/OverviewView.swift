import AppKit
import SwiftUI

/// Overview (⌃⌥Space): a dimmed full-screen backdrop with a grid of cards, one per ring window.
/// Faithful to the prototype's overview (`Strip Window Manager.dc.html`, lines 97-109 + the
/// `overviewWindows` model, lines 280-288): an accent-tinted card per window with the app name and
/// title, the active window framed by its accent, a "PINNED" badge when pinned. Clicking a card
/// brings that window to center and closes the overview.
///
/// Real window thumbnails would need Screen Recording (deferred for the spike), so each card is an
/// accent placeholder with a faux title bar rather than a live capture.
struct OverviewView: View {
    let items: [RailItem]
    /// Live window thumbnails keyed by `CGWindowID`; cards observe it and swap in real captures as
    /// they land, falling back to an accent placeholder until then (or when Screen Recording is off).
    @ObservedObject var thumbnails: ThumbnailStore
    let onCenter: (CGWindowID) -> Void
    let onClose: () -> Void

    /// Cards per row — matches the prototype's natural wrap at its 1180px max width (3 × 304 + gaps).
    private static let perRow = 3

    /// Chunk the windows into rows so each row can be centered (mirrors the prototype's
    /// `flex-wrap` + `justify-content:center`, which a fixed-column `LazyVGrid` can't reproduce —
    /// it would left-align the last partial row).
    private var rows: [[RailItem]] {
        stride(from: 0, to: items.count, by: Self.perRow).map {
            Array(items[$0 ..< min($0 + Self.perRow, items.count)])
        }
    }

    var body: some View {
        ZStack {
            // The behind-window blur (prototype: backdrop-filter blur over rgba(8,8,12,.68)) is applied
            // at the window-server level by `OverlayController` (`setWindowBackgroundBlur`), with a
            // tunable radius so the windows behind stay recognizable. Here we just lay a faint dark tint
            // the blurred windows show through — it also gives the panel the bit of alpha the
            // window-server blur composites under — and a tap target to dismiss.
            Color(red: 8 / 255, green: 8 / 255, blue: 12 / 255).opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() } // click off the cards to dismiss

            // `minHeight: geo.size.height` makes the content fill the display so the VStack's default
            // centering parks it in the vertical middle; it grows past that (and scrolls) only when
            // there are too many windows to fit.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 28) {
                        hint
                        VStack(spacing: 24) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 24) {
                                    ForEach(row) { item in
                                        OverviewCard(item: item, thumbnail: thumbnails[item.id])
                                            .contentShape(Rectangle())
                                            .onTapGesture { onCenter(item.id); onClose() }
                                    }
                                }
                                .frame(maxWidth: .infinity) // each row spans full width → cards center
                            }
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 64)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
    }

    private var hint: some View {
        (Text("Overview · click a window to bring it to center · ")
            + Text("Space").bold().foregroundColor(.white)
            + Text(" to close"))
            .font(.system(size: 14))
            .foregroundColor(Color(white: 0.72))
    }
}

/// A single 304×190 overview card — an accent placeholder standing in for a live thumbnail.
private struct OverviewCard: View {
    let item: RailItem
    /// Captured window contents, or `nil` to fall back to the accent placeholder.
    let thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            body_
        }
        .frame(width: 304, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color(nsColor: item.accent),
                              lineWidth: item.active ? 3 : 0)
        )
        .shadow(color: .black.opacity(item.active ? 0.6 : 0.5),
                radius: item.active ? 32 : 22, y: item.active ? 18 : 12)
        .overlay(alignment: .topTrailing) {
            if item.pinned { pinnedBadge }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(Color(white: 0.42)).frame(width: 8, height: 8)
                Circle().fill(Color(white: 0.42)).frame(width: 8, height: 8)
                Circle().fill(Color(white: 0.42)).frame(width: 8, height: 8)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: item.accent))
                Text(item.letter).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 20, height: 20)
            Text(item.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(white: 0.88))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(red: 26 / 255, green: 26 / 255, blue: 32 / 255))
    }

    private var body_: some View {
        ZStack {
            if let thumbnail {
                // Real window capture. The image is already at the window's own aspect (no baked-in
                // bars), so `.fit` shows the whole window centered on the dark backing — like Mission
                // Control. `scale: 2` matches the capture scale so the retina image isn't drawn 2×.
                Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255)
                Image(decorative: thumbnail, scale: CGFloat(ThumbnailStore.scale), orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Placeholder: accent gradient + title (shown until a capture lands, or when Screen
                // Recording is unavailable / the window can't be captured).
                LinearGradient(
                    colors: [Color(nsColor: item.accent).opacity(0.32),
                             Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.78))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
        }
    }

    private var pinnedBadge: some View {
        Text("PINNED")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(Color(nsColor: Theme.pinAccent))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 27 / 255, green: 27 / 255, blue: 30 / 255)))
            .padding(9)
    }
}
