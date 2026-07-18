import Foundation
import simd
import RAMbleKit

// RAMbleSelfTest — dependency-free verification runner.
//
// Mirrors the Swift Testing suite in Tests/RAMbleTests so the project can be
// verified on machines with only Command Line Tools (no XCTest/Testing).
// Usage: swift run RAMbleSelfTest   (exits non-zero on failure)

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String,
            file: String = #file, line: Int = #line) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ FAIL: \(label)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

// MARK: - StressEngine

print("StressEngine")
do {
    let engine = StressEngine()
    var idle = SystemState()
    idle.ramPercent = 0.3
    idle.cpuPercent = 0.05
    expect(engine.instantaneous(for: idle) < 0.25, "idle system has low stress")

    var busy = SystemState()
    busy.ramPercent = 0.97; busy.memoryPressure = 0.9; busy.swapPercent = 0.8
    busy.cpuPercent = 0.95; busy.gpuPercent = 0.9; busy.diskPressure = 0.7
    busy.inferenceRunning = true; busy.tokensPerSecond = 40
    expect(engine.instantaneous(for: busy) > 0.8, "saturated system has high stress")

    var swapOnly = SystemState()
    swapOnly.swapPercent = 1.0
    expect(engine.instantaneous(for: swapOnly) > 0.4, "worst signal dominates via peak bias")

    var bogus = SystemState()
    bogus.ramPercent = 5.0; bogus.memoryPressure = -3.0
    let clamped = engine.instantaneous(for: bogus)
    expect(clamped >= 0 && clamped <= 1, "output is always clamped to 0…1")

    var ema = StressEngine()
    var allBusy = SystemState()
    allBusy.ramPercent = 1; allBusy.memoryPressure = 1; allBusy.cpuPercent = 1
    allBusy.swapPercent = 1; allBusy.gpuPercent = 1; allBusy.diskPressure = 1
    var risen: Float = 0
    for _ in 0..<5 { risen = ema.update(with: allBusy) }
    var fallen = risen
    for _ in 0..<5 { fallen = ema.update(with: SystemState()) }
    expect(risen > 0.5, "smoothed stress climbs quickly under load")
    expect(fallen > 0.1 && fallen < risen, "smoothed stress decays gradually")
}

// MARK: - LLMMonitor parsing & transitions

print("LLMMonitor")
do {
    let ollama = """
    {"models":[{"name":"llama3.2:3b","context_length":8192},
               {"name":"qwen2.5:7b","context_length":32768}]}
    """.data(using: .utf8)!
    let parsed = LLMMonitor.parseOllamaPS(ollama)
    expect(parsed.models.sorted() == ["llama3.2:3b", "qwen2.5:7b"], "parses Ollama /api/ps models")
    expect(parsed.contextLength == 32768, "picks the largest context length")

    let openai = """
    {"object":"list","data":[{"id":"mistral-7b-instruct"},{"id":"phi-4"}]}
    """.data(using: .utf8)!
    expect(LLMMonitor.parseOpenAIModels(openai).sorted() == ["mistral-7b-instruct", "phi-4"],
           "parses OpenAI-compatible /v1/models")

    let garbage = "not json".data(using: .utf8)!
    expect(LLMMonitor.parseOllamaPS(garbage).models.isEmpty, "malformed Ollama payload → empty")
    expect(LLMMonitor.parseOpenAIModels(garbage).isEmpty, "malformed OpenAI payload → empty")

    let monitor = LLMMonitor(endpoints: [])
    let idle = monitor.sample(processStates: [], gpuUsage: 0)
    expect(!idle.inferenceRunning && idle.tokensPerSecond == 0, "idle sample has no activity")

    let inferring = WatchedProcessState(name: "ollama", isRunning: true,
                                        cpuPercent: 0.7, isInferring: true)
    let active = monitor.sample(processStates: [inferring], gpuUsage: 0.8)
    expect(active.inferenceRunning && active.activeGenerations == 1
           && active.tokensPerSecond > 0, "detects inference from process states")
    let done = monitor.sample(processStates: [], gpuUsage: 0)
    expect(done.generationJustFinished, "flags generation completion")
}

// MARK: - Themes

print("Themes")
do {
    expect(Themes.all.count == 7, "seven built-in themes")
    expect(Set(Themes.all.map(\.name)).count == 7, "theme names are distinct")
    expect(Themes.all.allSatisfy { !$0.palette.isEmpty && $0.particleScale > 0 },
           "every theme has a palette and positive particle scale")
    expect(Themes.named("Cyberpunk").name == "Cyberpunk", "lookup by name")
    expect(Themes.named("Nope").name == "Glass", "unknown name falls back to Glass")
    let theme = Themes.glass
    expect(theme.stressColor(0) == theme.calmColor, "stressColor(0) is calm")
    expect(theme.stressColor(1) == theme.warningColor, "stressColor(1) is warning")
    expect(theme.stressColor(9) == theme.warningColor, "stressColor clamps over-range")
}

// MARK: - Plugins

print("Plugins")
do {
    let builtIn = ["Plinko", "Galaxy", "Water Tank", "Motherboard", "Factory"]
    expect(Set(PluginRegistry.shared.availableNames).isSuperset(of: builtIn),
           "registry lists all built-in plugins")
    for name in builtIn {
        expect(PluginRegistry.shared.makePlugin(named: name)?.name == name,
               "registry builds \(name)")
    }

    var extreme = SystemState()
    extreme.ramPercent = 1; extreme.memoryPressure = 1; extreme.swapPercent = 1
    extreme.cpuPercent = 1; extreme.gpuPercent = 1; extreme.diskPressure = 1
    extreme.inferenceRunning = true; extreme.tokensPerSecond = 500
    extreme.modelJustLoaded = true
    extreme.perCoreUsage = Array(repeating: 1, count: 10)

    for name in builtIn {
        guard let plugin = PluginRegistry.shared.makePlugin(named: name) else { continue }
        plugin.prepare(bounds: SIMD2(1440, 900), theme: Themes.synthwave)
        for _ in 0..<300 { plugin.update(state: extreme, deltaTime: 1.0 / 60.0) }
        for _ in 0..<300 { plugin.update(state: SystemState(), deltaTime: 1.0 / 60.0) }
        expect(true, "\(name) survives 10s of extreme + calm states")
    }

    final class NullPlugin: AnimationPlugin {
        let name = "Null"
        func prepare(bounds: SIMD2<Float>, theme: Theme) {}
        func update(state: SystemState, deltaTime: Float) {}
        func render(renderer: Renderer) {}
    }
    PluginRegistry.shared.register(name: "Null") { NullPlugin() }
    expect(PluginRegistry.shared.makePlugin(named: "Null") != nil,
           "custom plugin registration works")
}

// MARK: - Live monitors (smoke)

print("Monitors (smoke)")
do {
    let mem = MemoryMonitor().sample()
    expect(mem.totalBytes > 0, "memory monitor reports total RAM")
    expect(mem.usedBytes > 0 && mem.usedBytes < mem.totalBytes,
           "used RAM is sane (\(mem.usedBytes / 1_048_576) MB)")

    let cpu = CPUMonitor()
    _ = cpu.sample()                       // first sample primes tick deltas
    Thread.sleep(forTimeInterval: 0.3)
    let cpuS = cpu.sample()
    expect(!cpuS.perCore.isEmpty, "cpu monitor reports \(cpuS.perCore.count) cores")
    expect(cpuS.totalUsage >= 0 && cpuS.totalUsage <= 1, "cpu usage in range")

    let procs = ProcessMonitor(watchList: ["launchd"]).sample()
    expect(procs.first?.isRunning == true, "process monitor sees launchd")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("SELF-TEST FAILED")
    exit(1)
}
print("SELF-TEST PASSED")
