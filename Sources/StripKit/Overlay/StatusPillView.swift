import SwiftUI

/// Hosted by the (fixed-size, full-width) status panel: it centers the content-sized `StatusPillView`
/// at the top, so the panel never needs to be re-fit/repositioned when the app-name width changes —
/// SwiftUI re-centers the pill within the fixed frame on its own async pass, no forced synchronous
/// layout on the slide hot path (perf: overlay render). Watches `OverlayModel` for incremental updates.
struct StatusHost: View {
    @ObservedObject var model: OverlayModel
    /// Matches the pill's previous offset from the top edge.
    static let topInset: CGFloat = 6

    var body: some View {
        StatusPillView(model: model)
            .padding(.top, Self.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Compact status pill (top-center): active app · layout · mode · transition · clock. The prototype
/// renders this as a full-width fake menu bar (lines 23-38); since the real macOS menu bar already
/// owns the top edge, Strip shows the same information as a floating pill instead.
struct StatusPillView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let status = model.status
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(LinearGradient(
                    colors: [.white, Color(red: 0xb9 / 255, green: 0xc0 / 255, blue: 1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 11, height: 11)
            Text(status.activeApp)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(Color(white: 0.92))
            label(status.layoutLabel)
            dot
            label(status.modeLabel)
            dot
            label(status.transLabel)
            Text("|").font(.system(size: 11)).foregroundColor(.white.opacity(0.25))
            Text(status.clock)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Color(white: 0.9))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(
            Capsule()
                .fill(Color(red: 17 / 255, green: 17 / 255, blue: 23 / 255).opacity(0.78))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
        .fixedSize()
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(Color(white: 0.85))
    }
    private var dot: some View {
        Text("·").font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
    }
}
