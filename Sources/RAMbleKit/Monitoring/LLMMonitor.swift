import Foundation

/// Polls local LLM servers for model and inference activity.
///
/// Supported endpoints:
/// - Ollama:                `GET http://127.0.0.1:11434/api/ps` (loaded models, context size)
/// - LM Studio / llama.cpp / vLLM / other OpenAI-compatible servers:
///                          `GET /v1/models` on their configured ports
///
/// Local servers do not expose live token counters, so tokens/sec is an
/// estimate derived from accelerator activity while a watched process is
/// inferring. Plugins treat it as an intensity signal, not a benchmark.
public final class LLMMonitor {
    public struct Sample {
        public var loadedModels: [String] = []
        public var contextLength: Int = 0
        public var activeGenerations: Int = 0
        public var inferenceRunning: Bool = false
        public var tokensPerSecond: Float = 0
        public var modelJustLoaded: Bool = false
        public var modelJustUnloaded: Bool = false
        public var generationJustFinished: Bool = false
    }

    public struct Endpoint: Sendable {
        public var name: String
        public var url: URL
        public var kind: Kind
        public enum Kind: Sendable { case ollama, openAICompatible }
        public init(name: String, url: URL, kind: Kind) {
            self.name = name
            self.url = url
            self.kind = kind
        }
    }

    public static let defaultEndpoints: [Endpoint] = [
        Endpoint(name: "Ollama", url: URL(string: "http://127.0.0.1:11434/api/ps")!, kind: .ollama),
        Endpoint(name: "LM Studio", url: URL(string: "http://127.0.0.1:1234/v1/models")!, kind: .openAICompatible),
        Endpoint(name: "llama.cpp", url: URL(string: "http://127.0.0.1:8080/v1/models")!, kind: .openAICompatible),
        Endpoint(name: "vLLM", url: URL(string: "http://127.0.0.1:8000/v1/models")!, kind: .openAICompatible),
    ]

    public var endpoints: [Endpoint]
    private let session: URLSession
    private var previousModels: Set<String> = []
    private var wasInferring = false
    private var gpuBusyStreak = 0
    private var tokenRateEMA: Float = 0
    /// Nominal peak local token rate used to scale the intensity estimate.
    private let nominalPeakTokensPerSecond: Float = 120

    public init(endpoints: [Endpoint] = LLMMonitor.defaultEndpoints) {
        self.endpoints = endpoints
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.75
        config.timeoutIntervalForResource = 1.5
        session = URLSession(configuration: config)
    }

    /// Poll all endpoints synchronously (call from a background queue).
    /// `processStates` and `gpuUsage` feed the inference-intensity estimate.
    public func sample(processStates: [WatchedProcessState], gpuUsage: Float) -> Sample {
        var models: Set<String> = []
        var contextLength = 0

        for endpoint in endpoints {
            guard let data = fetch(endpoint.url) else { continue }
            switch endpoint.kind {
            case .ollama:
                let parsed = Self.parseOllamaPS(data)
                models.formUnion(parsed.models)
                contextLength = max(contextLength, parsed.contextLength)
            case .openAICompatible:
                models.formUnion(Self.parseOpenAIModels(data))
            }
        }
        return fold(models: models, contextLength: contextLength,
                    processStates: processStates, gpuUsage: gpuUsage)
    }

    /// Pure state-folding step, separated from network I/O for testability.
    public func fold(models: Set<String>, contextLength: Int,
              processStates: [WatchedProcessState], gpuUsage: Float) -> Sample {
        var s = Sample()
        s.contextLength = contextLength
        s.loadedModels = models.sorted()
        s.modelJustLoaded = !models.subtracting(previousModels).isEmpty
        s.modelJustUnloaded = !previousModels.subtracting(models).isEmpty
        previousModels = models

        let inferringProcs = processStates.filter { $0.isInferring }
        // GPU path: on Apple Silicon the server process barely touches the
        // CPU while the GPU does the generating. A loaded model + sustained
        // GPU load is inference, whatever the CPU says.
        if !models.isEmpty, gpuUsage > 0.45 {
            gpuBusyStreak += 1
        } else {
            gpuBusyStreak = 0
        }
        let gpuInferring = gpuBusyStreak >= 2
        s.inferenceRunning = !inferringProcs.isEmpty || gpuInferring
        s.activeGenerations = max(inferringProcs.count, gpuInferring ? 1 : 0)
        s.generationJustFinished = wasInferring && !s.inferenceRunning
        wasInferring = s.inferenceRunning

        let intensity: Float = s.inferenceRunning
            ? max(gpuUsage, inferringProcs.map(\.cpuPercent).max() ?? 0)
            : 0
        tokenRateEMA += (intensity * nominalPeakTokensPerSecond - tokenRateEMA) * 0.3
        s.tokensPerSecond = tokenRateEMA < 1 ? 0 : tokenRateEMA
        return s
    }

    private func fetch(_ url: URL) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }

    // MARK: - Parsing (public for tests and custom integrations)

    public static func parseOllamaPS(_ data: Data) -> (models: [String], contextLength: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelList = json["models"] as? [[String: Any]] else { return ([], 0) }
        let names = modelList.compactMap { $0["name"] as? String ?? $0["model"] as? String }
        let context = modelList.compactMap { $0["context_length"] as? Int }.max() ?? 0
        return (names, context)
    }

    public static func parseOpenAIModels(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}
