import Foundation
import simd

/// Plinko — falling glowing balls as memory allocations, pegs as memory
/// channels. Pressure creates traffic jams and stacking; swap activity spills
/// red overflow off the bottom of the board.
public final class PlinkoPlugin: AnimationPlugin {
    public let name = "Plinko"

    private struct Ball {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var colorIndex: Int
        var radius: Float
        var depth: Float = 0   // pseudo-3D lane the ball falls in
        var settled: Float = 0        // seconds spent nearly motionless (jam factor)
        var isOverflow: Bool = false  // swap spill: glows red, falls off-screen
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var worldMin = SIMD2<Float>(0, 0)   // real screen edges in scene space
    private var worldMax = SIMD2<Float>(800, 600)
    private var theme = Themes.glass

    /// Seconds a ball may sit still before fading out (so nothing piles up).
    private let settleDespawn: Float = 2.0
    private let fadeDuration: Float = 0.7
    private var pegs: [SIMD2<Float>] = []
    private var pegDepths: [Float] = []
    private var pegHeat: [Float] = []   // per-peg impact flash, decays fast
    private var pegRadius: Float = 5
    private var balls: [Ball] = []
    private var spawnAccumulator: Float = 0
    private var pegPulse: Float = 0

    private let maxBalls = 900

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        balls.removeAll(keepingCapacity: true)
        buildPegs()
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    /// Test hook: live ball positions (used by the self-test suite).
    public var testBallPositions: [SIMD2<Float>] { balls.map(\.position) }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func buildPegs() {
        pegs.removeAll()
        pegDepths.removeAll()
        let rows = 9
        let usableHeight = bounds.y * 0.62
        let top = bounds.y * 0.86
        let rowSpacing = usableHeight / Float(rows)
        pegRadius = max(3, min(bounds.x, bounds.y) * 0.006)
        for row in 0..<rows {
            let y = top - Float(row) * rowSpacing
            let count = 10 + (row % 2)
            let spacing = bounds.x * 0.8 / Float(count - 1)
            let startX = bounds.x * 0.1 + (row % 2 == 0 ? 0 : spacing * 0.5)
            for i in 0..<count {
                let x = startX + Float(i) * spacing
                if x < bounds.x * 0.95 {
                    pegs.append(SIMD2(x, y))
                    // Alternate rows sit at different depths for parallax.
                    pegDepths.append(row % 2 == 0 ? 0.35 : -0.18)
                }
            }
        }
        pegHeat = Array(repeating: 0, count: pegs.count)
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        pegPulse = max(0, pegPulse - dt * 2)
        if state.modelJustLoaded { pegPulse = 1 }
        for i in pegHeat.indices { pegHeat[i] = max(0, pegHeat[i] - dt * 3.5) }

        // Spawn: a steady drip that tracks RAM usage and the intensity
        // setting. The population target is what despawn drains against, so
        // flow stays continuous — never dump-everything-then-starve.
        let intensity = max(state.intensity, 0.05)
        let targetPopulation = min(Float(maxBalls),
            Float(maxBalls) * (0.10 + state.ramPercent * 0.70) * intensity)
        // Settled (fading) balls don't count toward the population — the
        // stream keeps flowing while the floor drains.
        let activeCount = balls.reduce(into: 0) { if $1.settled < 0.4 { $0 += 1 } }
        let deficit = max(0, targetPopulation - Float(activeCount))
        var spawnRate = min(deficit * 0.25, 40 * intensity)
            + (3 + state.ramPercent * 20) * intensity
        if state.inferenceRunning {
            spawnRate += min(state.tokensPerSecond, 60) * 0.5 * intensity
        }
        spawnAccumulator += spawnRate * dt
        while spawnAccumulator >= 1, Float(activeCount) < targetPopulation,
              balls.count < maxBalls {
            spawnAccumulator -= 1
            spawnBall(swapActive: state.swapPercent > 0.05)
        }

        // Stress makes the board FASTER and more chaotic, never sluggish:
        // gravity ramps up, balls get agitated jitter, bounces get violent.
        // Congestion still shows as pileups — but they're angry, vibrating ones.
        let congestion = state.memoryPressure
        let stress = state.stress
        let gravity: Float = -bounds.y * (0.55 + stress * 0.6)
        let jitter: Float = (stress * 180 + congestion * 120) * min(intensity, 1.5)

        for i in balls.indices {
            var b = balls[i]
            // Balls resting on the screen floor are exempt from jitter —
            // otherwise agitation resets their settle timer and they never
            // fade, clogging the population cap so spawning stops.
            let onFloor = b.position.y <= worldMin.y + b.radius + 1
            b.velocity.y += gravity * dt
            if jitter > 1, !onFloor {
                b.velocity += SIMD2(randomFloat(-jitter...jitter),
                                    randomFloat(-jitter...jitter)) * dt * 8
            }
            b.position += b.velocity * dt

            // Peg collisions.
            for (pi, peg) in pegs.enumerated() {
                let delta = b.position - peg
                let minDist = b.radius + pegRadius
                let distSq = simd_length_squared(delta)
                if distSq < minDist * minDist, distSq > 0.0001 {
                    let dist = sqrt(distSq)
                    let normal = delta / dist
                    b.position = peg + normal * minDist
                    let vn = simd_dot(b.velocity, normal)
                    if vn < 0 {
                        // Bounces get MORE energetic under stress.
                        let bounce: Float = 0.35 + stress * 0.45
                        b.velocity -= normal * vn * (1 + bounce)
                        b.velocity.x += randomFloat(-14...14) * (1 + stress * 2)
                        pegHeat[pi] = min(1, pegHeat[pi] + min(-vn / 300, 0.6))
                    }
                }
            }

            // Screen edges are the true walls and floor — even when the
            // board is scaled down, escapees stay trapped on the display.
            if b.position.x < worldMin.x + b.radius {
                b.position.x = worldMin.x + b.radius
                b.velocity.x = abs(b.velocity.x) * 0.5
            }
            if b.position.x > worldMax.x - b.radius {
                b.position.x = worldMax.x - b.radius
                b.velocity.x = -abs(b.velocity.x) * 0.5
            }
            if b.position.y < worldMin.y + b.radius {
                b.position.y = worldMin.y + b.radius
                b.velocity.y = abs(b.velocity.y) * 0.42   // bounce off the screen bottom
                b.velocity.x *= 0.94                       // rolling friction
            }

            // Jam/settle detection: floor-resting balls always accrue settle
            // time (so they reliably fade); elsewhere it's velocity-based.
            let resting = b.position.y <= worldMin.y + b.radius + 1
            if resting || simd_length_squared(b.velocity) < 200 {
                b.settled += dt
            } else {
                b.settled = 0
            }
            balls[i] = b
        }

        // Ball-vs-ball separation only matters when congested (cost scales with pressure).
        if congestion > 0.15 { resolveBallCollisions(strength: congestion) }

        // Swap: convert bottom-most balls into red overflow that drains away.
        if state.swapPercent > 0.05 {
            let overflowCount = Int(state.swapPercent * 40)
            var converted = 0
            for i in balls.indices where !balls[i].isOverflow && balls[i].position.y < bounds.y * 0.12 {
                balls[i].isOverflow = true
                balls[i].velocity.y = -bounds.y * 0.4
                converted += 1
                if converted >= overflowCount { break }
            }
        }

        // Despawn: once a ball has been still for a while it fades out and
        // vanishes so nothing piles up along the screen bottom.
        balls.removeAll { $0.settled > settleDespawn + fadeDuration }
    }

    private func spawnBall(swapActive: Bool) {
        let radius = randomFloat(2.2...4.2)
        balls.append(Ball(
            position: SIMD2(randomFloat(Float(bounds.x * 0.15)...Float(bounds.x * 0.85)),
                            bounds.y + radius * 2),
            velocity: SIMD2(randomFloat(-20...20), randomFloat(-40...(-10))),
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
            radius: radius,
            depth: randomFloat(-0.55...0.55)))
    }

    private func resolveBallCollisions(strength: Float) {
        // Spatial hash keyed by cell; one relaxation pass is enough visually.
        let cell: Float = 12
        var grid: [Int: [Int]] = [:]
        grid.reserveCapacity(balls.count)
        @inline(__always) func key(_ p: SIMD2<Float>) -> Int {
            Int(p.x / cell) &* 92_821 &+ Int(p.y / cell)
        }
        for (i, b) in balls.enumerated() { grid[key(b.position), default: []].append(i) }

        for i in balls.indices {
            let p = balls[i].position
            for dx in -1...1 {
                for dy in -1...1 {
                    let k = (Int(p.x / cell) + dx) &* 92_821 &+ (Int(p.y / cell) + dy)
                    guard let others = grid[k] else { continue }
                    for j in others where j > i {
                        let delta = balls[j].position - balls[i].position
                        let minDist = balls[i].radius + balls[j].radius
                        let distSq = simd_length_squared(delta)
                        if distSq < minDist * minDist, distSq > 0.0001 {
                            let dist = sqrt(distSq)
                            let push = (delta / dist) * (minDist - dist) * 0.5 * strength
                            balls[i].position -= push
                            balls[j].position += push
                        }
                    }
                }
            }
        }
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        out.reserveCapacity(pegs.count + balls.count)

        // Pegs: memory channels; flash on impact, pulse bright on model load.
        let pegColor = simd_mix(theme.color(1), theme.calmColor, SIMD4(repeating: pegPulse))
        for (i, peg) in pegs.enumerated() {
            let heat = i < pegHeat.count ? pegHeat[i] : 0
            var c = simd_mix(pegColor, theme.calmColor, SIMD4(repeating: heat))
            c.w = 0.55 + heat * 0.45
            out.append(Particle(position: peg, color: c,
                                size: pegRadius * (1 + heat * 0.5),
                                glow: 0.2 + pegPulse * 0.8 + heat,
                                depth: i < pegDepths.count ? pegDepths[i] : 0))
        }

        for b in balls {
            let jam = min(b.settled / 2, 1)
            var color = b.isOverflow
                ? theme.warningColor
                : simd_mix(theme.color(b.colorIndex), theme.warningColor,
                           SIMD4(repeating: jam * 0.6))
            // Fade out during the final second before despawn.
            let fade = min(max((settleDespawn + fadeDuration - b.settled) / fadeDuration, 0), 1)
            color.w *= 0.9 * fade
            let fast = simd_length_squared(b.velocity) > 40_000
            out.append(Particle(position: b.position, velocity: b.velocity, color: color,
                                size: b.radius * theme.particleScale,
                                glow: b.isOverflow ? 0.9 : 0.35 + jam * 0.3,
                                shape: fast ? .streak : .disc, depth: b.depth))
            // Bright inner core gives the glass-marble look.
            var core = color; core.w = min(1, color.w * 1.2)
            out.append(Particle(position: b.position, color: core,
                                size: b.radius * theme.particleScale * 0.45,
                                glow: 0.8, depth: b.depth))
        }
        renderer.submit(out)
    }
}
