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
    case toggleOverview                // Space (M5)
    case toggleHelp                    // ?   (M4)
}

/// A global keyboard tap (Quartz event tap) that recognizes ⌃⌥ + key and forwards strip commands.
/// Requires Accessibility, which Strip already holds. Matched events are consumed; everything else
/// passes through untouched.
public final class HotkeyService {
    /// Invoked on the main thread for each recognized command.
    public var onCommand: ((HotkeyCommand) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // ⌃⌥ — the activation chord.
    private static let chord: CGEventFlags = [.maskControl, .maskAlternate]

    public init() {}

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
        let flags = event.flags
        guard flags.contains(Self.chord) else { return nil }
        // Disallow Command in the chord so app shortcuts (⌘…) are never shadowed.
        if flags.contains(.maskCommand) { return nil }
        let shift = flags.contains(.maskShift)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

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
        case kVK_Space:  return .toggleOverview
        case kVK_ANSI_Slash: return .toggleHelp   // ⌃⌥/  (the "?" key)
        default: return nil
        }
    }
}

// MARK: - C callback

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        service.reEnable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let command = service.command(for: event) else {
        return Unmanaged.passUnretained(event)
    }
    DispatchQueue.main.async { service.onCommand?(command) }
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
private let kVK_ANSI_1 = 0x12
private let kVK_ANSI_2 = 0x13
private let kVK_ANSI_3 = 0x14
private let kVK_Tab    = 0x30
private let kVK_Space  = 0x31
private let kVK_ANSI_Slash = 0x2C
