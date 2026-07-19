import Foundation
import Darwin

/// Samples RAM, swap, paging, and memory-pressure statistics from Mach / sysctl.
public final class MemoryMonitor {
    public struct Sample {
        public var totalBytes: UInt64 = 0
        public var usedBytes: UInt64 = 0
        public var freeBytes: UInt64 = 0
        public var cachedBytes: UInt64 = 0
        public var wiredBytes: UInt64 = 0
        public var compressedBytes: UInt64 = 0
        public var pressure: Float = 0            // 0…1
        public var swapTotalBytes: UInt64 = 0
        public var swapUsedBytes: UInt64 = 0
        public var swapGrowthBytesPerSec: Float = 0
        public var pageInsPerSec: Float = 0
        public var pageOutsPerSec: Float = 0
    }

    private var lastSwapUsed: UInt64?
    private var lastPageIns: UInt64?
    private var lastPageOuts: UInt64?
    private var lastSampleTime: Date?
    private var swapGrowthEMA: Float = 0
    private var osPressureLevel: Float = 0
    private let pressureSource: DispatchSourceMemoryPressure

    public init() {
        pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.pressureSource.data
            if event.contains(.critical) { self.osPressureLevel = 1.0 }
            else if event.contains(.warning) { self.osPressureLevel = 0.6 }
            else { self.osPressureLevel = 0.0 }
        }
        pressureSource.resume()
    }

    deinit { pressureSource.cancel() }

    public func sample() -> Sample {
        var s = Sample()
        let now = Date()
        let dt = Float(lastSampleTime.map { now.timeIntervalSince($0) } ?? 1)
        lastSampleTime = now

        s.totalBytes = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            s.freeBytes = UInt64(vmStats.free_count) * pageSize
            s.wiredBytes = UInt64(vmStats.wire_count) * pageSize
            s.compressedBytes = UInt64(vmStats.compressor_page_count) * pageSize
            s.cachedBytes = UInt64(vmStats.external_page_count) * pageSize
            // Match Activity Monitor's "Memory Used": App Memory + Wired +
            // Compressed, where App Memory excludes purgeable pages (they can
            // be reclaimed instantly and aren't real pressure).
            let purgeable = UInt64(vmStats.purgeable_count)
            let internalPages = UInt64(vmStats.internal_page_count)
            let appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            s.usedBytes = appMemory + s.wiredBytes + s.compressedBytes

            let pageIns = UInt64(vmStats.pageins)
            let pageOuts = UInt64(vmStats.pageouts)
            if let lastIn = lastPageIns, dt > 0 {
                s.pageInsPerSec = Float(pageIns &- lastIn) / dt
            }
            if let lastOut = lastPageOuts, dt > 0 {
                s.pageOutsPerSec = Float(pageOuts &- lastOut) / dt
            }
            lastPageIns = pageIns
            lastPageOuts = pageOuts
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swapTotalBytes = swap.xsu_total
            s.swapUsedBytes = swap.xsu_used
            if let last = lastSwapUsed, dt > 0 {
                let growth = Float(Int64(bitPattern: swap.xsu_used &- last)) / dt
                swapGrowthEMA += (growth - swapGrowthEMA) * 0.3
            }
            lastSwapUsed = swap.xsu_used
            s.swapGrowthBytesPerSec = swapGrowthEMA
        }

        // Blend the coarse OS pressure event level with a derived signal:
        // compression + swap occupancy indicate sustained pressure between events.
        let derived = derivedPressure(sample: s)
        s.pressure = max(osPressureLevel, derived)
        return s
    }

    private func derivedPressure(sample s: Sample) -> Float {
        guard s.totalBytes > 0 else { return 0 }
        let usedFrac = Float(s.usedBytes) / Float(s.totalBytes)
        let compressedFrac = Float(s.compressedBytes) / Float(s.totalBytes)
        let swapFrac = s.swapTotalBytes > 0 ? Float(s.swapUsedBytes) / Float(s.swapTotalBytes) : 0
        // Pressure ramps once used memory passes ~70%, amplified by compression and swap.
        let usage = max(0, usedFrac - 0.7) / 0.3
        return (usage * 0.5 + compressedFrac * 1.5 + swapFrac * 0.4).clamped01
    }
}
