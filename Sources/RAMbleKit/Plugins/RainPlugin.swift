import Foundation
import simd

/// Rain — a storm whose intensity is your system load, falling onto a
/// receding ground plane. Drops land bigger and brighter at the front
/// (bottom of screen) and smaller, dimmer, and higher toward the back
/// (horizon), giving real depth. Each impact throws a splash crown and an
/// expanding ripple; wind picks up and lightning strikes as the gauges climb.
///
/// Rain computes its own ground-plane perspective (near = front/bottom, far
/// = back/horizon) rather than the renderer's centered depth, so every
/// particle is submitted at depth 0 and sized/placed by hand.
///
/// Mapping:
/// - Downpour rate ← RAM + stress + the intensity setting (drizzle → deluge)
/// - Wind / slant  ← CPU + stress
/// - Lightning     ← starts around mid-stress, frequent near max; model load strikes
/// - Ground flood  ← swap raises the horizon and reddens the rain
public final class RainPlugin: AnimationPlugin {
    public let name = "Rain"

    private struct Drop {
        var position: SIMD2<Float>   // world x, falling y
        var vy: Float
        var d: Float                 // 0 = near/front … 1 = far/back
        var colorIndex: Int
    }
    private struct Ripple {
        var center: SIMD2<Float>
        var d: Float
        var radius: Float
        var maxRadius: Float
    }
    private struct Splash {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var d: Float
    }
    private struct Bolt { var points: [SIMD2<Float>]; var life: Float }

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
    private var horizon: Float = 0        // smoothed back edge of the ground
    private var flash: Float = 0
    private var strikeCooldown: Float = 0

    private let maxDrops = 1500
    private let strikeThreshold: Float = 0.45

    public init() {}

    public var preferredTrailPersistence: Float? { 0.4 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        drops.removeAll(keepingCapacity: true)
        ripples.removeAll(keepingCapacity: true)
        splashes.removeAll(keepingCapacity: true)
        bolts.removeAll(keepingCapacity: true)
        horizon = worldMin.y + bounds.y * 0.40
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    // MARK: - Ground-plane perspective

    private var groundBottom: Float { worldMin.y + (worldMax.y - worldMin.y) * 0.02 }
    private func horizonTarget(_ s: SystemState) -> Float {
        worldMin.y + (worldMax.y - worldMin.y) * (0.38 + s.swapPercent * 0.08)
    }
    /// Screen Y where a drop of depth `d` lands (front/bottom → back/horizon).
    private func landingY(_ d: Float) -> Float { lerp(groundBottom, horizon, d) }
    /// Foreshorten X toward center as things recede, for a vanishing-point feel.
    private func perspX(_ x: Float, _ d: Float) -> Float {
        let c = (worldMin.x + worldMax.x) * 0.5
        return lerp(x, c + (x - c) * 0.68, d)
    }
    private func sizeScale(_ d: Float) -> Float { lerp(2.1, 0.55, d) }
    private func dim(_ d: Float) -> Float { lerp(1.0, 0.5, d) }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)

        horizon += (horizonTarget(state) - horizon) * min(1, dt * 1.5)

        // --- Lightning: begins around mid-stress, frequent near max ---
        flash = max(0, flash - dt * 3.5)
        strikeCooldown = max(0, strikeCooldown - dt)
        for i in bolts.indices { bolts[i].life -= dt }
        bolts.removeAll { $0.life <= 0 }
        if state.modelJustLoaded { strike() }
        else if state.stress > strikeThreshold, strikeCooldown <= 0 {
            let p = (state.stress - strikeThreshold) * 2.2 * dt
            if randomFloat(0...1) < p { strike(); strikeCooldown = randomFloat(0.7...2.4) }
        }

        // --- Spawn: drizzle when idle, downpour under load ---
        let rate = (12 + state.ramPercent * 120 + state.stress * 220) * intensity
        let stormSpeed = 1 + state.stress * 1.1 + state.cpuPercent * 0.5
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1, drops.count < maxDrops {
            spawnAccumulator -= 1
            let d = randomFloat(0...1)
            drops.append(Drop(
                position: SIMD2(randomFloat((worldMin.x - 80)...(worldMax.x + 80)),
                                worldMax.y + randomFloat(0...100)),
                vy: -lerp(1150, 520, d) * stormSpeed,
                d: d,
                colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
        }

        // --- Wind: calm when idle, driving gusts as the bars climb ---
        let gust = 0.55 + 0.45 * sin(time * 0.5) + 0.3 * sin(time * 1.7 + 1.1)
        let windAmp = (state.cpuPercent * 70 + state.stress * 240) * gust

        var survivors: [Drop] = []
        survivors.reserveCapacity(drops.count)
        for var d in drops {
            let windFactor = lerp(1.4, 0.5, d.d)     // near drifts more (parallax)
            d.position.x += windAmp * windFactor * dt
            d.position.y += d.vy * dt
            if d.position.y <= landingY(d.d) {
                impact(worldX: d.position.x, d: d.d)
            } else {
                survivors.append(d)
            }
        }
        drops = survivors

        for i in ripples.indices { ripples[i].radius += (60 + state.stress * 46) * dt }
        ripples.removeAll { $0.radius >= $0.maxRadius }

        for i in splashes.indices {
            splashes[i].velocity.y -= 900 * dt
            splashes[i].position += splashes[i].velocity * dt
            splashes[i].life -= dt
        }
        splashes.removeAll { $0.life <= 0 }
    }

    private func impact(worldX: Float, d: Float) {
        let s = sizeScale(d)
        if ripples.count < 120 {
            ripples.append(Ripple(center: SIMD2(worldX, landingY(d)), d: d,
                                  radius: 2, maxRadius: (14 + 26 * (1 - d))))
        }
        // Splash crown: a fan of droplets thrown up, scaled by nearness.
        let count = Int((1.5 - d) * 5) + 2
        for _ in 0..<count where splashes.count < 500 {
            let ang = randomFloat(Float.pi * 0.30 ... Float.pi * 0.70)
            let spd = randomFloat(60...170) * s * 0.7
            splashes.append(Splash(
                position: SIMD2(worldX + randomFloat(-2...2), landingY(d)),
                velocity: SIMD2(cos(ang) * spd * (Bool.random() ? 1 : -1), sin(ang) * spd),
                life: randomFloat(0.3...0.7),
                d: d))
        }
    }

    private func strike() {
        flash = randomFloat(0.8...1.0)
        var pts: [SIMD2<Float>] = []
        let lo = worldMin.x + 40, hi = worldMax.x - 40
        var x = hi > lo ? randomFloat(lo...hi) : (worldMin.x + worldMax.x) * 0.5
        let steps = 16
        let topY = worldMax.y
        let botY = landingY(0.15)   // strikes near the front
        for s in 0...steps {
            let y = topY + (botY - topY) * Float(s) / Float(steps)
            x += randomFloat(-42...42)
            x = min(max(x, worldMin.x), worldMax.x)
            pts.append(SIMD2(x, y))
        }
        bolts.append(Bolt(points: pts, life: 0.2))
        impact(worldX: x, d: 0.15)
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        out.reserveCapacity(drops.count * 2 + ripples.count * 24 + splashes.count + 200)
        let swap = renderer.currentState.swapPercent
        let width = worldMax.x - worldMin.x

        // Ambient lightning flash sheet.
        if flash > 0.01 {
            var fc = theme.calmColor
            fc.w = flash * 0.12
            out.append(Particle(position: (worldMin + worldMax) * 0.5, color: fc,
                                size: max(width, bounds.y) * 0.95, glow: flash))
        }

        // Draw back-to-front so nearer, bigger elements sit on top.
        // Ripples first (they're flat on the ground), then splashes, drops.
        for rp in ripples.sorted(by: { $0.d > $1.d }) {
            let fade = 1 - rp.radius / rp.maxRadius
            var c = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap * 0.6))
            c.w *= fade * 0.7 * dim(rp.d)
            let squash = lerp(0.34, 0.12, rp.d)     // flatter toward the back
            let count = min(40, max(9, Int(rp.radius / 3)))
            for k in 0..<count {
                let a = Float(k) / Float(count) * 2 * .pi
                let px = rp.center.x + cos(a) * rp.radius
                let py = rp.center.y + sin(a) * rp.radius * squash
                out.append(Particle(position: SIMD2(perspX(px, rp.d), py), color: c,
                                    size: 1.3 * sizeScale(rp.d) * 0.7, glow: 0.3 + fade * 0.3))
            }
        }

        let sortedDrops = drops.sorted { $0.d > $1.d }
        for drop in sortedDrops {
            let s = sizeScale(drop.d)
            let ly = landingY(drop.d)
            var c = simd_mix(theme.color(drop.colorIndex), theme.calmColor, SIMD4(repeating: 0.4))
            c = simd_mix(c, theme.warningColor, SIMD4(repeating: swap * 0.5))
            c.w *= 0.85 * dim(drop.d)
            let px = perspX(drop.position.x, drop.d)
            let vel = SIMD2<Float>(0, drop.vy)   // streak stretches along fall
            out.append(Particle(position: SIMD2(px, drop.position.y), velocity: vel,
                                color: c, size: 1.4 * s * theme.particleScale,
                                glow: 0.35 + flash * 0.6, shape: .streak))
            // Faint reflection just above the ground where it will land.
            if drop.position.y - ly < bounds.y * 0.14 {
                var rc = c; rc.w *= 0.2
                out.append(Particle(position: SIMD2(px, 2 * ly - drop.position.y),
                                    velocity: SIMD2(0, -drop.vy), color: rc,
                                    size: 1.2 * s * theme.particleScale, glow: 0.1, shape: .streak))
            }
        }

        for sp in splashes.sorted(by: { $0.d > $1.d }) {
            var c = simd_mix(theme.calmColor, SIMD4(1, 1, 1, 1), SIMD4(repeating: 0.2))
            c.w *= min(sp.life * 3, 1) * 0.95 * dim(sp.d)
            out.append(Particle(position: SIMD2(perspX(sp.position.x, sp.d), sp.position.y),
                                velocity: sp.velocity, color: c,
                                size: 1.5 * sizeScale(sp.d), glow: 0.5 + flash * 0.4, shape: .streak))
        }

        for b in bolts {
            let a = min(b.life / 0.2, 1)
            var c = simd_mix(theme.calmColor, SIMD4(1, 1, 1, 1), SIMD4(repeating: 0.6))
            c.w = a
            for k in 1..<b.points.count {
                let p0 = b.points[k - 1], p1 = b.points[k]
                let seg = p1 - p0
                let n = max(1, Int(simd_length(seg) / 13))
                for j in 0...n {
                    out.append(Particle(
                        position: simd_mix(p0, p1, SIMD2(repeating: Float(j) / Float(n))),
                        velocity: seg, color: c, size: 2.4, glow: 1.4, shape: .streak))
                }
            }
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (drops: Int, ripples: Int, splashes: Int) {
        (drops.count, ripples.count, splashes.count)
    }
}
