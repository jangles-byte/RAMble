import Foundation
import IOKit

/// Samples aggregate disk throughput from IOBlockStorageDriver statistics
/// and derives a normalized 0…1 "disk pressure" from sustained throughput.
public final class DiskMonitor {
    public struct Sample {
        public var readBytesPerSec: Float = 0
        public var writeBytesPerSec: Float = 0
        public var pressure: Float = 0   // 0…1
    }

    /// Throughput considered "saturated" for pressure normalization (bytes/sec).
    /// Apple Silicon SSDs sustain multiple GB/s; 1.5 GB/s maps to full pressure.
    private let saturationBytesPerSec: Float = 1_500_000_000

    private var lastRead: UInt64?
    private var lastWrite: UInt64?
    private var lastTime: Date?
    private var pressureEMA: Float = 0

    public init() {}

    public func sample() -> Sample {
        var s = Sample()
        let (read, write) = totalBytes()
        let now = Date()
        if let lr = lastRead, let lw = lastWrite, let lt = lastTime {
            let dt = Float(now.timeIntervalSince(lt))
            if dt > 0 {
                s.readBytesPerSec = Float(read &- lr) / dt
                s.writeBytesPerSec = Float(write &- lw) / dt
            }
        }
        lastRead = read
        lastWrite = write
        lastTime = now

        let instant = ((s.readBytesPerSec + s.writeBytesPerSec) / saturationBytesPerSec).clamped01
        pressureEMA += (instant - pressureEMA) * 0.25
        s.pressure = pressureEMA
        return s
    }

    private func totalBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let statsRef = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0),
                let stats = statsRef.takeRetainedValue() as? [String: Any]
            else { continue }
            if let r = stats["Bytes (Read)"] as? UInt64 { read &+= r }
            else if let r = stats["Bytes (Read)"] as? Int { read &+= UInt64(max(0, r)) }
            if let w = stats["Bytes (Write)"] as? UInt64 { write &+= w }
            else if let w = stats["Bytes (Write)"] as? Int { write &+= UInt64(max(0, w)) }
        }
        return (read, write)
    }
}
