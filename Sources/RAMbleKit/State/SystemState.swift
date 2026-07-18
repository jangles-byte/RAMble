import Foundation

/// The single source of truth consumed by every animation plugin.
/// Animations never query the OS directly — they read this snapshot.
public struct SystemState: Equatable, Sendable {
    // Memory
    public var ramPercent: Float = 0          // 0…1 used / total
    public var memoryPressure: Float = 0      // 0…1 normalized pressure
    public var wiredPercent: Float = 0
    public var compressedPercent: Float = 0
    public var cachedPercent: Float = 0
    public var totalRAMBytes: UInt64 = 0
    public var usedRAMBytes: UInt64 = 0
    public var freeRAMBytes: UInt64 = 0

    // Swap
    public var swapPercent: Float = 0         // 0…1 used / allocated (0 when no swap)
    public var swapUsedBytes: UInt64 = 0
    public var swapGrowthRate: Float = 0      // bytes/sec, EMA-smoothed
    public var pageInsPerSecond: Float = 0
    public var pageOutsPerSecond: Float = 0

    // CPU
    public var cpuPercent: Float = 0          // 0…1 total
    public var perCoreUsage: [Float] = []     // 0…1 each
    public var efficiencyCorePercent: Float = 0
    public var performanceCorePercent: Float = 0

    // GPU
    public var gpuPercent: Float = 0          // 0…1
    public var gpuMemoryUsedBytes: UInt64 = 0

    // Disk
    public var diskPressure: Float = 0        // 0…1 normalized I/O saturation
    public var diskReadBytesPerSecond: Float = 0
    public var diskWriteBytesPerSecond: Float = 0

    // AI / LLM workloads
    public var inferenceRunning: Bool = false
    public var tokensPerSecond: Float = 0
    public var contextLength: Int = 0
    public var activeGenerations: Int = 0
    public var loadedModels: [String] = []
    public var modelJustLoaded: Bool = false      // one-shot flag, true for one tick
    public var modelJustUnloaded: Bool = false    // one-shot flag, true for one tick
    public var generationJustFinished: Bool = false
    public var watchedProcesses: [WatchedProcessState] = []

    // Composite
    public var stress: Float = 0              // 0…1, see StressEngine
    /// User preference, not a measurement: global activity multiplier
    /// (0.2 = slow drip … 2.5 = busy screen). Injected by the overlay layer.
    public var intensity: Float = 1

    public init() {}
}

/// Live status of one monitored AI process (Ollama, LM Studio, llama.cpp, …).
public struct WatchedProcessState: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isRunning: Bool
    public var cpuPercent: Float      // 0…1 of one core basis normalized to 0…1 total
    public var memoryPercent: Float   // 0…1 of physical RAM
    public var gpuPercent: Float      // 0…1, best-effort
    public var isInferring: Bool      // heuristic: sustained CPU/GPU activity

    public init(name: String, isRunning: Bool = false, cpuPercent: Float = 0,
                memoryPercent: Float = 0, gpuPercent: Float = 0, isInferring: Bool = false) {
        self.name = name
        self.isRunning = isRunning
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.isInferring = isInferring
    }
}
