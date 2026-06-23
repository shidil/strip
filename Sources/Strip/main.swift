import AppKit
import StripKit

// Strip is a menu-bar agent (no Dock icon, no main window). `.accessory` keeps it out of the Dock
// and the app switcher while still allowing a status item and overlay windows.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
