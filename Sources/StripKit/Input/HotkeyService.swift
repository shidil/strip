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
    case toggleSearch                  // f   open the Overview straight into search (Spotlight-style)
    case overview(OverviewKey)         // arrows / h j k l / Enter / Esc — only while overview is open
    case beginSearch                   // /   (chordless, Overview open) — switch the Overview into search
    case search(SearchKey)             // typing while the Overview is searching
}

/// Keys that drive the Overview while it's open. Unlike every other command these need **no** ⌃⌥
/// chord (the Overview is modal), so the tap only honors them when told the Overview is showing.
public enum OverviewKey {
    case left, right, up, down         // arrows + vim h/l/k/j → move the selection (wraps)
    case confirm                       // Enter → center the selected window
    case close                         // Esc / Space → dismiss
}

/// Keys that drive the Overview's search field. While searching, **every** keyDown is captured (so
/// typing never leaks into the focused app) — except ⌃⌥ chords (still strip commands) and the
/// system-level ⌘Tab / ⌘` / ⌘Space (passed through).
public enum SearchKey: Equatable {
    case edit(QueryEdit)
    case up, down                      // ↑↓, ⇧Tab/Tab, ⌃P/⌃N, ⌃K/⌃J → move the result selection
    case confirm                       // Enter → go to the selected result
    case escape                        // Esc → clear the query, or close when it's already empty
    case paste                         // ⌘V → append the clipboard's first line
    case ignore                        // captured but does nothing (←/→, F-keys, stray ⌃ combos)
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
    /// While true (and the Overview is open), plain keys are search input. The tap flips this itself
    /// on `/` and ⌃⌥F so the very next keystroke is already routed as text, before the main-queue hop
    /// that tells the overlay; `setSearchActive` from the overlay is the source of truth after that.
    private var searchActive = false

    public init() {}

    /// Tell the tap whether the Overview is open, gating the chordless navigation keys. Closing the
    /// Overview also ends search.
    public func setOverviewOpen(_ open: Bool) {
        overviewOpen = open
        if !open { searchActive = false }
    }

    /// Tell the tap whether the Overview's search field is taking input.
    public func setSearchActive(_ active: Bool) { searchActive = active }

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
        let flags = event.flags
        // While searching, plain keys are text for the search field; ⌃⌥ chords still fall through to
        // the strip commands below (so ⌃⌥Space / ⌃⌥F still close).
        if overviewOpen, searchActive, !flags.contains(Self.chord) {
            return searchKey(keyCode: keyCode,
                             shift: flags.contains(.maskShift),
                             control: flags.contains(.maskControl),
                             option: flags.contains(.maskAlternate),
                             command: flags.contains(.maskCommand),
                             chars: Self.typedCharacters(event)).map { .search($0) }
        }
        // `/` (unmodified) inside the Overview switches it into search mode.
        if overviewOpen, keyCode == kVK_ANSI_Slash,
           flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty {
            searchActive = true
            return .beginSearch
        }
        // While the Overview is open, its navigation keys are recognized chordlessly (and consumed).
        // Anything else falls through to the normal ⌃⌥ logic, so other commands and typing are intact.
        if overviewOpen, let key = Self.overviewKey(for: keyCode) { return .overview(key) }

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
        case kVK_ANSI_F:
            // Opening (or switching) straight into search: route the next keystrokes as text right
            // away. When it's a close instead, the overlay's visibility callback resets both flags.
            if !(overviewOpen && searchActive) { overviewOpen = true; searchActive = true }
            return .toggleSearch
        default: return nil
        }
    }

    /// The text a keyDown types under the current keyboard layout (respects ⇧ and the layout, unlike
    /// the position-based keycode). Dead keys aren't composed — an event tap sees them raw.
    private static func typedCharacters(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length,
                                       unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
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

/// Map a keyDown to a search-field action while the Overview is searching. `nil` means "not ours —
/// pass the event through" (⌘ shortcuts we don't handle); everything else is consumed. Pure (takes the
/// already-decoded modifiers and typed characters) so the mapping is unit-tested without a tap.
func searchKey(keyCode: Int, shift: Bool, control: Bool, option: Bool, command: Bool,
               chars: String) -> SearchKey? {
    // ⌘Tab / ⌘` / ⌘Space stay system-level (app/window switching, Spotlight) — checked first so ⌘Tab
    // isn't read as Tab (next result).
    if command, [kVK_Tab, kVK_Space, kVK_ANSI_Grave].contains(keyCode) { return nil }
    switch keyCode {
    case kVK_Return, kVK_KeypadEnter: return .confirm
    case kVK_Escape:    return .escape
    case kVK_UpArrow:   return .up
    case kVK_DownArrow: return .down
    case kVK_Tab:       return shift ? .up : .down
    case kVK_Delete:
        if command { return .edit(.clear) }
        if option || control { return .edit(.deleteWord) }
        return .edit(.deleteBackward)
    default: break
    }
    if command {
        // Every other ⌘ shortcut is swallowed — ⌘W/⌘Q here would otherwise close or quit the app
        // *behind* the search panel.
        return keyCode == kVK_ANSI_V ? .paste : .ignore
    }
    if control {
        switch keyCode {
        case kVK_ANSI_P, kVK_ANSI_K: return .up
        case kVK_ANSI_N, kVK_ANSI_J: return .down
        case kVK_ANSI_U: return .edit(.clear)
        case kVK_ANSI_W: return .edit(.deleteWord)
        default: return .ignore
        }
    }
    // Printable text only: drop control characters and the private-use range AppKit uses for
    // function/arrow keys (U+F700–U+F8FF).
    let printable = !chars.isEmpty && chars.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0) && !(0xF700 ... 0xF8FF).contains($0.value)
    }
    return printable ? .edit(.insert(chars)) : .ignore
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
private let kVK_ANSI_F = 0x03
private let kVK_ANSI_N = 0x2D
private let kVK_ANSI_U = 0x20
private let kVK_ANSI_V = 0x09
private let kVK_ANSI_W = 0x0D
private let kVK_Delete = 0x33
private let kVK_ANSI_Grave = 0x32
private let kVK_KeypadEnter = 0x4C
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
