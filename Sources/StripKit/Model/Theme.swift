import AppKit

/// Visual identity for the strip, ported from the prototype
/// (`Strip Window Manager.dc.html`, lines 131-134). In the prototype these were keyed by a
/// fixed set of demo "apps"; here we map them onto whatever real apps the user is running by
/// hashing the app's bundle id / name so each app gets a stable accent + letter chip.
public enum Theme {
    /// The prototype's seven demo accent colors. Real apps are assigned one deterministically.
    public static let accentPalette: [NSColor] = [
        NSColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1), // editor  #7aa2f7
        NSColor(srgbRed: 0x41 / 255, green: 0xd1 / 255, blue: 0x8f / 255, alpha: 1), // terminal #41d18f
        NSColor(srgbRed: 0x5b / 255, green: 0x9d / 255, blue: 0xff / 255, alpha: 1), // browser  #5b9dff
        NSColor(srgbRed: 0xb5 / 255, green: 0x8c / 255, blue: 0xf2 / 255, alpha: 1), // chat     #b58cf2
        NSColor(srgbRed: 0xf0 / 255, green: 0xa3 / 255, blue: 0x5e / 255, alpha: 1), // mail     #f0a35e
        NSColor(srgbRed: 0xff / 255, green: 0x7a / 255, blue: 0x90 / 255, alpha: 1), // music    #ff7a90
        NSColor(srgbRed: 0x5f / 255, green: 0xc9 / 255, blue: 0xa0 / 255, alpha: 1), // calendar #5fc9a0
    ]

    /// Pinned accent used by the prototype (#ffd479).
    public static let pinAccent = NSColor(srgbRed: 0xff / 255, green: 0xd4 / 255, blue: 0x79 / 255, alpha: 1)

    /// Stable, deterministic accent for an app derived from a string key (bundle id or name).
    public static func accent(for key: String) -> NSColor {
        accentPalette[stableHash(key) % accentPalette.count]
    }

    /// A single-character chip label for an app (first letter of its localized name, uppercased).
    public static func letter(for appName: String) -> String {
        guard let first = appName.first else { return "•" }
        return String(first).uppercased()
    }

    /// A small, stable, platform-independent string hash (FNV-1a) so accent assignment is
    /// deterministic across launches (Swift's `Hashing` is salted per-process).
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int(h & 0x7fff_ffff)
    }
}
