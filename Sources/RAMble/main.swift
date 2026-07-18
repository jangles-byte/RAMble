import AppKit
import RAMbleKit

// RAMble — AI workload visualization desktop overlay.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
