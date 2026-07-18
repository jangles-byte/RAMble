import Foundation
import Combine

/// Owns every monitor, samples them on a background queue, folds the results
/// into a `SystemState`, runs the `StressEngine`, and publishes snapshots.
///
/// Fast signals (CPU, memory, GPU, disk) sample at `fastInterval`; expensive
/// ones (process list, LLM HTTP polls) at `slowInterval` and are merged into
/// the next fast tick.
public final class StateEngine: ObservableObject {
    @Published public private(set) var state = SystemState()

    public let fastInterval: TimeInterval
    public let slowInterval: TimeInterval

    private let memory = MemoryMonitor()
    private let cpu = CPUMonitor()
    private let gpu = GPUMonitor()
    private let disk = DiskMonitor()
    private let processes: ProcessMonitor
    private let llm: LLMMonitor
    private var stress = StressEngine()

    private let queue = DispatchQueue(label: "com.ramble.state-engine", qos: .utility)
    private var fastTimer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?

    // Written on `queue`, merged into state on the next fast tick.
    private var latestProcesses: [WatchedProcessState] = []
    private var latestLLM = LLMMonitor.Sample()
    private var llmFlagsConsumed = true

    public init(fastInterval: TimeInterval = 1.0,
                slowInterval: TimeInterval = 2.5,
                watchList: [String] = ProcessMonitor.defaultWatchList) {
        self.fastInterval = fastInterval
        self.slowInterval = slowInterval
        self.processes = ProcessMonitor(watchList: watchList)
        self.llm = LLMMonitor()
    }

    public func start() {
        guard fastTimer == nil else { return }

        let fast = DispatchSource.makeTimerSource(queue: queue)
        fast.schedule(deadline: .now(), repeating: fastInterval, leeway: .milliseconds(100))
        fast.setEventHandler { [weak self] in self?.fastTick() }
        fast.resume()
        fastTimer = fast

        let slow = DispatchSource.makeTimerSource(queue: queue)
        slow.schedule(deadline: .now() + 0.2, repeating: slowInterval, leeway: .milliseconds(250))
        slow.setEventHandler { [weak self] in self?.slowTick() }
        slow.resume()
        slowTimer = slow
    }

    public func stop() {
        fastTimer?.cancel(); fastTimer = nil
        slowTimer?.cancel(); slowTimer = nil
    }

    public func updateWatchList(_ list: [String]) {
        queue.async { self.processes.watchList = list }
    }

    private func slowTick() {
        let procs = processes.sample()
        latestProcesses = procs
        let gpuNow = gpu.sample()
        let llmSample = llm.sample(processStates: procs, gpuUsage: gpuNow.usage)
        latestLLM = llmSample
        llmFlagsConsumed = false
    }

    private func fastTick() {
        let mem = memory.sample()
        let cpuS = cpu.sample()
        let gpuS = gpu.sample()
        let diskS = disk.sample()

        var s = SystemState()
        let total = Float(max(mem.totalBytes, 1))
        s.totalRAMBytes = mem.totalBytes
        s.usedRAMBytes = mem.usedBytes
        s.freeRAMBytes = mem.freeBytes
        s.ramPercent = (Float(mem.usedBytes) / total).clamped01
        s.wiredPercent = (Float(mem.wiredBytes) / total).clamped01
        s.compressedPercent = (Float(mem.compressedBytes) / total).clamped01
        s.cachedPercent = (Float(mem.cachedBytes) / total).clamped01
        s.memoryPressure = mem.pressure
        s.swapUsedBytes = mem.swapUsedBytes
        s.swapPercent = mem.swapTotalBytes > 0
            ? (Float(mem.swapUsedBytes) / Float(mem.swapTotalBytes)).clamped01 : 0
        s.swapGrowthRate = mem.swapGrowthBytesPerSec
        s.pageInsPerSecond = mem.pageInsPerSec
        s.pageOutsPerSecond = mem.pageOutsPerSec

        s.cpuPercent = cpuS.totalUsage
        s.perCoreUsage = cpuS.perCore
        s.efficiencyCorePercent = cpuS.efficiencyUsage
        s.performanceCorePercent = cpuS.performanceUsage

        s.gpuPercent = gpuS.usage
        s.gpuMemoryUsedBytes = gpuS.memoryUsedBytes

        s.diskPressure = diskS.pressure
        s.diskReadBytesPerSecond = diskS.readBytesPerSec
        s.diskWriteBytesPerSecond = diskS.writeBytesPerSec

        s.watchedProcesses = latestProcesses
        s.inferenceRunning = latestLLM.inferenceRunning
        s.tokensPerSecond = latestLLM.tokensPerSecond
        s.contextLength = latestLLM.contextLength
        s.activeGenerations = latestLLM.activeGenerations
        s.loadedModels = latestLLM.loadedModels

        // One-shot event flags fire on exactly one published state.
        if !llmFlagsConsumed {
            s.modelJustLoaded = latestLLM.modelJustLoaded
            s.modelJustUnloaded = latestLLM.modelJustUnloaded
            s.generationJustFinished = latestLLM.generationJustFinished
            llmFlagsConsumed = true
        }

        s.stress = stress.update(with: s)

        DispatchQueue.main.async { [weak self] in self?.state = s }
    }
}
