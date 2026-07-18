import Foundation
import Darwin

/// Samples total and per-core CPU utilization via host_processor_info,
/// splitting efficiency vs performance clusters on Apple Silicon.
public final class CPUMonitor {
    public struct Sample {
        public var totalUsage: Float = 0          // 0…1
        public var perCore: [Float] = []          // 0…1 each
        public var efficiencyUsage: Float = 0     // 0…1 avg across E-cores
        public var performanceUsage: Float = 0    // 0…1 avg across P-cores
    }

    private var previousTicks: [[UInt32]] = []
    private let efficiencyCoreCount: Int
    private let performanceCoreCount: Int

    public init() {
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu")
            ?? ProcessInfo.processInfo.activeProcessorCount
    }

    public func sample() -> Sample {
        var s = Sample()
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return s }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let stateCount = Int(CPU_STATE_MAX)
        var currentTicks: [[UInt32]] = []
        var perCore: [Float] = []

        for core in 0..<Int(cpuCount) {
            let base = core * stateCount
            let ticks = (0..<stateCount).map { UInt32(bitPattern: info[base + $0]) }
            currentTicks.append(ticks)

            if core < previousTicks.count {
                let prev = previousTicks[core]
                let user = Float(ticks[Int(CPU_STATE_USER)] &- prev[Int(CPU_STATE_USER)])
                let system = Float(ticks[Int(CPU_STATE_SYSTEM)] &- prev[Int(CPU_STATE_SYSTEM)])
                let nice = Float(ticks[Int(CPU_STATE_NICE)] &- prev[Int(CPU_STATE_NICE)])
                let idle = Float(ticks[Int(CPU_STATE_IDLE)] &- prev[Int(CPU_STATE_IDLE)])
                let total = user + system + nice + idle
                perCore.append(total > 0 ? ((user + system + nice) / total).clamped01 : 0)
            } else {
                perCore.append(0)
            }
        }
        previousTicks = currentTicks

        s.perCore = perCore
        if !perCore.isEmpty {
            s.totalUsage = perCore.reduce(0, +) / Float(perCore.count)
        }
        // macOS enumerates P-cores first (perflevel0), then E-cores (perflevel1).
        let pCount = min(performanceCoreCount, perCore.count)
        let pCores = perCore.prefix(pCount)
        let eCores = perCore.dropFirst(pCount)
        if !pCores.isEmpty { s.performanceUsage = pCores.reduce(0, +) / Float(pCores.count) }
        if !eCores.isEmpty { s.efficiencyUsage = eCores.reduce(0, +) / Float(eCores.count) }
        return s
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
