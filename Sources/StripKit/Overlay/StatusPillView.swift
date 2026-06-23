import SwiftUI

/// Compact status pill (top-center): active app · layout · mode · transition · clock. The prototype
/// renders this as a full-width fake menu bar (lines 23-38); since the real macOS menu bar already
/// owns the top edge, Strip shows the same information as a floating pill instead.
struct StatusPillView: View {
    let snapshot: OverlaySnapshot

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(LinearGradient(
                    colors: [.white, Color(red: 0xb9 / 255, green: 0xc0 / 255, blue: 1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 11, height: 11)
            Text(snapshot.activeApp)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(Color(white: 0.92))
            label(snapshot.layoutLabel)
            dot
            label(snapshot.modeLabel)
            dot
            label(snapshot.transLabel)
            Text("|").font(.system(size: 11)).foregroundColor(.white.opacity(0.25))
            Text(snapshot.clock)
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
