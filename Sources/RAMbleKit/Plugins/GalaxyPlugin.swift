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
        var twinklePhase: Float    // per-star shimmer offset
        var twinkleRate: Float
    }
    private struct Wisp {          // soft nebula haze blobs
        var angle: Float
        var radius: Float
        var size: Float
        var colorIndex: Int
        var drift: Float
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var stars: [Star] = []
    private var wisps: [Wisp] = []
    private var backdrop: [Particle] = []   // static distant starfield
    private var corePulse: Float = 0
    private var blackHole: Float = 0    // 0…1 how formed the black hole is
    private var time: Float = 0

    private let starCount = 2600
    private let armCount: Float = 2
    private let armTwist: Float = 2.6   // radians of spiral wind at the rim

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        stars.removeAll(keepingCapacity: true)
        stars.reserveCapacity(starCount)
        let maxRadius = min(bounds.x, bounds.y) * 0.42
        for i in 0..<starCount {
            // Density falls off with radius, like a disc galaxy.
            let r = maxRadius * (0.12 + 0.88 * pow(randomFloat(0...1), 0.6))
            // ~70% of stars cluster into wound spiral arms; the rest scatter.
            var angle = randomFloat(0...(2 * .pi))
            if i % 10 < 7 {
                let arm = Float(i % Int(armCount))
                let armBase = arm * (2 * .pi / armCount)
                angle = armBase + (r / maxRadius) * armTwist
                    + randomFloat(-0.30...0.30)
            }
            stars.append(Star(
                angle: angle,
                radius: r,
                baseRadius: r,
                // Mostly uniform sweep (density-wave-ish) so arms persist,
                // with a touch of shear for life.
                speed: 0.30 + 8 / max(r, 30),
                colorIndex: Int.random(in: 0..<8),
                size: randomFloat(0.7...2.6),
                inclination: randomFloat(0.55...0.75),
                twinklePhase: randomFloat(0...(2 * .pi)),
                twinkleRate: randomFloat(0.6...2.8)))
        }
        // Nebula haze: big, soft, slow blobs riding the arms.
        wisps = (0..<36).map { i in
            let r = maxRadius * (0.18 + 0.75 * randomFloat(0...1))
            let arm = Float(i % Int(armCount))
            return Wisp(
                angle: arm * (2 * .pi / armCount) + (r / maxRadius) * armTwist
                    + randomFloat(-0.4...0.4),
                radius: r,
                size: randomFloat(26...58),
                colorIndex: Int.random(in: 0..<4),
                drift: randomFloat(0.10...0.22))
        }
        // Distant static starfield across the whole display.
        backdrop = (0..<180).map { _ in
            var c = theme.color(Int.random(in: 0..<4))
            c.w *= randomFloat(0.06...0.22)
            return Particle(
                position: SIMD2(randomFloat(0...bounds.x), randomFloat(0...bounds.y)),
                color: c, size: randomFloat(0.6...1.4))
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
        for i in wisps.indices {
            wisps[i].angle += wisps[i].drift * dt * (0.5 + speedBoost * 0.15)
        }
    }

    public func render(renderer: Renderer) {
        let center = bounds * 0.5
        var out: [Particle] = []
        out.reserveCapacity(stars.count + wisps.count + backdrop.count + 24)

        // Distant starfield + nebula haze go down first (they sit "behind").
        out.append(contentsOf: backdrop)
        for w in wisps {
            let pos = center + SIMD2(cos(w.angle) * w.radius,
                                     sin(w.angle) * w.radius * 0.62)
            var c = theme.color(w.colorIndex)
            c.w *= 0.045
            out.append(Particle(position: pos, color: c, size: w.size, glow: 0.05))
        }

        let maxR = min(bounds.x, bounds.y) * 0.42
        for s in stars {
            let pos = center + SIMD2(cos(s.angle) * s.radius,
                                     sin(s.angle) * s.radius * s.inclination)
            let closeness = 1 - min(s.radius / maxR, 1)
            // Warm bright core → cool dim rim, shifted toward warning as the
            // black hole forms; per-star twinkle keeps the field alive.
            var color = simd_mix(theme.color(s.colorIndex), theme.calmColor,
                                 SIMD4(repeating: closeness * 0.55))
            color = simd_mix(color, theme.stressColor(blackHole),
                             SIMD4(repeating: closeness * blackHole))
            let twinkle = 0.78 + 0.22 * sin(time * s.twinkleRate + s.twinklePhase)
            color.w *= (0.45 + closeness * 0.5) * twinkle
            // Tangential velocity for streak stretching near the core.
            let tangent = SIMD2(-sin(s.angle), cos(s.angle) * s.inclination)
            let speed = s.speed * max(s.baseRadius / max(s.radius, 1), 1) * s.radius * 0.35
            out.append(Particle(position: pos, velocity: tangent * speed,
                                color: color,
                                size: s.size * theme.particleScale * (0.9 + closeness * 0.4),
                                glow: closeness * 0.6 + corePulse * 0.3,
                                shape: speed > 260 ? .streak : .disc))
        }

        // Core: layered halo, bright when healthy, collapsing dark as the
        // hole forms. Three nested discs give it depth instead of one blob.
        let coreSize = min(bounds.x, bounds.y) * (0.028 + corePulse * 0.02) * (1 - blackHole * 0.7)
        var coreColor = theme.stressColor(blackHole)
        coreColor.w = 0.9 * (1 - blackHole * 0.85)
        var halo = coreColor; halo.w *= 0.16
        out.append(Particle(position: center, color: halo,
                            size: coreSize * 3.4, glow: 0.3))
        var mid = coreColor; mid.w *= 0.45
        out.append(Particle(position: center, color: mid,
                            size: coreSize * 1.9, glow: 0.5 + corePulse * 0.5))
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
