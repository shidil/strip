import SwiftUI

/// The keyboard cheat-sheet (⌃⌥/). A dimmed full-screen backdrop with a centered card listing the
/// shortcuts. Faithful to the prototype's help overlay (lines 76-95, rows 310-320); the chips show
/// the bare keys and the subtitle names Strip's actual Mod chord (⌃⌥).
struct HelpOverlayView: View {
    let onClose: () -> Void

    /// (key chips, description). Mirrors the prototype `helpRows`.
    static let rows: [(keys: [String], label: String)] = [
        (["H", "L"], "Slide the film — bring the prev / next window to center"),
        (["⇧H", "⇧L"], "Carry the focused window along the strip (reorder)"),
        (["Tab", "J / K"], "Move focus between slots"),
        (["P"], "Pin / unpin the focused slot — it stays put as others flow"),
        (["1", "2", "3"], "Monocle / 2-up / 3-up layout"),
        (["E"], "Toggle focus vs equal column widths"),
        (["-", "="], "Narrow / widen the focus window (monocle: toward filled)"),
        (["↑", "↓"], "Grow / shrink window height"),
        (["[", "]"], "Tighten / loosen gaps & padding"),
        (["T"], "Cycle the film-feel animation"),
        (["Space"], "Overview of every window"),
        (["F"], "Search windows & tabs (or / inside Overview)"),
        (["/"], "Toggle this panel"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            card
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Color(white: 0.91))
            Text("Vim-style, like Niri. All shortcuts are held behind ⌃⌥ (Control + Option).")
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.6))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .center, spacing: 14) {
                        HStack(spacing: 6) {
                            ForEach(row.keys, id: \.self) { KeyCap($0) }
                        }
                        .frame(width: 132, alignment: .leading)
                        Text(row.label)
                            .font(.system(size: 13.5))
                            .foregroundColor(Color(white: 0.78))
                    }
                }
            }
            .padding(.top, 20)
        }
        .padding(EdgeInsets(top: 28, leading: 32, bottom: 28, trailing: 32))
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 19)
                .fill(Color(red: 25 / 255, green: 25 / 255, blue: 31 / 255).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.65), radius: 45, y: 36)
        // The card itself shouldn't close on tap — only the backdrop does.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// A single keyboard key chip.
private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
            )
    }
}
