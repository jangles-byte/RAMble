import Foundation

/// Watches a configurable set of AI-related processes (Ollama, LM Studio,
/// llama.cpp, vLLM, …) by sampling `ps` at a low cadence. Shelling out to
/// `ps` avoids private-API entitlements while staying well under the CPU
/// budget at a 2-second cadence.
public final class ProcessMonitor {
    public static let defaultWatchList = [
        "ollama", "LM Studio", "lms", "llama-server", "llama-cli", "llama.cpp",
        "open-webui", "vllm", "pythia",
    ]

    /// Case-insensitive substrings matched against the process command name.
    public var watchList: [String]

    /// Sustained CPU above this fraction of one core marks a process as inferring.
    private let inferenceCPUThreshold: Float = 0.5
    private var inferenceStreak: [String: Int] = [:]

    public init(watchList: [String] = ProcessMonitor.defaultWatchList) {
        self.watchList = watchList
    }

    public func sample() -> [WatchedProcessState] {
        let rows = runPS()
        var results: [WatchedProcessState] = []
        for watched in watchList {
            let needle = watched.lowercased()
            let matches = rows.filter { $0.command.lowercased().contains(needle) }
            var state = WatchedProcessState(name: watched)
            if !matches.isEmpty {
                state.isRunning = true
                // %cpu from ps is per-core (can exceed 100); normalize to 0…1 of total.
                let coreCount = Float(ProcessInfo.processInfo.activeProcessorCount)
                let cpuSum = matches.reduce(Float(0)) { $0 + $1.cpu }
                state.cpuPercent = (cpuSum / 100 / coreCount).clamped01
                state.memoryPercent = (matches.reduce(Float(0)) { $0 + $1.mem } / 100).clamped01

                let busy = cpuSum / 100 >= inferenceCPUThreshold
                let streak = busy ? (inferenceStreak[watched] ?? 0) + 1 : 0
                inferenceStreak[watched] = streak
                state.isInferring = streak >= 2
            } else {
                inferenceStreak[watched] = 0
            }
            results.append(state)
        }
        return results
    }

    // MARK: - ps parsing

    private struct PSRow {
        var pid: Int32
        var cpu: Float
        var mem: Float
        var command: String
    }

    private func runPS() -> [PSRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,pmem=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Float(parts[1]),
                  let mem = Float(parts[2]) else { return nil }
            return PSRow(pid: pid, cpu: cpu, mem: mem, command: String(parts[3]))
        }
    }
}
