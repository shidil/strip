import Foundation

/// Apps whose windows **quantize their size** (terminals snap to whole character cells), so animating
/// a resize springs them through dozens of intermediate sizes and they re-quantize on every frame —
/// the visible "staircase" the spring produces. For these we snap straight to the target size in one
/// step instead (one re-quantization, no staircase). Most apps resize per-pixel and stay smooth.
///
/// A pragmatic hardcoded stopgap until M9's bundle-id ignore/denylist config gives this a real home.
/// Pure + unit-tested so the matching is verified without AppKit/AX.
enum SteppingApps {
    /// Known terminal-emulator bundle ids.
    private static let bundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
    ]

    /// Name tokens for terminals without a known bundle id (matched case-insensitively as substrings),
    /// covering things like cmux/tmux front-ends and generic "…Terminal" apps.
    private static let nameTokens: [String] = [
        "term", "cmux", "tmux", "alacritty", "kitty", "wezterm", "ghostty", "console",
    ]

    /// Whether windows of this app step on resize. `key` is the window's accent key (bundle id, or the
    /// app name when no bundle id is available); `appName` is the localized name.
    static func isStepping(key: String, appName: String) -> Bool {
        if bundleIds.contains(key) { return true }
        let name = appName.lowercased()
        return nameTokens.contains { name.contains($0) }
    }
}
