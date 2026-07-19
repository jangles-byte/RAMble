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

    // GPU-offloaded inference: model loaded + hot GPU counts as generating
    // even when the server process shows little CPU (the Apple Silicon norm).
    let gpuMonitor = LLMMonitor(endpoints: [])
    let loaded: Set<String> = ["llama3.2:3b"]
    _ = gpuMonitor.fold(models: loaded, contextLength: 8192,
                        processStates: [], gpuUsage: 0.9)
    let second = gpuMonitor.fold(models: loaded, contextLength: 8192,
                                 processStates: [], gpuUsage: 0.9)
    expect(second.inferenceRunning, "detects GPU-offloaded inference (loaded model + hot GPU)")
    let cooled = gpuMonitor.fold(models: loaded, contextLength: 8192,
                                 processStates: [], gpuUsage: 0.1)
    expect(!cooled.inferenceRunning && cooled.generationJustFinished,
           "GPU cooling down ends the generation")
    let noModel = LLMMonitor(endpoints: [])
    _ = noModel.fold(models: [], contextLength: 0, processStates: [], gpuUsage: 0.9)
    let hotButEmpty = noModel.fold(models: [], contextLength: 0,
                                   processStates: [], gpuUsage: 0.9)
    expect(!hotButEmpty.inferenceRunning,
           "hot GPU without a loaded model (games etc.) is not inference")
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
    let builtIn = ["Synapse", "Plinko", "Galaxy", "Water Tank", "Motherboard", "Factory"]
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

    // Regression: before the first layout pass the view reports ~1x1 bounds;
    // plugins must not crash (e.g. inverted random ranges) at degenerate sizes.
    for name in builtIn {
        guard let plugin = PluginRegistry.shared.makePlugin(named: name) else { continue }
        plugin.prepare(bounds: SIMD2(1, 1), theme: Themes.glass)
        for _ in 0..<30 { plugin.update(state: extreme, deltaTime: 1.0 / 60.0) }
        expect(true, "\(name) survives degenerate 1x1 bounds")
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

// MARK: - Synapse graph

print("Synapse")
do {
    let synapse = SynapsePlugin()
    synapse.prepare(bounds: SIMD2(1440, 900), theme: Themes.glass)
    let built = synapse.testCounts
    expect(built.nodes > 40, "graph builds a healthy node population (\(built.nodes))")
    expect(built.edges > built.nodes, "graph is well connected (\(built.edges) edges)")

    var inferring = SystemState()
    inferring.cpuPercent = 0.5
    inferring.inferenceRunning = true
    inferring.tokensPerSecond = 60
    for _ in 0..<120 { synapse.update(state: inferring, deltaTime: 1.0 / 60.0) }
    expect(synapse.testCounts.signals > 0, "signals fire during inference")

    let idle = SystemState()
    for _ in 0..<(60 * 20) { synapse.update(state: idle, deltaTime: 1.0 / 60.0) }
    expect(synapse.testCounts.signals < 900, "signal population stays bounded")
}

// MARK: - Update version compare

print("UpdateChecker")
do {
    expect(UpdateChecker.isNewer("1.2.0", than: "1.1.0"), "1.2.0 > 1.1.0")
    expect(!UpdateChecker.isNewer("1.1.0", than: "1.1.0"), "equal versions are not newer")
    expect(UpdateChecker.isNewer("1.10.0", than: "1.9.9"), "numeric compare, not lexical")
    expect(!UpdateChecker.isNewer("0.9", than: "1.0"), "older is not newer")
    expect(UpdateChecker.isNewer("2", than: "1.9.9"), "short version strings work")
}

// MARK: - World-box physics (screen edges trap escapees)

print("World box")
do {
    let plinko = PlinkoPlugin()
    plinko.prepare(bounds: SIMD2(1000, 800), theme: Themes.glass)
    // Simulate scale 0.5: the world extends well below/around the scene box.
    let wMin = SIMD2<Float>(-500, -400)
    let wMax = SIMD2<Float>(1500, 1200)
    plinko.worldChanged(worldMin: wMin, worldMax: wMax)
    var busy = SystemState()
    busy.ramPercent = 0.8
    for _ in 0..<(60 * 20) { plinko.update(state: busy, deltaTime: 1.0 / 60.0) }
    let positions = plinko.testBallPositions
    expect(!positions.isEmpty, "plinko has live balls after 20s")
    expect(positions.allSatisfy { $0.y >= wMin.y - 1 },
           "no ball ever passes below the screen-bottom floor")
    expect(positions.allSatisfy { $0.x >= wMin.x - 1 && $0.x <= wMax.x + 1 },
           "no ball ever escapes the screen sides")
    expect(positions.contains { $0.y < -10 },
           "balls do fall out of the scaled scene box onto the real floor")

    // Settled balls must despawn instead of piling up forever.
    let calm = SystemState()
    for _ in 0..<(60 * 30) { plinko.update(state: calm, deltaTime: 1.0 / 60.0) }
    expect(plinko.testBallPositions.count < positions.count,
           "settled balls fade away instead of piling up")

    // Regression: under sustained stress, jitter used to keep floor balls
    // from ever settling — the cap filled and spawning froze. The stream
    // must keep flowing indefinitely.
    var stressed = SystemState()
    stressed.ramPercent = 0.85
    stressed.memoryPressure = 0.7
    stressed.stress = 0.8
    for _ in 0..<(60 * 90) {
        plinko.update(state: stressed, deltaTime: 1.0 / 60.0)
    }
    let finalPositions = plinko.testBallPositions
    expect(finalPositions.count < 900, "population never pins at the hard cap")
    expect(finalPositions.contains { $0.y > wMin.y + 100 },
           "fresh balls are still falling after 90s of stress")
}

// MARK: - Process inspector

print("ProcessInspector")
do {
    // Attribution rules: CPU/memory metrics are attributable, GPU/disk aren't.
    expect(MetricKind.cpu.attributable && MetricKind.ram.attributable,
           "CPU and RAM are attributable")
    expect(!MetricKind.gpu.attributable && !MetricKind.disk.attributable,
           "GPU and disk have no public per-process API")
    expect(MetricKind.cpu.sortByCPU && !MetricKind.ram.sortByCPU,
           "CPU sorts by cpu, RAM sorts by memory")

    let procs = ProcessInspector.sampleProcesses()
    expect(!procs.isEmpty, "inspector lists running processes (\(procs.count))")
    expect(procs.contains { $0.name.contains("launchd") }, "sees launchd")
    let topMem = ProcessInspector.sorted(procs, for: .ram, limit: 5)
    expect(topMem.count <= 5 && (topMem.first?.rssBytes ?? 0) >= (topMem.last?.rssBytes ?? 0),
           "memory list is sorted descending")
    let topCPU = ProcessInspector.sorted(procs, for: .cpu, limit: 5)
    expect((topCPU.first?.cpuPercent ?? 0) >= (topCPU.last?.cpuPercent ?? 0),
           "cpu list is sorted descending")
    let inspector = ProcessInspector()

    // Terminate must refuse pid ≤ 1 and self — no process is harmed here.
    expect(!inspector.terminate(pid: 1, force: false), "refuses to kill launchd (pid 1)")
    expect(!inspector.terminate(pid: 0, force: false), "refuses pid 0")
    inspector.stop()
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
