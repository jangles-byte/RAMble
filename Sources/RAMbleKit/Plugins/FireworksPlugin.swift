import Foundation
import simd

/// Fireworks — a valley celebration that scales with the machine's effort
/// (docs/fireworks-design.md). Rockets rise from behind an invisible
/// treeline silhouette; calm gets one small low shell every little while,
/// and sustained load tips into volleys, height, and grand-finale variety.
/// The silhouette is never drawn — it appears only as negative space
/// against the sky-glow of the biggest bursts.
///
/// Mapping:
/// - Drive (stress/CPU/GPU) → launch rate, apex height, burst size, variety
/// - Tokens                 → extra shells in step with generation
/// - Generation finish      → one enormous golden willow
/// - Swap                   → shells stain red
/// - Model load / surge     → an immediate volley
public final class FireworksPlugin: AnimationPlugin {
    public let name = "Fireworks"

    private enum BurstKind: CaseIterable {
        case peony, ring, willow, crackle
    }

    private struct Rocket {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var apexY: Float
        var colorIndex: Int
        var kind: BurstKind
        var sizeScale: Float
        var trailAccumulator: Float = 0
    }

    private struct Spark {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var maxLife: Float
        var colorIndex: Int
        var isWillow: Bool = false
        var isCrackleSeed: Bool = false  // pops into white flashes on death
        var isFlash: Bool = false        // the white crackle pop itself
        var redStain: Float = 0
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var rockets: [Rocket] = []
    private var sparks: [Spark] = []
    private var time: Float = 0
    private var launchAccumulator: Float = 0
    private var tokenAccumulator: Float = 0
    private var skyGlow: Float = 0            // recent-burst flash, decays
    private var treePhase: (Float, Float, Float) = (0, 0, 0)
    private var loadEma: Float = 0
    private var surgeArmed = true

    private let gravity: Float = -300
    private let maxSparks = 2200
    private let maxRockets = 24

    public init() {}

    public var preferredTrailPersistence: Float? { 0.75 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        rockets.removeAll(keepingCapacity: true)
        sparks.removeAll(keepingCapacity: true)
        treePhase = (randomFloat(0...(2 * .pi)), randomFloat(0...(2 * .pi)),
                     randomFloat(0...(2 * .pi)))
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    /// The invisible silhouette: jagged treeline height at x. Never drawn —
    /// it exists only as the line below which nothing is rendered.
    private func treeHeight(_ x: Float) -> Float {
        let w = max(bounds.x, 1)
        let base = bounds.y * 0.10
        return base
            + sin(x / w * 19 + treePhase.0) * bounds.y * 0.028
            + sin(x / w * 47 + treePhase.1) * bounds.y * 0.018
            + sin(x / w * 9 + treePhase.2) * bounds.y * 0.022
    }

    // MARK: - Simulation

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)

        // Drive: how celebratory the sky is. Stress leads; raw CPU/GPU keep
        // it honest when stress lags a burst of work.
        let load = max(state.cpuPercent, state.gpuPercent)
        let drive = min(max(state.stress, load * 0.85), 1)

        // Launch cadence: a lazy shell every little while when calm; volleys
        // as the machine digs in. Finale above drive ~0.8.
        var rate = (0.12 + pow(drive, 1.5) * 3.2) * intensity
        if state.inferenceRunning {
            tokenAccumulator += min(state.tokensPerSecond, 12) * dt * 0.25
            while tokenAccumulator >= 1 {
                tokenAccumulator -= 1
                launch(drive: drive, swap: state.swapPercent)
            }
        } else {
            tokenAccumulator = 0
        }
        if drive > 0.8, Int(time * 2) % 3 == 0 { rate *= 1.6 }   // finale pulses
        launchAccumulator += rate * dt
        while launchAccumulator >= 1 {
            launchAccumulator -= 1
            let volley = drive > 0.8 ? Int.random(in: 2...4) : 1
            for _ in 0..<volley { launch(drive: drive, swap: state.swapPercent) }
        }

        // Events.
        if state.modelJustLoaded {
            for _ in 0..<5 { launch(drive: max(drive, 0.7), swap: state.swapPercent) }
        }
        if state.generationJustFinished {
            launch(drive: 1, swap: state.swapPercent, forceKind: .willow, forceScale: 1.6)
        }
        // Surge response: a compute spike answers with an immediate volley.
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            for _ in 0..<3 { launch(drive: max(drive, 0.6), swap: state.swapPercent) }
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)

        skyGlow = max(0, skyGlow - dt * 1.6)

        // Rockets climb; at apex they burst.
        var burst: [Rocket] = []
        for i in rockets.indices {
            rockets[i].velocity.y += gravity * 0.25 * dt   // gentle deceleration
            rockets[i].position += rockets[i].velocity * dt
            rockets[i].trailAccumulator += dt * 40
            // Shed a faint trail spark now and then.
            while rockets[i].trailAccumulator >= 1, sparks.count < maxSparks {
                rockets[i].trailAccumulator -= 1
                sparks.append(Spark(
                    position: rockets[i].position + SIMD2(randomFloat(-1...1), randomFloat(-1...1)),
                    velocity: SIMD2(randomFloat(-6...6), randomFloat(-30 ... -10)),
                    life: randomFloat(0.15...0.35), maxLife: 0.35,
                    colorIndex: rockets[i].colorIndex))
            }
            if rockets[i].position.y >= rockets[i].apexY || rockets[i].velocity.y < 40 {
                burst.append(rockets[i])
            }
        }
        rockets.removeAll { $0.position.y >= $0.apexY || $0.velocity.y < 40 }
        for r in burst { explode(r, swap: state.swapPercent) }

        // Sparks fall, drag, and die; crackle seeds pop into white on death.
        var popped: [Spark] = []
        for i in sparks.indices {
            let drag: Float = sparks[i].isWillow ? 0.55 : 1.1
            sparks[i].velocity *= max(0, 1 - dt * drag)
            sparks[i].velocity.y += gravity * (sparks[i].isWillow ? 1.15 : 0.8) * dt
            sparks[i].position += sparks[i].velocity * dt
            sparks[i].life -= dt
            if sparks[i].life <= 0, sparks[i].isCrackleSeed { popped.append(sparks[i]) }
        }
        sparks.removeAll { $0.life <= 0 || $0.position.y < -20 }
        for seed in popped where sparks.count + 2 <= maxSparks {
            for _ in 0..<2 {
                sparks.append(Spark(
                    position: seed.position + SIMD2(randomFloat(-4...4), randomFloat(-4...4)),
                    velocity: SIMD2(randomFloat(-40...40), randomFloat(-30...50)),
                    life: randomFloat(0.10...0.22), maxLife: 0.22,
                    colorIndex: seed.colorIndex, isFlash: true))
            }
        }
    }

    private func launch(drive: Float, swap: Float,
                        forceKind: BurstKind? = nil, forceScale: Float? = nil) {
        guard rockets.count < maxRockets, bounds.x > 64, bounds.y > 64 else { return }
        let x = randomFloat(bounds.x * 0.08 ... bounds.x * 0.92)

        // Calm shells stay low over the trees; the finale stacks them high.
        let apexFrac = 0.16 + randomFloat(0...0.10) + drive * (0.30 + randomFloat(0...0.28))
        let apexY = bounds.y * min(apexFrac, 0.88)

        // Repertoire weights shift with drive: calm favors small peonies.
        let kind: BurstKind
        if let forced = forceKind {
            kind = forced
        } else {
            let roll = randomFloat(0...1)
            if drive < 0.35 {
                kind = roll < 0.8 ? .peony : (roll < 0.92 ? .willow : .crackle)
            } else if roll < 0.5 {
                kind = .peony
            } else if roll < 0.7 {
                kind = .crackle
            } else if roll < 0.88 {
                kind = .willow
            } else {
                kind = .ring
            }
        }

        // Rise time from ballistics: v so the rocket runs out near apex.
        let rise = sqrt(2 * -gravity * 0.25 * apexY) + apexY * 0.9
        rockets.append(Rocket(
            position: SIMD2(x, treeHeight(x) - 12),   // from behind the trees
            velocity: SIMD2(randomFloat(-14...14), rise),
            apexY: apexY,
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
            kind: kind,
            sizeScale: forceScale ?? (0.55 + drive * 0.75 + randomFloat(0...0.2))))
    }

    private func explode(_ r: Rocket, swap: Float) {
        skyGlow = min(skyGlow + 0.35 * r.sizeScale, 1)
        let s = r.sizeScale
        let stain = min(swap * 1.4, 1) * (randomFloat(0...1) < swap ? 1 : 0.3)

        func add(_ spark: Spark) {
            if sparks.count < maxSparks { sparks.append(spark) }
        }

        switch r.kind {
        case .peony:
            let n = Int(60 * s) + 24
            for _ in 0..<n {
                let ang = randomFloat(0...(2 * .pi))
                let spd = randomFloat(90...240) * s
                add(Spark(position: r.position,
                          velocity: SIMD2(cos(ang), sin(ang)) * spd,
                          life: randomFloat(0.8...1.5), maxLife: 1.5,
                          colorIndex: r.colorIndex, redStain: stain))
            }
        case .ring:
            let n = Int(50 * s) + 26
            let spd = randomFloat(150...210) * s
            let tilt = randomFloat(0.55...1.0)      // squashed = 3D tilt
            for k in 0..<n {
                let ang = Float(k) / Float(n) * 2 * .pi
                add(Spark(position: r.position,
                          velocity: SIMD2(cos(ang), sin(ang) * tilt) * spd,
                          life: randomFloat(1.0...1.4), maxLife: 1.4,
                          colorIndex: r.colorIndex, redStain: stain))
            }
        case .willow:
            let n = Int(46 * s) + 18
            for _ in 0..<n {
                let ang = randomFloat(0...(2 * .pi))
                let spd = randomFloat(60...150) * s
                add(Spark(position: r.position,
                          velocity: SIMD2(cos(ang), sin(ang)) * spd,
                          life: randomFloat(1.6...2.6), maxLife: 2.6,
                          colorIndex: r.colorIndex, isWillow: true, redStain: stain))
            }
        case .crackle:
            let n = Int(40 * s) + 16
            for _ in 0..<n {
                let ang = randomFloat(0...(2 * .pi))
                let spd = randomFloat(80...190) * s
                add(Spark(position: r.position,
                          velocity: SIMD2(cos(ang), sin(ang)) * spd,
                          life: randomFloat(0.5...1.0), maxLife: 1.0,
                          colorIndex: r.colorIndex,
                          isCrackleSeed: true, redStain: stain))
            }
        }
    }

    // MARK: - Render

    private func deepen(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var d = simd_mix(c, c * c, SIMD4(repeating: 0.75))
        d.w = c.w
        return d
    }

    /// Warm gold for willows, whatever the theme — gunpowder is gunpowder.
    private var gold: SIMD4<Float> {
        simd_mix(SIMD4(1.0, 0.82, 0.45, 1), theme.calmColor, SIMD4(repeating: 0.15))
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        out.reserveCapacity(rockets.count * 2 + sparks.count + 100)

        // Sky-glow above the treeline during big bursts: the silhouette
        // appears as negative space, then fades back into the dark.
        if skyGlow > 0.02, bounds.x > 64 {
            let n = 70
            var gc = deepen(theme.calmColor)
            gc.w = skyGlow * 0.030
            for k in 0..<n {
                let x = (Float(k) + 0.5) / Float(n) * bounds.x
                // Large soft overlapping discs: a diffuse glow band, so the
                // silhouette reads as an edge, not a string of lights.
                out.append(Particle(position: SIMD2(x, treeHeight(x) + 16),
                                    color: gc, size: 16, glow: skyGlow * 0.12))
            }
        }

        // Rockets: small hot streaks climbing.
        for r in rockets where r.position.y > treeHeight(r.position.x) {
            var c = deepen(theme.color(r.colorIndex))
            c.w = 0.9
            out.append(Particle(position: r.position, velocity: r.velocity * 0.35,
                                color: c, size: 1.6, glow: 0.7, shape: .streak))
        }

        // Sparks: occluded by the invisible treeline — falling embers die
        // into the silhouette, which is what makes it read as *trees*.
        for sp in sparks where sp.position.y > treeHeight(sp.position.x) {
            let lifeT = max(sp.life / sp.maxLife, 0)
            var c: SIMD4<Float>
            if sp.isFlash {
                c = SIMD4(1, 1, 1, 1)
            } else if sp.isWillow {
                c = deepen(gold)
            } else {
                c = deepen(theme.color(sp.colorIndex))
            }
            c = simd_mix(c, theme.warningColor, SIMD4(repeating: sp.redStain * 0.7))
            // Envelope: quick in, slow fade — nothing pops out of existence.
            c.w = (sp.isFlash ? 1.0 : 0.9) * min(lifeT * 3, 1)
            out.append(Particle(position: sp.position, velocity: sp.velocity,
                                color: c,
                                size: sp.isFlash ? 1.8 : (sp.isWillow ? 1.5 : 1.7) * min(lifeT * 2, 1) + 0.5,
                                glow: (sp.isFlash ? 1.3 : 0.55) * lifeT,
                                shape: .streak))
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (rockets: Int, sparks: Int) { (rockets.count, sparks.count) }
}
