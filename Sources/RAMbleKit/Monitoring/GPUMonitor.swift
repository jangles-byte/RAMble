import Foundation
import IOKit

/// Samples GPU utilization (and memory where exposed) from the IOAccelerator
/// performance statistics. On Apple Silicon the unified GPU publishes
/// "Device Utilization %" through this interface.
public final class GPUMonitor {
    public struct Sample {
        public var usage: Float = 0             // 0…1
        public var memoryUsedBytes: UInt64 = 0  // 0 when not exposed
    }

    public init() {}

    public func sample() -> Sample {
        var s = Sample()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return s }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any]
            else { continue }

            if let device = stats["Device Utilization %"] as? Int {
                s.usage = max(s.usage, (Float(device) / 100).clamped01)
            } else if let renderer = stats["Renderer Utilization %"] as? Int {
                s.usage = max(s.usage, (Float(renderer) / 100).clamped01)
            }
            if let inUse = stats["In use system memory"] as? Int {
                s.memoryUsedBytes = max(s.memoryUsedBytes, UInt64(max(0, inUse)))
            } else if let alloc = stats["Alloc system memory"] as? Int {
                s.memoryUsedBytes = max(s.memoryUsedBytes, UInt64(max(0, alloc)))
            }
        }
        return s
    }
}
