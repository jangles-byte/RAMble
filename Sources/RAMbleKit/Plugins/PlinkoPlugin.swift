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
        var settled: Float = 0        // seconds spent nearly motionless (jam factor)
        var isOverflow: Bool = false  // swap spill: glows red, falls off-screen
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var pegs: [SIMD2<Float>] = []
    private var pegRadius: Float = 5
    private var balls: [Ball] = []
    private var spawnAccumulator: Float = 0
    private var pegPulse: Float = 0

    private let maxBalls = 900

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        balls.removeAll(keepingCapacity: true)
        buildPegs()
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func buildPegs() {
        pegs.removeAll()
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
                if x < bounds.x * 0.95 { pegs.append(SIMD2(x, y)) }
            }
        }
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        pegPulse = max(0, pegPulse - dt * 2)
        if state.modelJustLoaded { pegPulse = 1 }

        // Spawn rate follows RAM usage; inference adds a steady token drizzle.
        let targetPopulation = Float(maxBalls) * (0.12 + state.ramPercent * 0.88)
        let deficit = max(0, targetPopulation - Float(balls.count))
        var spawnRate = deficit * 0.6 + state.ramPercent * 30
        if state.inferenceRunning { spawnRate += min(state.tokensPerSecond, 60) }
        spawnAccumulator += spawnRate * dt
        while spawnAccumulator >= 1, balls.count < maxBalls {
            spawnAccumulator -= 1
            spawnBall(swapActive: state.swapPercent > 0.05)
        }

        // Congestion: pressure adds drag, making balls pile up between pegs.
        let congestion = state.memoryPressure
        let gravity: Float = -bounds.y * (0.55 - congestion * 0.35)
        let drag: Float = 1 - min(0.9, congestion * 2.2) * dt

        for i in balls.indices {
            var b = balls[i]
            b.velocity.y += gravity * dt
            b.velocity *= drag
            b.position += b.velocity * dt

            // Peg collisions.
            for peg in pegs {
                let delta = b.position - peg
                let minDist = b.radius + pegRadius
                let distSq = simd_length_squared(delta)
                if distSq < minDist * minDist, distSq > 0.0001 {
                    let dist = sqrt(distSq)
                    let normal = delta / dist
                    b.position = peg + normal * minDist
                    let vn = simd_dot(b.velocity, normal)
                    if vn < 0 {
                        let bounce: Float = 0.35 + (1 - congestion) * 0.25
                        b.velocity -= normal * vn * (1 + bounce)
                        b.velocity.x += randomFloat(-14...14)
                    }
                }
            }

            // Walls.
            if b.position.x < b.radius { b.position.x = b.radius; b.velocity.x = abs(b.velocity.x) * 0.5 }
            if b.position.x > bounds.x - b.radius {
                b.position.x = bounds.x - b.radius
                b.velocity.x = -abs(b.velocity.x) * 0.5
            }

            // Jam detection: slow-moving balls under pressure stack up.
            if simd_length_squared(b.velocity) < 200 { b.settled += dt } else { b.settled = 0 }
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

        // Retire balls that fell off (or recycle settled floor balls when calm).
        let floorY: Float = bounds.y * 0.04
        balls.removeAll { b in
            if b.position.y < -b.radius * 4 { return true }
            if !b.isOverflow && b.position.y < floorY && b.settled > lerp(6, 1.5, 1 - congestion) {
                return true
            }
            return false
        }

        // Floor: non-overflow balls rest on the bottom edge and stack.
        for i in balls.indices where !balls[i].isOverflow {
            if balls[i].position.y < floorY {
                balls[i].position.y = floorY
                balls[i].velocity.y = abs(balls[i].velocity.y) * 0.2
            }
        }
    }

    private func spawnBall(swapActive: Bool) {
        let radius = randomFloat(2.2...4.2)
        balls.append(Ball(
            position: SIMD2(randomFloat(Float(bounds.x * 0.15)...Float(bounds.x * 0.85)),
                            bounds.y + radius * 2),
            velocity: SIMD2(randomFloat(-20...20), randomFloat(-40...(-10))),
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
            radius: radius))
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

        // Pegs: memory channels; pulse bright on model load.
        let pegColor = simd_mix(theme.color(1), theme.calmColor, SIMD4(repeating: pegPulse))
        for peg in pegs {
            out.append(Particle(position: peg, color: pegColor * SIMD4(1, 1, 1, 0.55),
                                size: pegRadius, glow: 0.2 + pegPulse * 0.8))
        }

        for b in balls {
            let jam = min(b.settled / 2, 1)
            var color = b.isOverflow
                ? theme.warningColor
                : simd_mix(theme.color(b.colorIndex), theme.warningColor,
                           SIMD4(repeating: jam * 0.6))
            color.w *= 0.9
            out.append(Particle(position: b.position, velocity: b.velocity, color: color,
                                size: b.radius * theme.particleScale,
                                glow: b.isOverflow ? 0.9 : 0.3 + jam * 0.3,
                                shape: simd_length_squared(b.velocity) > 40_000 ? .streak : .disc))
        }
        renderer.submit(out)
    }
}
