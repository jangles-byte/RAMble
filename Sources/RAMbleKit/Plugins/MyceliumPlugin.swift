import Foundation
import simd

/// Mycelium — Physarum slime mould as the machine's hunger
/// (docs/mycelium-design.md). Thousands of blind agents deposit pheromone
/// trail, sense it ahead, and steer toward it; the feedback grows living
/// transport networks. Decay is the drama: calm holds a dense lace, stress
/// starves the web to filaments, relief regrows it.
///
/// Mapping:
/// - RAM        → colony population
/// - CPU        → foraging speed
/// - Stress     → trail decay (the network starves under pressure)
/// - Tokens     → fed agents burn colored and deposit double
/// - Swap       → the organism stains red
/// - Model load → the colony re-seeds and grows anew
public final class MyceliumPlugin: AnimationPlugin {
    public let name = "Mycelium"

    private struct Agent {
        var position: SIMD2<Float>
        var angle: Float
        var fed: Float = 0        // token heat, decays
        var colorIndex: Int = 0
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var agents: [Agent] = []
    private var trail: [Float] = []
    private var trailBack: [Float] = []
    private var cols = 1, rows = 1
    private var time: Float = 0
    private var tokenAccumulator: Float = 0
    private var loadEma: Float = 0
    private var surgeArmed = true

    private let cell: Float = 5
    private let sensorDist: Float = 19    // agents look FAR beyond their step
    private let sensorAngle: Float = 0.52 // ≈30°
    private let turn: Float = 0.61        // ≈35°/step
    private let maxAgents = 8000

    public init() {}

    // High persistence: the visible filaments are the accumulation buffer;
    // the CPU grid exists for sensing.
    public var preferredTrailPersistence: Float? { 0.93 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        cols = max(1, Int(bounds.x / cell) + 1)
        rows = max(1, Int(bounds.y / cell) + 1)
        trail = [Float](repeating: 0, count: cols * rows)
        trailBack = trail
        agents.removeAll(keepingCapacity: true)
        seedColony()
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    /// Seed in a disc with random headings, not a uniform field — the
    /// network must *grow outward*, and scouts must be able to leave it.
    private func seedColony() {
        let c = bounds * 0.5
        let r = min(bounds.x, bounds.y) * 0.34
        for _ in 0..<1200 {
            let a = randomFloat(0...(2 * .pi))
            let d = r * sqrt(randomFloat(0...1))
            agents.append(Agent(
                position: c + SIMD2(cos(a), sin(a)) * d,
                angle: randomFloat(0...(2 * .pi)),
                colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
        }
    }

    @inline(__always)
    private func sense(_ p: SIMD2<Float>) -> Float {
        // Toroidal, matching the wrapped movement — otherwise the screen
        // edge reads as a wall of trail and agents run laps along it.
        var x = Int(p.x / cell) % cols
        var y = Int(p.y / cell) % rows
        if x < 0 { x += cols }
        if y < 0 { y += rows }
        // Saturate: a mega-trail must not out-shout every other route, or
        // blobs become jails (the attractor-basin failure mode).
        return min(trail[y * cols + x], 25)
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let stepScale = dt * 60
        let intensity = max(state.intensity, 0.05)

        if state.modelJustLoaded {
            for i in trail.indices { trail[i] = 0 }
            agents.removeAll(keepingCapacity: true)
            seedColony()
        }

        // Population follows RAM, gradually.
        let target = min(Int(2600 + state.ramPercent * 5400), maxAgents)
        if agents.count < target {
            // New agents appear anywhere — cloning onto existing colonies
            // only amplifies clumps.
            for _ in 0..<min(24, target - agents.count) {
                agents.append(Agent(
                    position: SIMD2(randomFloat(0...bounds.x), randomFloat(0...bounds.y)),
                    angle: randomFloat(0...(2 * .pi)),
                    colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
            }
        } else if agents.count > target {
            agents.removeLast(min(24, agents.count - target))
        }
        guard !agents.isEmpty else { return }

        // Tokens feed the colony.
        if state.inferenceRunning {
            tokenAccumulator += min(state.tokensPerSecond, 10) * dt
            while tokenAccumulator >= 1 {
                tokenAccumulator -= 1
                let i = Int.random(in: 0..<agents.count)
                agents[i].fed = 1
                agents[i].colorIndex = Int.random(in: 0..<max(theme.palette.count, 1))
            }
        } else {
            tokenAccumulator = 0
        }

        // Surge response: a compute spike is a feeding frenzy — a wave of
        // agents lights up colored and doubles its deposit at once.
        let load = max(state.cpuPercent, state.gpuPercent)
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            for _ in 0..<min(60, agents.count) {
                let i = Int.random(in: 0..<agents.count)
                agents[i].fed = 1
                agents[i].colorIndex = Int.random(in: 0..<max(theme.palette.count, 1))
            }
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)

        let speed = (40 + state.cpuPercent * 50 + state.stress * 20)
            * (0.6 + intensity * 0.4)

        for i in agents.indices {
            var a = agents[i]
            let ahead = SIMD2(cos(a.angle), sin(a.angle))
            let left = SIMD2(cos(a.angle - sensorAngle), sin(a.angle - sensorAngle))
            let right = SIMD2(cos(a.angle + sensorAngle), sin(a.angle + sensorAngle))
            let f = sense(a.position + ahead * sensorDist)
            let fl = sense(a.position + left * sensorDist)
            let fr = sense(a.position + right * sensorDist)

            if f > fl, f > fr {
                // hold course
            } else if fl > fr {
                a.angle -= turn * randomFloat(0...1) * stepScale
            } else if fr > fl {
                a.angle += turn * randomFloat(0...1) * stepScale
            } else {
                a.angle += (randomFloat(0...1) - 0.5) * 2 * turn * stepScale
            }
            // Persistent wander so highways stay alive but never become jails.
            a.angle += (randomFloat(0...1) - 0.5) * 0.22 * stepScale

            a.position += SIMD2(cos(a.angle), sin(a.angle)) * speed * dt
            // Wrap at edges.
            if a.position.x < 0 { a.position.x += bounds.x }
            if a.position.x >= bounds.x { a.position.x -= bounds.x }
            if a.position.y < 0 { a.position.y += bounds.y }
            if a.position.y >= bounds.y { a.position.y -= bounds.y }

            let x = Int(a.position.x / cell), y = Int(a.position.y / cell)
            if x >= 0, x < cols, y >= 0, y < rows {
                trail[y * cols + x] += 3.0 * stepScale * (a.fed > 0 ? 2 : 1)
            }
            a.fed = max(0, a.fed - dt * 0.7)
            agents[i] = a
        }

        // Blur + decay: decay is the whole piece — stress starves the web.
        let decay = pow(0.93 - state.stress * 0.03, stepScale)
        for y in 0..<rows {
            for x in 0..<cols {
                var sum: Float = 0
                var n: Float = 0
                for dy in max(y - 1, 0)...min(y + 1, rows - 1) {
                    for dx in max(x - 1, 0)...min(x + 1, cols - 1) {
                        sum += trail[dy * cols + dx]
                        n += 1
                    }
                }
                trailBack[y * cols + x] = (sum / n) * decay
            }
        }
        swap(&trail, &trailBack)
    }

    // MARK: - Render

    private func deepen(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var d = simd_mix(c, c * c, SIMD4(repeating: 0.75))
        d.w = c.w
        return d
    }

    public func render(renderer: Renderer) {
        guard !agents.isEmpty else { return }
        let state = renderer.currentState
        var out: [Particle] = []
        out.reserveCapacity(agents.count)

        var ash = simd_mix(SIMD4<Float>(0.72, 0.76, 0.82, 1), theme.calmColor,
                           SIMD4(repeating: 0.22))
        ash = simd_mix(ash, theme.warningColor, SIMD4(repeating: state.swapPercent * 0.5))
        var accent = deepen(theme.color(1))
        accent = simd_mix(accent, theme.warningColor, SIMD4(repeating: state.swapPercent * 0.5))

        for a in agents {
            if a.fed > 0 {
                var c = deepen(theme.color(a.colorIndex))
                c.w = min(a.fed * 2, 1)
                out.append(Particle(position: a.position, color: c, size: 1.6,
                                    glow: 1.0 * min(a.fed * 2, 1)))
            } else {
                // Concentration earns the color: trunk routes heat up.
                let heat = min(sense(a.position) / 34, 1)
                var c = simd_mix(ash, accent, SIMD4(repeating: heat))
                c.w = 0.16 + heat * 0.2
                out.append(Particle(position: a.position, color: c, size: 1.0,
                                    glow: heat * 0.35))
            }
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (agents: Int, gridCells: Int) { (agents.count, trail.count) }
}
