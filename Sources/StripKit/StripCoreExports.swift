// StripCore holds Strip's pure model, geometry and policies (no AppKit, no AX; ADR-0006).
// Re-export it so StripKit's own files, the Strip executable and StripKitTests see its public
// types (Slot, LayoutConfig, SlotGeometry, MotionPolicy, PromotePolicy, …) without importing it.
@_exported import StripCore
