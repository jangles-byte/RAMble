import Testing
@testable import RAMbleKit

@Suite struct StressEngineTests {
    @Test func idleSystemHasLowStress() {
        let engine = StressEngine()
        var s = SystemState()
        s.ramPercent = 0.3
        s.cpuPercent = 0.05
        #expect(engine.instantaneous(for: s) < 0.25)
    }

    @Test func saturatedSystemHasHighStress() {
        let engine = StressEngine()
        var s = SystemState()
        s.ramPercent = 0.97
        s.memoryPressure = 0.9
        s.swapPercent = 0.8
        s.cpuPercent = 0.95
        s.gpuPercent = 0.9
        s.diskPressure = 0.7
        s.inferenceRunning = true
        s.tokensPerSecond = 40
        #expect(engine.instantaneous(for: s) > 0.8)
    }

    @Test func worstSignalDominatesViaPeakBias() {
        let engine = StressEngine()
        var s = SystemState()
        s.swapPercent = 1.0   // only swap is maxed
        // Weighted average alone would be ~0.2; peak bias must lift it well above.
        #expect(engine.instantaneous(for: s) > 0.4)
    }

    @Test func outputIsAlwaysClamped() {
        let engine = StressEngine()
        var s = SystemState()
        s.ramPercent = 5.0        // bogus over-range input
        s.memoryPressure = -3.0   // bogus negative input
        let stress = engine.instantaneous(for: s)
        #expect(stress >= 0 && stress <= 1)
    }

    @Test func smoothingRisesFasterThanItFalls() {
        var engine = StressEngine()
        var busy = SystemState()
        busy.ramPercent = 1; busy.memoryPressure = 1; busy.cpuPercent = 1
        busy.swapPercent = 1; busy.gpuPercent = 1; busy.diskPressure = 1

        var risen: Float = 0
        for _ in 0..<5 { risen = engine.update(with: busy) }

        let idle = SystemState()
        var fallen = risen
        for _ in 0..<5 { fallen = engine.update(with: idle) }

        #expect(risen > 0.5, "should climb quickly under load")
        #expect(fallen > 0.1, "should decay gradually, not snap to zero")
        #expect(fallen < risen)
    }
}
