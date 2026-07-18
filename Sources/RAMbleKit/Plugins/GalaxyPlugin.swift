import Foundation
import simd

/// Galaxy — thousands of stars orbit a gravitational center. Pressure deepens
/// the well and drags orbits inward; heavy swap collapses the core into a
/// black hole that visibly swallows stars. Token generation pulses the core.
public final class GalaxyPlugin: AnimationPlugin {
    public let name = "Galaxy"

    private struct Star {
        var angle: Float
        var radius: Float          // current orbit radius
        var baseRadius: Float      // relaxed orbit radius
        var speed: Float           // angular velocity at base radius
        var colorIndex: Int
        var size: Float
        var inclination: Float     // ellipse squash for depth illusion
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var stars: [Star] = []
    private var corePulse: Float = 0
    private var blackHole: Float = 0    // 0…1 how formed the black hole is
    private var time: Float = 0

    private let starCount = 2600

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        stars.removeAll(keepingCapacity: true)
        stars.reserveCapacity(starCount)
        let maxRadius = min(bounds.x, bounds.y) * 0.42
        for _ in 0..<starCount {
            // Density falls off with radius, like a disc galaxy.
            let r = maxRadius * (0.12 + 0.88 * pow(randomFloat(0...1), 0.6))
            stars.append(Star(
                angle: randomFloat(0...(2 * .pi)),
                radius: r,
                baseRadius: r,
                speed: (0.25 + 40 / max(r, 8)) * (Bool.random() ? 1 : 1),  // Keplerian-ish
                colorIndex: Int.random(in: 0..<8),
                size: randomFloat(0.8...2.4),
                inclination: randomFloat(0.55...0.75)))
        }
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt

        corePulse = max(0, corePulse - dt * 1.5)
        if state.modelJustLoaded { corePulse = 1 }
        if state.inferenceRunning {
            corePulse = max(corePulse, 0.3 + 0.2 * sin(time * 6))
        }
        if state.generationJustFinished { corePulse = 0.8 }

        // Black hole forms with swap; dissolves when swap drains.
        let targetHole = state.swapPercent > 0.05 ? min(1, state.swapPercent * 1.6) : 0
        blackHole += (targetHole - blackHole) * min(1, dt * 0.8)

        // Gravity: memory pressure pulls orbits toward the core.
        let pull = state.memoryPressure * 0.6 + blackHole * 0.8
        // Stress cranks the whole galaxy up: faster sweeps + chaotic wobble.
        let speedBoost = 1 + state.cpuPercent * 1.2 + state.gpuPercent * 0.8
            + state.stress * 3.5
        let turbulence = state.stress * state.stress * 14

        let minRadius = min(bounds.x, bounds.y) * 0.02
        for i in stars.indices {
            var s = stars[i]
            let target = s.baseRadius * (1 - pull * 0.85)
            s.radius += (target - s.radius) * dt * (0.6 + pull * 2)
            // Spiral inward under the black hole; captured stars respawn outside.
            if blackHole > 0.1 {
                s.radius -= s.radius * blackHole * dt * 0.35
                if s.radius < minRadius {
                    s.radius = s.baseRadius
                    s.angle = randomFloat(0...(2 * .pi))
                }
            }
            // Conserve a hint of angular momentum: tighter orbit → faster sweep.
            let momentum = max(s.baseRadius / max(s.radius, 1), 1)
            s.angle += s.speed * speedBoost * momentum * dt * 0.35
            if turbulence > 0.1 {
                // High stress: orbits shiver and stars get knocked around.
                s.radius += randomFloat(-turbulence...turbulence) * dt * 30
                s.angle += randomFloat(-turbulence...turbulence) * dt * 0.02
            }
            stars[i] = s
        }
    }

    public func render(renderer: Renderer) {
        let center = bounds * 0.5
        var out: [Particle] = []
        out.reserveCapacity(stars.count + 24)

        for s in stars {
            let pos = center + SIMD2(cos(s.angle) * s.radius,
                                     sin(s.angle) * s.radius * s.inclination)
            let closeness = 1 - min(s.radius / (min(bounds.x, bounds.y) * 0.42), 1)
            var color = simd_mix(theme.color(s.colorIndex),
                                 theme.stressColor(blackHole),
                                 SIMD4(repeating: closeness * blackHole))
            color.w *= 0.55 + closeness * 0.4
            // Tangential velocity for streak stretching near the core.
            let tangent = SIMD2(-sin(s.angle), cos(s.angle) * s.inclination)
            let speed = s.speed * max(s.baseRadius / max(s.radius, 1), 1) * s.radius * 0.35
            out.append(Particle(position: pos, velocity: tangent * speed,
                                color: color, size: s.size * theme.particleScale,
                                glow: closeness * 0.5 + corePulse * 0.3,
                                shape: speed > 260 ? .streak : .disc))
        }

        // Core: bright when healthy, collapses to a dark ring as the hole forms.
        let coreSize = min(bounds.x, bounds.y) * (0.028 + corePulse * 0.02) * (1 - blackHole * 0.7)
        var coreColor = theme.stressColor(blackHole)
        coreColor.w = 0.9 * (1 - blackHole * 0.85)
        out.append(Particle(position: center, color: coreColor,
                            size: coreSize, glow: 0.8 + corePulse))
        if blackHole > 0.05 {
            // Accretion ring.
            let ringRadius = coreSize * 2.4
            for i in 0..<20 {
                let a = Float(i) / 20 * 2 * .pi + time * 1.5
                var c = theme.warningColor
                c.w = blackHole * 0.8
                out.append(Particle(
                    position: center + SIMD2(cos(a), sin(a) * 0.6) * ringRadius,
                    color: c, size: 2.5, glow: blackHole))
            }
        }
        renderer.submit(out)
    }
}
