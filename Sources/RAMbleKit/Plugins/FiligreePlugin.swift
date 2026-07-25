import Foundation
import simd

/// Filigree — a Clifford strange attractor as the shape of the machine's
/// mind (docs/filigree-design.md). One deterministic orbit iterated
/// thousands of times a frame deposits a filament sculpture out of faint
/// overlapping points. The parameters breathe in slow orbits around a seed
/// (never traveling between seeds — most of that line is non-chaotic), so
/// the form kneads itself faster the harder the machine works.
///
/// Mapping:
/// - CPU + stress → parameter-orbit tempo (the form flexes faster)
/// - RAM          → iteration density (heavier lace)
/// - Tokens       → the newest points burn hot and colored, then cool
/// - Stress/swap  → the ramp warms / stains red
/// - Model load   → re-seed: a new mind, a new sculpture
public final class FiligreePlugin: AnimationPlugin {
    public let name = "Filigree"

    /// Verified chaotic Clifford seeds (Atelier generative-motion reference).
    private static let seeds: [SIMD4<Float>] = [
        SIMD4(-1.4, 1.6, 1.0, 0.7),
        SIMD4(1.7, 1.7, 0.6, 1.2),
        SIMD4(-1.7, 1.3, -0.1, -1.21),
    ]

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var time: Float = 0
    private var seedIndex = 0
    private var colorAnchor = 0
    private var orbit = SIMD2<Float>(0.1, 0.1)   // current point, attractor space
    private var params = SIMD4<Float>(0, 0, 0, 0)
    private var tempo: Float = 0.5
    private var reseedEnvelope: Float = 0        // 1 right after a re-seed, decays
    private var tempoKick: Float = 0             // surge convulsion, decays
    private var loadEma: Float = 0
    private var surgeArmed = true
    private var hotBudget = 0
    private var iterations = 2600

    public init() {}

    // High persistence builds the filigree out of accumulation; the plotted
    // points are faint and always moving, so nothing piles up in place.
    public var preferredTrailPersistence: Float? { 0.88 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        orbit = SIMD2(0.1, 0.1)
        params = Self.seeds[seedIndex]
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        let intensity = max(state.intensity, 0.05)
        // Surge response: a compute spike convulses the sculpture — the
        // form kneads violently for a moment, then settles.
        let load = max(state.cpuPercent, state.gpuPercent)
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            tempoKick = 3.5
            reseedEnvelope = max(reseedEnvelope, 0.5)   // brightness bloom
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)
        tempoKick = max(0, tempoKick - dt * 2.2)

        // Evolve slower than feels right — the tempo range is deliberately low.
        tempo = 0.35 + intensity * 0.3 + state.cpuPercent * 0.8 + state.stress * 1.2
            + tempoKick
        time += dt * tempo

        if state.modelJustLoaded {
            seedIndex = (seedIndex + 1) % Self.seeds.count
            colorAnchor += 1
            orbit = SIMD2(randomFloat(-0.3...0.3), randomFloat(-0.3...0.3))
            reseedEnvelope = 1
        }
        reseedEnvelope = max(0, reseedEnvelope - dt * 0.8)

        // Orbit one seed; amplitudes stay inside the verified chaotic band.
        let s = Self.seeds[seedIndex]
        params = SIMD4(
            s.x + 0.18 * sin(time * 0.117),
            s.y + 0.16 * sin(time * 0.093 + 2.1),
            s.z + 0.14 * sin(time * 0.081 + 4.3),
            s.w + 0.15 * sin(time * 0.127 + 1.2))

        iterations = Int(5000 + state.ramPercent * 5000)
        hotBudget = state.inferenceRunning
            ? Int(min(state.tokensPerSecond, 40)) * 3
            : 0
    }

    @inline(__always)
    private func clifford(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(sin(params.x * p.y) + params.z * cos(params.x * p.x),
              sin(params.y * p.x) + params.w * cos(params.y * p.y))
    }

    public func render(renderer: Renderer) {
        let state = renderer.currentState
        let stress = state.stress
        let scale = min(bounds.x, bounds.y) * 0.30
        let center = bounds * 0.5

        var cool = simd_mix(SIMD4<Float>(0.72, 0.76, 0.82, 1), theme.calmColor,
                            SIMD4(repeating: 0.22))
        var hot = simd_mix(theme.color(colorAnchor), theme.color(colorAnchor) * theme.color(colorAnchor),
                           SIMD4(repeating: 0.75))
        hot = simd_mix(hot, theme.stressColor(stress), SIMD4(repeating: stress * 0.4))
        hot = simd_mix(hot, theme.warningColor, SIMD4(repeating: state.swapPercent * 0.6))
        cool = simd_mix(cool, theme.warningColor, SIMD4(repeating: state.swapPercent * 0.3))

        var out: [Particle] = []
        out.reserveCapacity(iterations + hotBudget)

        var p = orbit
        let baseAlpha: Float = 0.045 + reseedEnvelope * 0.03
        for i in 0..<iterations {
            let next = clifford(p)
            let v = simd_length(next - p)          // velocity earns the color
            let heat = min(v * 0.55, 1)
            let isHot = i >= iterations - hotBudget
            var c = simd_mix(cool, hot, SIMD4(repeating: heat))
            c.w = isHot ? 0.9 : baseAlpha + heat * 0.025
            out.append(Particle(
                position: center + p * scale,
                color: c,
                size: isHot ? 1.7 : 1.0,
                glow: isHot ? 0.9 : heat * 0.12))
            p = next
        }
        orbit = p   // the orbit persists across frames — one continuous thread

        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (iterations: Int, hot: Int) { (iterations, hotBudget) }
}
