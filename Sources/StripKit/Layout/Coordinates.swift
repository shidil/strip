import AppKit

/// Strip works internally in **Quartz global** coordinates (top-left origin, Y down) because that
/// is what the Accessibility API reads and writes. AppKit (`NSScreen`, overlay windows) uses
/// **Cocoa** coordinates (bottom-left origin, Y up). These helpers convert between the two.
public enum Coordinates {
    /// Height of the primary display (the one whose Cocoa origin is (0,0)); the flip pivot.
    public static var primaryHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }

    /// Cocoa rect (bottom-left) → Quartz rect (top-left). Involution: same formula both ways.
    public static func toQuartz(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    public static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}

public extension NSScreen {
    /// This screen's full frame in Quartz global coordinates (top-left origin).
    var quartzFrame: CGRect { Coordinates.toQuartz(frame) }

    /// This screen's frame minus the menu bar and Dock, in Quartz global coordinates.
    var quartzVisibleFrame: CGRect { Coordinates.toQuartz(visibleFrame) }
}
