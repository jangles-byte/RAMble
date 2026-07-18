import AppKit
import RAMbleKit

// Icon-generation mode: `RAMble --render-icon <dir>` writes ram-head PNGs
// at all app-icon sizes and exits (used by scripts/make-app.sh).
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try? RamHeadIcon.writePNG(size: base,
            to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
        try? RamHeadIcon.writePNG(size: base * 2,
            to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    exit(0)
}

// RAMble — AI workload visualization desktop overlay.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
