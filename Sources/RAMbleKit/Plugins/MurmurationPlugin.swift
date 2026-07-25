import Foundation
import simd

/// Murmuration — boids flocking as the system's nerves
/// (docs/murmuration-design.md). Hundreds of silver streaked birds wheel
/// through the dark; knots in the flock glow with crowd density. Pressure
/// is fear: stress frays the murmuration into nervous scatter, and swap
/// summons a red predator that hunts the flock open.
///
/// Mapping:
/// - RAM      → flock population
/// - Stress   → fear: separation overpowers alignment, speed rises
/// - Swap     → the predator appears and hunts
/// - Tokens   → leader birds ignite in palette color, one per token
/// - Model load → a bang startles the whole flock
public final class MurmurationPlugin: AnimationPlugin {
    public let name = "Murmuration"

    private struct Boid {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var z: Float
        var leaderLife: Float = 0
        var colorIndex: Int = 0
        var neighbors: Float = 0
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var worldMin = SIMD2<Float>(0, 0)
    private var worldMax = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var boids: [Boid] = []
    private var time: Float = 0
    private var tokenAccumulator: Float = 0
    private var predatorStrength: Float = 0   // smoothed swap presence
    private var loadEma: Float = 0
    private var surgeArmed = true

    // Radii from the Atelier boids reference: separation well under
    // alignment, cohesion outermost. Grid cell = cohesion radius.
    // Scaled ×1.6 from the reference's canvas-sized radii — on a full-screen
    // field the smaller neighborhoods fragment into micro-flocks.
    private let sepR2: Float = 26 * 26
    private let aliR2: Float = 64 * 64
    private let cohR2: Float = 88 * 88
    private let cell: Float = 90
    private let maxBoids = 1000

    public init() {}

    public var preferredTrailPersistence: Float? { 0.6 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        boids.removeAll(keepingCapacity: true)
        // Seed as a loose disc mid-screen so the flock forms rather than
        // starting as uniform noise.
        let c = bounds * 0.5
        let r = min(bounds.x, bounds.y) * 0.25
        for _ in 0..<300 { spawnBoid(near: c, radius: r) }
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func spawnBoid(near c: SIMD2<Float>, radius: Float) {
        let ang = randomFloat(0...(2 * .pi))
        let dist = radius * sqrt(randomFloat(0...1))
        let heading = randomFloat(0...(2 * .pi))
        boids.append(Boid(
            position: c + SIMD2(cos(ang), sin(ang)) * dist,
            velocity: SIMD2(cos(heading), sin(heading)) * randomFloat(70...120),
            z: randomFloat(-0.35...0.35),
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
    }

    /// The predator roams the field on a slow Lissajous path.
    private func predatorPosition() -> SIMD2<Float> {
        let w = worldMax - worldMin
        return worldMin + SIMD2(
            w.x * (0.5 + 0.42 * sin(time * 0.13)),
            w.y * (0.5 + 0.38 * sin(time * 0.17 + 1.3)))
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)
        let stress = state.stress

        // Population follows RAM, adjusted gradually so the flock grows and
        // thins rather than popping.
        let target = min(Int(240 + state.ramPercent * 760), maxBoids)
        let delta = min(2, abs(target - boids.count))
        if boids.count < target {
            let c = boids.randomElement()?.position ?? bounds * 0.5
            for _ in 0..<delta { spawnBoid(near: c, radius: 60) }
        } else if boids.count > target {
            boids.removeLast(delta)
        }
        guard !boids.isEmpty else { return }

        // Leaders: one bird ignites per token (capped so they stay events).
        if state.inferenceRunning {
            tokenAccumulator += min(state.tokensPerSecond, 8) * dt
            while tokenAccumulator >= 1 {
                tokenAccumulator -= 1
                let i = Int.random(in: 0..<boids.count)
                boids[i].leaderLife = 1.3
                boids[i].colorIndex = Int.random(in: 0..<max(theme.palette.count, 1))
            }
        } else {
            tokenAccumulator = 0
        }

        // A model load startles the flock.
        if state.modelJustLoaded {
            for i in boids.indices {
                let ang = randomFloat(0...(2 * .pi))
                boids[i].velocity += SIMD2(cos(ang), sin(ang)) * randomFloat(120...260)
            }
        }

        // Surge response: a sudden compute spike is a gunshot in the valley —
        // the whole flock startles at once, then re-forms.
        let load = max(state.cpuPercent, state.gpuPercent)
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            for i in boids.indices {
                let ang = randomFloat(0...(2 * .pi))
                boids[i].velocity += SIMD2(cos(ang), sin(ang)) * randomFloat(80...180)
            }
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)

        predatorStrength += (min(state.swapPercent * 12, 1) - predatorStrength)
            * min(1, dt * 2)
        let predator = predatorPosition()

        // Spatial hash over the world.
        let world = worldMax - worldMin
        let cols = max(1, Int(world.x / cell) + 1)
        let rows = max(1, Int(world.y / cell) + 1)
        var grid = [[Int]](repeating: [], count: cols * rows)
        @inline(__always) func cellIndex(_ p: SIMD2<Float>) -> (Int, Int) {
            (min(max(Int((p.x - worldMin.x) / cell), 0), cols - 1),
             min(max(Int((p.y - worldMin.y) / cell), 0), rows - 1))
        }
        for (i, b) in boids.enumerated() {
            let (cx, cy) = cellIndex(b.position)
            grid[cy * cols + cx].append(i)
        }

        // Fear reweights the three rules: separation up, alignment down.
        let wSep: Float = 1.5 * (1 + stress * 1.5)
        let wAli: Float = 1.0 * max(0.3, 1 - stress * 0.6)
        let wCoh: Float = 0.9 * (1 - stress * 0.4)
        let minSpeed: Float = 60 + stress * 40
        let maxSpeed: Float = (140 + stress * 120) * (0.7 + intensity * 0.3)

        var newBoids = boids
        for i in boids.indices {
            let b = boids[i]
            var sep = SIMD2<Float>(0, 0)
            var avgVel = SIMD2<Float>(0, 0)
            var avgPos = SIMD2<Float>(0, 0)
            var aliCount: Float = 0
            var cohCount: Float = 0

            let (cx, cy) = cellIndex(b.position)
            for gy in max(cy - 1, 0)...min(cy + 1, rows - 1) {
                for gx in max(cx - 1, 0)...min(cx + 1, cols - 1) {
                    for j in grid[gy * cols + gx] where j != i {
                        let d = b.position - boids[j].position
                        let d2 = simd_length_squared(d)
                        guard d2 < cohR2, d2 > 0.01 else { continue }
                        if d2 < sepR2 { sep += d / d2 }
                        if d2 < aliR2 { avgVel += boids[j].velocity; aliCount += 1 }
                        avgPos += boids[j].position; cohCount += 1
                    }
                }
            }

            var force = sep * wSep * 60
            if aliCount > 0 { force += (avgVel / aliCount - b.velocity) * 0.09 * wAli * 60 }
            if cohCount > 0 { force += (avgPos / cohCount - b.position) * 0.035 * wCoh * 60 }

            // Flee the predator.
            if predatorStrength > 0.01 {
                let d = b.position - predator
                let d2 = simd_length_squared(d)
                if d2 < 130 * 130, d2 > 1 {
                    force += (d / d2) * 3200 * predatorStrength
                }
            }

            var v = b.velocity + force * dt
            let speed = max(simd_length(v), 0.001)
            let lo = b.leaderLife > 0 ? minSpeed * 1.4 : minSpeed
            let hi = b.leaderLife > 0 ? maxSpeed * 1.5 : maxSpeed
            v *= min(max(speed, lo), hi) / speed

            var nb = b
            nb.velocity = v
            nb.position = b.position + v * dt
            // Wrap, never bounce — bouncing reads as a container.
            if nb.position.x < worldMin.x - 10 { nb.position.x = worldMax.x + 10 }
            if nb.position.x > worldMax.x + 10 { nb.position.x = worldMin.x - 10 }
            if nb.position.y < worldMin.y - 10 { nb.position.y = worldMax.y + 10 }
            if nb.position.y > worldMax.y + 10 { nb.position.y = worldMin.y - 10 }
            nb.leaderLife = max(0, b.leaderLife - dt)
            nb.neighbors = cohCount
            newBoids[i] = nb
        }
        boids = newBoids
    }

    // MARK: - Render

    private func deepen(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var d = simd_mix(c, c * c, SIMD4(repeating: 0.75))
        d.w = c.w
        return d
    }

    public func render(renderer: Renderer) {
        guard !boids.isEmpty else { return }
        let stress = renderer.currentState.stress
        var out: [Particle] = []
        out.reserveCapacity(boids.count + 4)

        var ash = simd_mix(SIMD4<Float>(0.72, 0.76, 0.82, 1), theme.calmColor,
                           SIMD4(repeating: 0.22))
        ash = simd_mix(ash, theme.stressColor(stress), SIMD4(repeating: stress * 0.3))

        for b in boids {
            // Crowd earns the light: knots glow, loners stay faint.
            let density = min(b.neighbors, 12) / 12
            if b.leaderLife > 0 {
                var c = deepen(theme.color(b.colorIndex))
                c.w = min(b.leaderLife * 2, 1)
                out.append(Particle(position: b.position, velocity: b.velocity,
                                    color: c, size: 2.4 * theme.particleScale,
                                    glow: 1.2 * min(b.leaderLife * 2, 1),
                                    shape: .streak, depth: b.z))
            } else {
                var c = ash
                c.w = 0.55 + density * 0.4
                out.append(Particle(position: b.position, velocity: b.velocity,
                                    color: c, size: 1.8 * theme.particleScale,
                                    glow: 0.1 + density * 0.5,
                                    shape: .streak, depth: b.z))
            }
        }

        // The predator: a red presence, unmistakable.
        if predatorStrength > 0.01 {
            let p = predatorPosition()
            var halo = theme.warningColor
            halo.w = 0.10 * predatorStrength
            out.append(Particle(position: p, color: halo, size: 26,
                                glow: 0.5 * predatorStrength))
            var core = theme.warningColor
            core.w = 0.9 * predatorStrength
            out.append(Particle(position: p,
                                velocity: SIMD2(cos(time * 0.9), sin(time * 0.7)) * 40,
                                color: core, size: 4.5, glow: 1.2 * predatorStrength,
                                shape: .streak))
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (boids: Int, leaders: Int) {
        (boids.count, boids.filter { $0.leaderLife > 0 }.count)
    }
}
