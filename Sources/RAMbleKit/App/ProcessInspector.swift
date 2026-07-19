import Foundation
import Combine
import Darwin

/// Which meter the user clicked — determines how the detail view attributes
/// and sorts the contributing processes.
public enum MetricKind: String, CaseIterable, Identifiable {
    case ram = "RAM"
    case pressure = "Memory Pressure"
    case swap = "Swap"
    case cpu = "CPU"
    case gpu = "GPU"
    case disk = "Disk"
    case stress = "Stress"
    case tokens = "Inference"
    public var id: String { rawValue }

    /// Whether per-process attribution is possible from public APIs.
    public var attributable: Bool {
        switch self {
        case .cpu, .ram, .pressure, .swap, .stress: return true
        case .gpu, .disk, .tokens: return false   // no public per-process API
        }
    }

    public var sortByCPU: Bool { self == .cpu || self == .stress }

    var explanation: String {
        switch self {
        case .ram:
            return "Physical memory in use (app memory + wired + compressed). The processes below hold the most resident memory right now."
        case .pressure:
            return "How hard macOS is working to keep memory available — driven by compression and swap, not just usage. The biggest memory holders are the usual cause."
        case .swap:
            return "Data pushed from RAM out to disk because physical memory ran short. Reducing the memory hogs below relieves it."
        case .cpu:
            return "Total processor load across all cores. The processes below are using the most CPU right now."
        case .gpu:
            return "Graphics/compute load. macOS does not expose per-process GPU use through public APIs, so this shows the overall figure and your monitored AI apps."
        case .disk:
            return "Read/write throughput to storage. macOS does not expose per-process disk I/O without elevated privileges."
        case .stress:
            return "RAMble's composite pressure score across every subsystem. The heaviest CPU processes are shown as the most likely driver."
        case .tokens:
            return "Local LLM generation activity, estimated from accelerator load while a model is loaded."
        }
    }
}

/// One process row for the detail view.
public struct ProcInfo: Identifiable, Equatable {
    public let id: Int32          // pid
    public var name: String
    public var cpuPercent: Float  // raw ps %cpu (can exceed 100 across cores)
    public var memPercent: Float  // % of physical RAM
    public var rssBytes: UInt64
    public var isSelf: Bool
}

/// Fetches and refreshes the top processes on demand (only while a detail
/// window is open), and terminates a process on explicit user request.
public final class ProcessInspector: ObservableObject {
    @Published public private(set) var processes: [ProcInfo] = []
    @Published public private(set) var refreshing = false

    private let queue = DispatchQueue(label: "com.ramble.process-inspector", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    /// Begin refreshing every `interval` seconds. Call `stop()` when the
    /// detail window closes so we're not sampling `ps` in the background.
    public func start(interval: TimeInterval = 2.0) {
        stop()
        refresh()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refresh() {
        DispatchQueue.main.async { self.refreshing = true }
        queue.async { [weak self] in
            guard let self else { return }
            let rows = Self.runPS(selfPID: self.selfPID)
            DispatchQueue.main.async {
                self.processes = rows
                self.refreshing = false
            }
        }
    }

    /// Synchronous process sample on the calling thread — for tests and any
    /// caller that can't pump the main run loop.
    public static func sampleProcesses() -> [ProcInfo] {
        runPS(selfPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Sort a process list for a metric (pure; testable without a run loop).
    public static func sorted(_ procs: [ProcInfo], for kind: MetricKind,
                              limit: Int = 12) -> [ProcInfo] {
        let s = kind.sortByCPU
            ? procs.sorted { $0.cpuPercent > $1.cpuPercent }
            : procs.sorted { $0.rssBytes > $1.rssBytes }
        return Array(s.prefix(limit))
    }

    /// Top `limit` rows for a metric, already sorted.
    public func top(for kind: MetricKind, limit: Int = 12) -> [ProcInfo] {
        Self.sorted(processes, for: kind, limit: limit)
    }

    /// Terminate a process. `force` sends SIGKILL, otherwise SIGTERM.
    /// Returns true if the signal was delivered. Never targets pid ≤ 1 or self.
    @discardableResult
    public func terminate(pid: Int32, force: Bool) -> Bool {
        guard pid > 1, pid != selfPID else { return false }
        let result = kill(pid, force ? SIGKILL : SIGTERM)
        if result == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refresh()
            }
            return true
        }
        return false
    }

    // MARK: - ps

    private static func runPS(selfPID: Int32) -> [ProcInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,pmem=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let cpu = Float(parts[1]),
                  let mem = Float(parts[2]),
                  let rssKB = UInt64(parts[3]) else { return nil }
            // `comm` is usually a full path; show just the executable name.
            let raw = String(parts[4])
            let name = (raw as NSString).lastPathComponent
            return ProcInfo(id: pid, name: name, cpuPercent: cpu, memPercent: mem,
                            rssBytes: rssKB * 1024, isSelf: pid == selfPID)
        }
    }
}
