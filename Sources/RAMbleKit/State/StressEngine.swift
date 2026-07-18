import Foundation

/// Folds every pressure signal into one normalized 0…1 stress score.
///
/// The score is a weighted blend, biased so that the *worst* subsystem
/// dominates (a maxed-out swap should read as stress even if the CPU idles),
/// then temporally smoothed so animations breathe instead of flickering.
public struct StressEngine: Sendable {
    public struct Weights: Sendable {
        public var ram: Float = 0.20
        public var memoryPressure: Float = 0.25
        public var swap: Float = 0.20
        public var cpu: Float = 0.15
        public var gpu: Float = 0.10
        public var disk: Float = 0.05
        public var inference: Float = 0.05
        public init() {}
    }

    public var weights = Weights()
    /// How much the single worst signal bleeds into the blend (0 = pure weighted avg, 1 = pure max).
    public var peakBias: Float = 0.35
    /// Exponential smoothing factor per update (higher = snappier).
    public var smoothing: Float = 0.15

    private var smoothed: Float = 0

    public init() {}

    /// Instantaneous (unsmoothed) stress for a state snapshot.
    public func instantaneous(for s: SystemState) -> Float {
        let inference: Float = s.inferenceRunning ? min(1, 0.5 + s.tokensPerSecond / 200) : 0
        let signals: [(Float, Float)] = [
            (s.ramPercent, weights.ram),
            (s.memoryPressure, weights.memoryPressure),
            (s.swapPercent, weights.swap),
            (s.cpuPercent, weights.cpu),
            (s.gpuPercent, weights.gpu),
            (s.diskPressure, weights.disk),
            (inference, weights.inference),
        ]
        let totalWeight = signals.reduce(0) { $0 + $1.1 }
        let weighted = signals.reduce(0) { $0 + $1.0.clamped01 * $1.1 } / max(totalWeight, .ulpOfOne)
        let peak = signals.map { $0.0.clamped01 }.max() ?? 0
        return (weighted * (1 - peakBias) + peak * peakBias).clamped01
    }

    /// Update the smoothed stress with a new snapshot. Mutates internal EMA state.
    public mutating func update(with s: SystemState) -> Float {
        let target = instantaneous(for: s)
        // Rise faster than we fall: pressure spikes should register immediately.
        let alpha = target > smoothed ? min(1, smoothing * 2.5) : smoothing
        smoothed += (target - smoothed) * alpha
        return smoothed.clamped01
    }
}

extension Float {
    var clamped01: Float { Swift.min(1, Swift.max(0, self)) }
}
