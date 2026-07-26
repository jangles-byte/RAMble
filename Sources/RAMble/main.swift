import AppKit
import Metal
import SwiftUI
import RAMbleKit

// List mode: `RAMble --list-animations` prints every registered scene name
// (one per line) and exits. Used by CI to render whatever a PR contains.
if CommandLine.arguments.contains("--list-animations") {
    PluginRegistry.shared.availableNames.forEach { print($0) }
    exit(0)
}

// Widget-render mode: `RAMble --render-widget <out.png> [calm|busy|crushed]`
// renders the Engine Room meters widget headlessly at a canned state — the
// design critique loop for widgets, like --snapshot is for scenes.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-widget"),
   CommandLine.arguments.count > flagIndex + 1 {
    let outPath = CommandLine.arguments[flagIndex + 1]
    let profile = CommandLine.arguments.count > flagIndex + 2
        ? CommandLine.arguments[flagIndex + 2] : "busy"
    var s = SystemState()
    switch profile {
    case "calm":
        s.ramPercent = 0.42; s.wiredPercent = 0.09; s.compressedPercent = 0.03
        s.memoryPressure = 0.15; s.cpuPercent = 0.08; s.gpuPercent = 0.05
        s.perCoreUsage = [0.15, 0.1, 0.08, 0.05, 0.04, 0.05, 0.03, 0.02, 0.03, 0.02]
        s.stress = 0.08
    case "crushed":
        s.ramPercent = 0.96; s.wiredPercent = 0.14; s.compressedPercent = 0.22
        s.memoryPressure = 0.92; s.swapPercent = 0.85; s.cpuPercent = 0.95
        s.gpuPercent = 1.0; s.diskPressure = 0.7; s.stress = 0.95
        s.perCoreUsage = Array(repeating: 0.95, count: 10)
        s.inferenceRunning = true; s.tokensPerSecond = 110
    default:
        s.ramPercent = 0.68; s.wiredPercent = 0.11; s.compressedPercent = 0.08
        s.memoryPressure = 0.45; s.swapPercent = 0.18; s.cpuPercent = 0.55
        s.gpuPercent = 0.88; s.diskPressure = 0.25; s.stress = 0.52
        s.perCoreUsage = [0.9, 0.75, 0.85, 0.6, 0.5, 0.3, 0.2, 0.15, 0.1, 0.08]
        s.inferenceRunning = true; s.tokensPerSecond = 60
    }
    let png: Data? = MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: EngineBody(state: s, time: 1.7, showHint: true))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    guard let png else {
        FileHandle.standardError.write(Data("render-widget: failed\n".utf8)); exit(1)
    }
    do { try png.write(to: URL(fileURLWithPath: outPath)) } catch {
        FileHandle.standardError.write(Data("render-widget: write failed: \(error)\n".utf8))
        exit(1)
    }
    print("wrote \(outPath)")
    exit(0)
}

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
    var warmup = 180
    if args.count > flagIndex + 5, let w = Int(args[flagIndex + 5]) { warmup = w }
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
                                        state: state, sizePoints: size, warmupFrames: warmup),
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
