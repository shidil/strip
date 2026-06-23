import CoreGraphics

/// Slot geometry, ported verbatim from the prototype's `geom()` (`Strip Window Manager.dc.html`,
/// lines 165-179). The prototype lays out on a fixed 1440×900 "stage" and scales the whole stage to
/// fit the viewport (letterboxing). For a real window manager we instead re-express every value as a
/// **fraction of the active display's visible frame**, so the strip fills the screen — including
/// ultrawides — rather than letterboxing. The pixel constants below are kept exactly as the
/// prototype wrote them and divided by the stage size at projection time, so the proportions are
/// faithful by construction.
enum SlotGeometry {
    static let stageW: CGFloat = 1440
    static let stageH: CGFloat = 900
    /// Vertical center of every window on the stage (`baseY`, prototype line 209).
    static let baseCY: CGFloat = 454

    /// A slot box in stage units: horizontal center `cx`, width `w`, height `h`.
    struct Box {
        var cx: CGFloat, w: CGFloat, h: CGFloat
        init(_ cx: CGFloat, _ w: CGFloat, _ h: CGFloat) { self.cx = cx; self.w = w; self.h = h }
    }

    /// Stage-unit boxes per slot for the given layout (faithful port of `geom()`).
    static func boxes(cols: Int, emphasis: Emphasis, focusSlot: Slot) -> [Slot: Box] {
        switch cols {
        case 1:
            return [.C: Box(720, 1000, 724)]
        case 3:
            if emphasis == .focus {
                return [.L: Box(190, 300, 556), .C: Box(720, 716, 690), .R: Box(1250, 300, 556)]
            } else {
                return [.L: Box(282, 420, 636), .C: Box(720, 420, 636), .R: Box(1158, 420, 636)]
            }
        default: // 2-up
            if emphasis == .focus {
                if focusSlot == .R {
                    return [.L: Box(328, 380, 560), .R: Box(922, 760, 690)]
                } else {
                    return [.L: Box(518, 760, 690), .R: Box(1112, 380, 560)]
                }
            } else {
                return [.L: Box(398, 620, 666), .R: Box(1042, 620, 666)]
            }
        }
    }

    /// Project a stage-unit box into a concrete rect within the display's visible frame
    /// (Quartz coordinates: top-left origin, Y down). Width scales by the visible width, height by
    /// the visible height, independently — so the layout adapts to any aspect ratio.
    static func rect(_ box: Box, in vis: CGRect) -> CGRect {
        let w = box.w / stageW * vis.width
        let h = box.h / stageH * vis.height
        let cx = vis.minX + box.cx / stageW * vis.width
        let cy = vis.minY + baseCY / stageH * vis.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Vertical center line of the strip within `vis` (Quartz).
    static func centerY(in vis: CGRect) -> CGFloat {
        vis.minY + baseCY / stageH * vis.height
    }
}
