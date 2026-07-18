import Foundation
import Testing
@testable import RAMbleKit

@Suite struct LLMMonitorTests {
    @Test func parsesOllamaPS() {
        let json = """
        {"models":[{"name":"llama3.2:3b","model":"llama3.2:3b","size":3500000000,
                    "context_length":8192},
                   {"name":"qwen2.5:7b","context_length":32768}]}
        """.data(using: .utf8)!
        let parsed = LLMMonitor.parseOllamaPS(json)
        #expect(parsed.models.sorted() == ["llama3.2:3b", "qwen2.5:7b"])
        #expect(parsed.contextLength == 32768)
    }

    @Test func parsesOpenAIModels() {
        let json = """
        {"object":"list","data":[{"id":"mistral-7b-instruct","object":"model"},
                                 {"id":"phi-4","object":"model"}]}
        """.data(using: .utf8)!
        #expect(LLMMonitor.parseOpenAIModels(json).sorted()
                == ["mistral-7b-instruct", "phi-4"])
    }

    @Test func malformedPayloadsYieldEmptyResults() {
        let garbage = "not json".data(using: .utf8)!
        #expect(LLMMonitor.parseOllamaPS(garbage).models.isEmpty)
        #expect(LLMMonitor.parseOpenAIModels(garbage).isEmpty)
    }

    @Test func idleSampleHasNoActivity() {
        let monitor = LLMMonitor(endpoints: [])  // no network in tests
        let idle = monitor.sample(processStates: [], gpuUsage: 0)
        #expect(!idle.modelJustLoaded)
        #expect(!idle.inferenceRunning)
        #expect(idle.tokensPerSecond == 0)
    }

    @Test func inferenceDetectionFromProcessStates() {
        let monitor = LLMMonitor(endpoints: [])
        let inferring = WatchedProcessState(name: "ollama", isRunning: true,
                                            cpuPercent: 0.7, isInferring: true)
        let sample = monitor.sample(processStates: [inferring], gpuUsage: 0.8)
        #expect(sample.inferenceRunning)
        #expect(sample.activeGenerations == 1)
        #expect(sample.tokensPerSecond > 0)

        let done = monitor.sample(processStates: [], gpuUsage: 0)
        #expect(done.generationJustFinished)
    }
}
