import AppKit
import Metal
import RAMbleKit

// Snapshot mode: `RAMble --snapshot <Animation> <Theme> <out.png> [WxH]` renders
// one still through the real HDR pipeline and exits. Headless — no window, no
// screen-recording permission. Used for previews and README/marketing shots.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > flagIndex + 3 {
    let args = CommandLine.arguments
    let pluginName = args[flagIndex + 1]
    let themeName = args[flagIndex + 2]
    let outPath = args[flagIndex + 3]
    var size = SIMD2(1600, 1000)
    if args.count > flagIndex + 4 {
        let parts = args[flagIndex + 4].lowercased().split(separator: "x")
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { size = SIMD2(w, h) }
    }
    guard let device = MTLCreateSystemDefaultDevice(),
          let renderer = try? Renderer(device: device),
          let plugin = PluginRegistry.shared.makePlugin(named: pluginName) else {
        FileHandle.standardError.write(Data("snapshot: setup failed\n".utf8)); exit(1)
    }
    var state = SystemState()
    state.ramPercent = 0.62; state.cpuPercent = 0.45; state.gpuPercent = 0.55
    state.memoryPressure = 0.4; state.stress = 0.5
    state.inferenceRunning = true; state.tokensPerSecond = 55
    state.perCoreUsage = Array(repeating: 0.5, count: 10)
    guard let image = renderer.snapshot(plugin: plugin, theme: Themes.named(themeName),
                                        state: state, sizePoints: size),
          let dst = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { FileHandle.standardError.write(Data("snapshot: render failed\n".utf8)); exit(1) }
    try? dst.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
    exit(0)
}

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
