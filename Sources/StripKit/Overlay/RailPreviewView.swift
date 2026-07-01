import SwiftUI

/// The hover-preview shown above/beside the film rail: a single window's live thumbnail (or an
/// accent-gradient placeholder while it captures / if it can't be captured), bordered in the
/// hovered chip's accent so it's identifiable even though it isn't positioned per-chip (see
/// `OverlayController.handleChipHover`). Mirrors `OverviewCard.body_`'s image-vs-placeholder logic,
/// trimmed down to a single quick-glance card (no title bar, no pin badge).
struct RailPreviewView: View {
    let item: RailItem
    /// Observed (not a plain snapshot) so the preview updates itself once the async capture kicked
    /// off in `OverlayController.handleChipHover` lands — the panel's `rootView` is set once, exactly
    /// like `RailHost`/`OverlayModel`.
    @ObservedObject var thumbnails: ThumbnailStore

    var body: some View {
        ZStack {
            if let thumbnail = thumbnails[item.id] {
                Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255)
                Image(decorative: thumbnail, scale: CGFloat(ThumbnailStore.scale), orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                LinearGradient(
                    colors: [Color(nsColor: item.accent).opacity(0.32),
                             Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.78))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
        }
        .frame(width: 220, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: item.accent), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}
