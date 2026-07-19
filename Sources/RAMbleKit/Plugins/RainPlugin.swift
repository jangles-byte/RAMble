import Foundation
import simd

/// Rain — a storm whose intensity is your system load, falling into a puddle
/// that reacts with ripples and splashes. Raindrops fall in parallax depth
/// layers and strike the water, throwing splash crowns and expanding ripple
/// rings. As the gauges climb, the wind picks up (rain slants harder) and
/// lightning begins to strike; swap floods the puddle higher and reddens it.
///
/// Mapping:
/// - Downpour rate ← RAM + stress + the intensity setting (drizzle → deluge)
/// - Wind / slant  ← CPU + stress (calm when idle, driving at high load)
/// - Lightning     ← starts around mid-stress, frequent near max; model load strikes
/// - Puddle depth  ← RAM usage; floods higher and turns red under swap
public final class RainPlugin: AnimationPlugin {
    public let name = "Rain"

    private struct Drop {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var depth: Float          // -1 near … +1 far (parallax lane)
        var colorIndex: Int
    }
    private struct Ripple {
        var center: Float
        var surfaceY: Float
        var radius: Float
        var maxRadius: Float
    }
    private struct Splash {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var depth: Float
    }
    private struct Bolt {
        var points: [SIMD2<Float>]
        var life: Float
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var worldMin = SIMD2<Float>(0, 0)
    private var worldMax = SIMD2<Float>(800, 600)
    private var theme = Themes.glass

    private var drops: [Drop] = []
    private var ripples: [Ripple] = []
    private var splashes: [Splash] = []
    private var bolts: [Bolt] = []
    private var spawnAccumulator: Float = 0
    private var time: Float = 0
    private var puddleBaseY: Float = 0
    private var flash: Float = 0
    private var strikeCooldown: Float = 0

    private let maxDrops = 1400
    private let strikeThreshold: Float = 0.45   // stress at which lightning begins

    public init() {}

    // Rain reads best with crisp streaks, not long accumulation smear.
    public var preferredTrailPersistence: Float? { 0.45 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        drops.removeAll(keepingCapacity: true)
        ripples.removeAll(keepingCapacity: true)
        splashes.removeAll(keepingCapacity: true)
        bolts.removeAll(keepingCapacity: true)
        puddleBaseY = worldMin.y + bounds.y * 0.08
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func targetSurfaceY(_ s: SystemState) -> Float {
        worldMin.y + (worldMax.y - worldMin.y) * (0.06 + s.ramPercent * 0.14 + s.swapPercent * 0.16)
    }

    // A flat surface with a gentle whole-puddle bob — no per-column waveform.
    private func surfaceY() -> Float {
        puddleBaseY + sin(time * 0.7) * 1.5
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)

        puddleBaseY += (targetSurfaceY(state) - puddleBaseY) * min(1, dt * 1.5)

        // --- Lightning: begins around mid-stress, frequent near max ---
        flash = max(0, flash - dt * 3.5)
        strikeCooldown = max(0, strikeCooldown - dt)
        for i in bolts.indices { bolts[i].life -= dt }
        bolts.removeAll { $0.life <= 0 }
        if state.modelJustLoaded { strike() }
        else if state.stress > strikeThreshold, strikeCooldown <= 0 {
            // Probability climbs steeply as the bars go higher.
            let p = (state.stress - strikeThreshold) * 2.2 * dt
            if randomFloat(0...1) < p {
                strike()
                strikeCooldown = randomFloat(0.7...2.4)
            }
        }

        // --- Spawn: drizzle when idle, downpour under load ---
        let rate = (12 + state.ramPercent * 120 + state.stress * 220) * intensity
        let stormSpeed = 1 + state.stress * 1.1 + state.cpuPercent * 0.5
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1, drops.count < maxDrops {
            spawnAccumulator -= 1
            spawnDrop(stormSpeed: stormSpeed)
        }

        // --- Wind: calm when idle, driving gusts as the bars climb ---
        let gust = 0.55 + 0.45 * sin(time * 0.5) + 0.3 * sin(time * 1.7 + 1.1)
        let windAmp = (state.cpuPercent * 70 + state.stress * 240) * gust

        // --- Drops fall; nearer lanes fall and drift faster (parallax) ---
        for i in drops.indices {
            let t01 = (drops[i].depth + 1) * 0.5
            let speedFactor = lerp(1.4, 0.65, t01)
            let windFactor = lerp(1.4, 0.5, t01)
            drops[i].velocity.x = windAmp * windFactor
            drops[i].position += drops[i].velocity * SIMD2(1, speedFactor) * dt
        }

        // --- Impacts: a drop reaching the surface splashes and ripples ---
        let sy = surfaceY()
        var survivors: [Drop] = []
        survivors.reserveCapacity(drops.count)
        for d in drops {
            if d.position.y <= sy {
                impact(at: d.position.x, depth: d.depth,
                       strength: lerp(1.4, 0.6, (d.depth + 1) * 0.5))
            } else if d.position.y > worldMin.y - 40 {
                survivors.append(d)
            }
        }
        drops = survivors

        // --- Ripples expand and fade ---
        for i in ripples.indices { ripples[i].radius += (58 + state.stress * 46) * dt }
        ripples.removeAll { $0.radius >= $0.maxRadius }

        // --- Splashes arc up and fall back, seeding tiny ripples on landing ---
        let floor = surfaceY()
        for i in splashes.indices {
            splashes[i].velocity.y -= 900 * dt
            let prevY = splashes[i].position.y
            splashes[i].position += splashes[i].velocity * dt
            splashes[i].life -= dt
            if prevY > floor, splashes[i].position.y <= floor, ripples.count < 110 {
                ripples.append(Ripple(center: splashes[i].position.x, surfaceY: floor,
                                      radius: 1.5, maxRadius: randomFloat(8...16)))
            }
        }
        splashes.removeAll { $0.life <= 0 || $0.position.y < worldMin.y - 20 }
    }

    private func spawnDrop(stormSpeed: Float) {
        let depth = randomFloat(-1...1)
        let t01 = (depth + 1) * 0.5
        drops.append(Drop(
            position: SIMD2(randomFloat((worldMin.x - 80)...(worldMax.x + 80)),
                            worldMax.y + randomFloat(0...80)),
            velocity: SIMD2(0, -lerp(900, 480, t01) * stormSpeed),
            depth: depth,
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
    }

    private func impact(at x: Float, depth: Float, strength: Float) {
        let sy = surfaceY()
        if ripples.count < 110 {
            ripples.append(Ripple(center: x, surfaceY: sy, radius: 2,
                                  maxRadius: lerp(48, 22, (depth + 1) * 0.5) * (0.7 + strength)))
        }
        // A splash crown: a small fan of droplets thrown up and outward.
        let count = Int(strength * 5) + 2
        for _ in 0..<count where splashes.count < 500 {
            let ang = randomFloat(Float.pi * 0.28 ... Float.pi * 0.72)   // upward fan
            let spd = randomFloat(70...190) * strength
            splashes.append(Splash(
                position: SIMD2(x + randomFloat(-2...2), sy),
                velocity: SIMD2(cos(ang) * spd * (Bool.random() ? 1 : -1), sin(ang) * spd),
                life: randomFloat(0.35...0.8),
                depth: depth))
        }
    }

    private func strike() {
        flash = randomFloat(0.8...1.0)
        var pts: [SIMD2<Float>] = []
        let lo = worldMin.x + 40, hi = worldMax.x - 40
        var x = hi > lo ? randomFloat(lo...hi) : (worldMin.x + worldMax.x) * 0.5
        let steps = 16
        let topY = worldMax.y
        let botY = puddleBaseY
        for s in 0...steps {
            let y = topY + (botY - topY) * Float(s) / Float(steps)
            x += randomFloat(-42...42)
            x = min(max(x, worldMin.x), worldMax.x)
            pts.append(SIMD2(x, y))
        }
        bolts.append(Bolt(points: pts, life: 0.2))
        // The bolt hits the water: a big ripple + splash where it lands.
        impact(at: x, depth: -0.4, strength: 1.6)
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        out.reserveCapacity(drops.count * 2 + ripples.count * 28 + splashes.count + 200)
        let width = worldMax.x - worldMin.x
        let swap = renderer.currentState.swapPercent
        let sy = surfaceY()

        // Ambient lightning flash: a broad faint sheet that lifts the scene.
        if flash > 0.01 {
            var fc = theme.calmColor
            fc.w = flash * 0.12
            out.append(Particle(position: (worldMin + worldMax) * 0.5, color: fc,
                                size: max(width, bounds.y) * 0.95, glow: flash, depth: 0.4))
        }

        // Puddle body: a faint filled band; its soft top edge is the surface.
        var fill = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap))
        fill.w *= 0.11
        let rows = 5
        for r in 0..<rows {
            let y = lerp(worldMin.y + 2, sy, Float(r) / Float(rows))
            var x = worldMin.x
            let step = width / 26
            while x <= worldMax.x {
                out.append(Particle(position: SIMD2(x, y), color: fill, size: step * 0.9,
                                    glow: 0.03, depth: 0.28))
                x += step
            }
        }

        // Ripple rings (perspective-flattened ellipses) mark the surface.
        for rp in ripples {
            let fade = 1 - rp.radius / rp.maxRadius
            var c = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap * 0.6))
            c.w *= fade * 0.7
            let count = min(44, max(10, Int(rp.radius / 3)))
            for k in 0..<count {
                let a = Float(k) / Float(count) * 2 * .pi
                out.append(Particle(
                    position: SIMD2(rp.center + cos(a) * rp.radius,
                                    rp.surfaceY + sin(a) * rp.radius * 0.30),
                    color: c, size: 1.4, glow: 0.3 + fade * 0.3, depth: 0.06))
            }
        }

        // Lightning bolts: bright jagged streaks, near the camera.
        for b in bolts {
            let a = min(b.life / 0.2, 1)
            var c = simd_mix(theme.calmColor, SIMD4(1, 1, 1, 1), SIMD4(repeating: 0.6))
            c.w = a
            for k in 1..<b.points.count {
                let p0 = b.points[k - 1], p1 = b.points[k]
                let seg = p1 - p0
                let n = max(1, Int(simd_length(seg) / 13))
                for j in 0...n {
                    out.append(Particle(position: simd_mix(p0, p1, SIMD2(repeating: Float(j) / Float(n))),
                                        velocity: seg, color: c, size: 2.4,
                                        glow: 1.4, shape: .streak, depth: -0.6))
                }
            }
        }

        // Raindrops (streaks) + faint reflection near the surface.
        for d in drops {
            var c = simd_mix(theme.color(d.colorIndex), theme.calmColor, SIMD4(repeating: 0.4))
            c = simd_mix(c, theme.warningColor, SIMD4(repeating: swap * 0.5))
            c.w *= 0.85
            out.append(Particle(position: d.position, velocity: d.velocity, color: c,
                                size: 1.6 * theme.particleScale,
                                glow: 0.35 + flash * 0.6, shape: .streak, depth: d.depth))
            if d.position.y - sy < bounds.y * 0.16 {
                var rc = c; rc.w *= 0.22
                out.append(Particle(position: SIMD2(d.position.x, 2 * sy - d.position.y),
                                    velocity: SIMD2(d.velocity.x, -d.velocity.y),
                                    color: rc, size: 1.4 * theme.particleScale,
                                    glow: 0.1, shape: .streak, depth: d.depth * 0.5 + 0.3))
            }
        }

        // Splashes: bright droplet crowns off every impact.
        for s in splashes {
            var c = simd_mix(theme.calmColor, SIMD4(1, 1, 1, 1), SIMD4(repeating: 0.2))
            c.w *= min(s.life * 3, 1) * 0.95
            out.append(Particle(position: s.position, velocity: s.velocity, color: c,
                                size: 1.7, glow: 0.5 + flash * 0.4, shape: .streak, depth: s.depth))
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (drops: Int, ripples: Int, splashes: Int) {
        (drops.count, ripples.count, splashes.count)
    }
}
