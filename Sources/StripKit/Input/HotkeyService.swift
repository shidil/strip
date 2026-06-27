import AppKit
import CoreGraphics

/// Commands the strip understands. Bound behind a modifier chord so single keys (h/l/j/k…) don't
/// hijack normal typing — the prototype itself notes these "sit behind your Mod key".
public enum HotkeyCommand {
    case slidePrev, slideNext          // h / l
    case focusPrev, focusNext          // j / k, Tab / ⇧Tab
    case movePrev, moveNext            // ⇧H / ⇧L
    case cols(Int)                     // 1 / 2 / 3
    case toggleEmphasis                // e
    case cycleTransition               // t
    case togglePin                     // p   (M3)
    case focusWider                    // =   widen the focused window
    case focusNarrower                 // -   narrow the focused window
    case taller                        // ↑   grow window height
    case shorter                       // ↓   shrink window height
    case gapTighter                    // [   smaller gaps/padding
    case gapLooser                     // ]   larger gaps/padding
    case releaseAll                    // 0   release/suspend escape hatch (M7)
    case toggleOverview                // Space (M5)
    case toggleHelp                    // ?   (M4)
    case overview(OverviewKey)         // arrows / h j k l / Enter / Esc — only while overview is open
}

/// Keys that drive the Overview while it's open. Unlike every other command these need **no** ⌃⌥
/// chord (the Overview is modal), so the tap only honors them when told the Overview is showing.
public enum OverviewKey {
    case left, right, up, down         // arrows + vim h/l/k/j → move the selection (wraps)
    case confirm                       // Enter → center the selected window
    case close                         // Esc / Space → dismiss
}

/// A global keyboard tap (Quartz event tap) that recognizes ⌃⌥ + key and forwards strip commands.
/// Requires Accessibility, which Strip already holds. Matched events are consumed; everything else
/// passes through untouched.
public final class HotkeyService {
    /// Invoked on the main thread for each recognized command. `repeated` is true when the keyDown is
    /// an OS auto-repeat (key held down) rather than a fresh press — so navigation can pace a held key
    /// instead of advancing at the full repeat rate.
    public var onCommand: ((_ command: HotkeyCommand, _ repeated: Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // ⌃⌥ — the activation chord.
    private static let chord: CGEventFlags = [.maskControl, .maskAlternate]

    /// While true, the Overview's plain navigation keys are recognized (no chord required) and
    /// consumed. Set on the main run loop (where the tap callback also runs), so no locking is needed.
    private var overviewOpen = false

    public init() {}

    /// Tell the tap whether the Overview is open, gating the chordless navigation keys.
    public func setOverviewOpen(_ open: Bool) { overviewOpen = open }

    @discardableResult
    public func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon
        ) else {
            Log.line("hotkeys: failed to create event tap (is Accessibility granted?)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        Log.line("hotkeys: ⌃⌥ tap active")
        return true
    }

    fileprivate func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns the command for a keyDown event if it matches our chord, else nil (pass through).
    fileprivate func command(for event: CGEvent) -> HotkeyCommand? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // While the Overview is open, its navigation keys are recognized chordlessly (and consumed).
        // Anything else falls through to the normal ⌃⌥ logic, so other commands and typing are intact.
        if overviewOpen, let key = Self.overviewKey(for: keyCode) { return .overview(key) }

        let flags = event.flags
        guard flags.contains(Self.chord) else { return nil }
        // Disallow Command in the chord so app shortcuts (⌘…) are never shadowed.
        if flags.contains(.maskCommand) { return nil }
        let shift = flags.contains(.maskShift)

        switch keyCode {
        case kVK_ANSI_H: return shift ? .movePrev : .slidePrev
        case kVK_ANSI_L: return shift ? .moveNext : .slideNext
        case kVK_ANSI_J: return .focusPrev
        case kVK_ANSI_K: return .focusNext
        case kVK_Tab:    return shift ? .focusPrev : .focusNext
        case kVK_ANSI_1: return .cols(1)
        case kVK_ANSI_2: return .cols(2)
        case kVK_ANSI_3: return .cols(3)
        case kVK_ANSI_E: return .toggleEmphasis
        case kVK_ANSI_T: return .cycleTransition
        case kVK_ANSI_P: return .togglePin
        case kVK_ANSI_Equal:  return .focusWider
        case kVK_ANSI_Minus:  return .focusNarrower
        case kVK_UpArrow:     return .taller
        case kVK_DownArrow:   return .shorter
        case kVK_ANSI_LeftBracket:  return .gapTighter
        case kVK_ANSI_RightBracket: return .gapLooser
        case kVK_ANSI_0: return .releaseAll
        case kVK_Space:  return .toggleOverview
        case kVK_ANSI_Slash: return .toggleHelp   // ⌃⌥/  (the "?" key)
        default: return nil
        }
    }

    /// Map a keycode to an Overview navigation key (arrows + vim h/j/k/l, Enter, Esc/Space), or nil.
    /// Used only while the Overview is open. Vim mapping is the 2-D convention: h=left, l=right,
    /// j=down, k=up.
    private static func overviewKey(for keyCode: Int) -> OverviewKey? {
        switch keyCode {
        case kVK_LeftArrow, kVK_ANSI_H:  return .left
        case kVK_RightArrow, kVK_ANSI_L: return .right
        case kVK_UpArrow, kVK_ANSI_K:    return .up
        case kVK_DownArrow, kVK_ANSI_J:  return .down
        case kVK_Return:                 return .confirm
        case kVK_Escape, kVK_Space:      return .close
        default:                         return nil
        }
    }
}

// MARK: - C callback

/// Cached mach timebase for converting `CGEvent.timestamp` (mach ticks) deltas to nanoseconds.
private let machTimebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // The OS disabled our tap — the main run loop blocked past the tap timeout (the Phase 3
        // failure mode) or the user is typing fast. Count it: a non-zero rate here is the signal that
        // the tap needs its own thread. (Integer-free event; zero-cost when not tracing.)
        Signpost.log.emitEvent("tapDisabled")
        service.reEnable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let command = service.command(for: event) else {
        return Unmanaged.passUnretained(event)
    }
    // Headline metric (chord→tap latency): how long the keyDown waited from the window server
    // creating it until this callback ran. Because the tap source is on the MAIN run loop, this
    // includes any time the main thread was blocked (e.g. a reconcile) — the Phase 3 cost. CGEvent
    // timestamps are mach_absolute_time ticks; convert the delta to microseconds (non-allocating).
    let nowTicks = mach_absolute_time()
    let evTicks = event.timestamp
    let deltaTicks = nowTicks > evTicks ? nowTicks - evTicks : 0
    let latencyUs = deltaTicks &* UInt64(machTimebase.numer) / UInt64(machTimebase.denom) / 1000
    Signpost.log.emitEvent("chordLatency", "us=\(latencyUs)")
    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    DispatchQueue.main.async { service.onCommand?(command, repeated) }
    return nil // consume
}

// Virtual key codes (kVK_* from Carbon/HIToolbox) — layout-position based, which is what vim-style
// navigation wants.
private let kVK_ANSI_H = 0x04
private let kVK_ANSI_L = 0x25
private let kVK_ANSI_J = 0x26
private let kVK_ANSI_K = 0x28
private let kVK_ANSI_P = 0x23
private let kVK_ANSI_E = 0x0E
private let kVK_ANSI_T = 0x11
private let kVK_ANSI_0 = 0x1D
private let kVK_ANSI_1 = 0x12
private let kVK_ANSI_2 = 0x13
private let kVK_ANSI_3 = 0x14
private let kVK_ANSI_Equal = 0x18
private let kVK_ANSI_Minus = 0x1B
private let kVK_ANSI_LeftBracket  = 0x21
private let kVK_ANSI_RightBracket = 0x1E
private let kVK_Tab    = 0x30
private let kVK_Space  = 0x31
private let kVK_ANSI_Slash = 0x2C
private let kVK_Return  = 0x24
private let kVK_Escape  = 0x35
private let kVK_LeftArrow  = 0x7B
private let kVK_RightArrow = 0x7C
private let kVK_DownArrow  = 0x7D
private let kVK_UpArrow    = 0x7E
