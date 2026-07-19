import Foundation
import simd

/// Rain — a storm whose intensity is your system load, falling into a puddle
/// that genuinely reacts. Raindrops fall in parallax depth layers, strike a
/// wave-simulated water surface to raise ripple rings and splashes, and the
/// puddle rises and reddens as memory fills and swap floods. Loading a model
/// throws a lightning flash.
///
/// Mapping:
/// - Downpour rate  ← RAM + stress + the intensity setting (drizzle → deluge)
/// - Storm speed / wind ← stress and CPU
/// - Puddle depth   ← RAM usage; floods higher and turns red under swap
/// - Lightning      ← model load; occasional strikes under heavy stress
public final class RainPlugin: AnimationPlugin {
    public let name = "Rain"

    private struct Drop {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var depth: Float          // -1 near … +1 far (parallax lane)
        var length: Float
        var colorIndex: Int
    }
    private struct Ripple {
        var center: Float         // x on the surface
        var surfaceY: Float
        var radius: Float
        var maxRadius: Float
        var depth: Float
    }
    private struct Splash {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var depth: Float
    }
    private struct Column { var height: Float = 0; var velocity: Float = 0 }

    private var bounds = SIMD2<Float>(800, 600)
    private var worldMin = SIMD2<Float>(0, 0)
    private var worldMax = SIMD2<Float>(800, 600)
    private var theme = Themes.glass

    private var drops: [Drop] = []
    private var ripples: [Ripple] = []
    private var splashes: [Splash] = []
    private var columns: [Column] = []
    private var spawnAccumulator: Float = 0
    private var time: Float = 0
    private var puddleBaseY: Float = 0     // smoothed surface rest level
    private var flash: Float = 0           // lightning brightness, decays
    private var flashCooldown: Float = 0

    private let columnCount = 140
    private let maxDrops = 1400

    public init() {}

    // Rain reads best with crisp streaks, not long accumulation smear.
    public var preferredTrailPersistence: Float? { 0.45 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        columns = Array(repeating: Column(), count: columnCount)
        drops.removeAll(keepingCapacity: true)
        ripples.removeAll(keepingCapacity: true)
        splashes.removeAll(keepingCapacity: true)
        puddleBaseY = worldMin.y + bounds.y * 0.08
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    // Surface rest level rises with memory usage; swap floods it higher.
    private func targetSurfaceY(_ s: SystemState) -> Float {
        worldMin.y + (worldMax.y - worldMin.y) * (0.06 + s.ramPercent * 0.14 + s.swapPercent * 0.16)
    }

    private func columnIndex(forX x: Float) -> Int {
        let t = (x - worldMin.x) / max(worldMax.x - worldMin.x, 1)
        return min(columnCount - 1, max(0, Int(t * Float(columnCount - 1))))
    }
    private func columnX(_ i: Int) -> Float {
        worldMin.x + (worldMax.x - worldMin.x) * Float(i) / Float(columnCount - 1)
    }
    private func surfaceY(atX x: Float) -> Float {
        puddleBaseY + columns[columnIndex(forX: x)].height
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)

        puddleBaseY += (targetSurfaceY(state) - puddleBaseY) * min(1, dt * 1.5)

        // Lightning: model load strikes; heavy stress strikes occasionally.
        flash = max(0, flash - dt * 3.5)
        flashCooldown = max(0, flashCooldown - dt)
        if state.modelJustLoaded { flash = 1; flashCooldown = 0.5 }
        if state.stress > 0.75, flashCooldown <= 0, randomFloat(0...1) < state.stress * dt {
            flash = randomFloat(0.6...1.0); flashCooldown = randomFloat(1.5...4)
        }

        // --- Spawn: drizzle when idle, downpour under load ---
        let rate = (12 + state.ramPercent * 120 + state.stress * 220) * intensity
        let stormSpeed = 1 + state.stress * 1.1 + state.cpuPercent * 0.5
        let windAmp = (30 + state.stress * 160) * sin(time * 0.4)
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1, drops.count < maxDrops {
            spawnAccumulator -= 1
            spawnDrop(stormSpeed: stormSpeed)
        }

        // --- Drops fall; nearer lanes fall and drift faster (parallax) ---
        let floodRed = state.swapPercent
        for i in drops.indices {
            let t01 = (drops[i].depth + 1) * 0.5
            let speedFactor = lerp(1.4, 0.65, t01)
            let windFactor = lerp(1.4, 0.5, t01)
            drops[i].velocity.x = windAmp * windFactor
            drops[i].position += drops[i].velocity * SIMD2(1, speedFactor) * dt
        }

        // --- Impacts: a drop reaching the surface makes a ripple + splash ---
        var survivors: [Drop] = []
        survivors.reserveCapacity(drops.count)
        for d in drops {
            if d.position.y <= surfaceY(atX: d.position.x) {
                impact(at: d.position.x, depth: d.depth, strength: lerp(1.3, 0.6, (d.depth + 1) * 0.5))
            } else if d.position.y > worldMin.y - 40 {
                survivors.append(d)
            }
        }
        drops = survivors

        // --- 1D wave sim on the puddle surface ---
        var next = columns
        let stiffness: Float = 42
        for i in 0..<columnCount {
            let l = columns[max(i - 1, 0)].height
            let r = columns[min(i + 1, columnCount - 1)].height
            let spread = (l + r - 2 * columns[i].height) * stiffness
            next[i].velocity += (spread - columns[i].height * stiffness * 0.35) * dt
            next[i].velocity *= 0.985
            next[i].height += next[i].velocity * dt
        }
        columns = next

        // --- Ripples expand and fade ---
        for i in ripples.indices {
            ripples[i].radius += (60 + state.stress * 40) * dt
        }
        ripples.removeAll { $0.radius >= $0.maxRadius }

        // --- Splashes arc up and fall back ---
        for i in splashes.indices {
            splashes[i].velocity.y -= 900 * dt
            splashes[i].position += splashes[i].velocity * dt
            splashes[i].life -= dt
        }
        splashes.removeAll { $0.life <= 0 || $0.position.y < worldMin.y - 20 }
        _ = floodRed
    }

    private func spawnDrop(stormSpeed: Float) {
        let depth = randomFloat(-1...1)
        let t01 = (depth + 1) * 0.5
        let x = randomFloat((worldMin.x - 60)...(worldMax.x + 60))
        let fall = lerp(900, 480, t01) * stormSpeed
        drops.append(Drop(
            position: SIMD2(x, worldMax.y + randomFloat(0...80)),
            velocity: SIMD2(0, -fall),
            depth: depth,
            length: lerp(16, 7, t01),
            colorIndex: Int.random(in: 0..<max(theme.palette.count, 1))))
    }

    private func impact(at x: Float, depth: Float, strength: Float) {
        let sy = surfaceY(atX: x)
        // Kick the surface down (drop pushes water in), then it rebounds.
        let ci = columnIndex(forX: x)
        columns[ci].velocity -= strength * 260
        if ci > 0 { columns[ci - 1].velocity -= strength * 130 }
        if ci < columnCount - 1 { columns[ci + 1].velocity -= strength * 130 }

        if ripples.count < 90 {
            ripples.append(Ripple(center: x, surfaceY: sy, radius: 2,
                                  maxRadius: lerp(46, 20, (depth + 1) * 0.5) * (0.7 + strength),
                                  depth: depth))
        }
        let splashCount = Int(strength * 3) + 1
        for _ in 0..<splashCount where splashes.count < 400 {
            splashes.append(Splash(
                position: SIMD2(x + randomFloat(-3...3), sy),
                velocity: SIMD2(randomFloat(-40...40), randomFloat(60...150) * strength),
                life: randomFloat(0.3...0.7),
                depth: depth))
        }
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        out.reserveCapacity(drops.count * 2 + ripples.count * 24 + splashes.count + columnCount + 64)
        let width = worldMax.x - worldMin.x
        let swap = renderer.currentState.swapPercent

        // Ambient lightning flash: a broad, faint sheet that lifts everything.
        if flash > 0.01 {
            var fc = theme.calmColor
            fc.w = flash * 0.10
            out.append(Particle(position: (worldMin + worldMax) * 0.5, color: fc,
                                size: max(width, bounds.y) * 0.9, glow: flash, depth: 0.4))
        }

        // --- Puddle body: faint filled band below the waterline ---
        let bodyTop = puddleBaseY
        var fill = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap))
        fill.w *= 0.10
        let rows = 5
        for r in 0..<rows {
            let y = lerp(worldMin.y + 2, bodyTop, Float(r) / Float(rows))
            var x = worldMin.x
            let step = width / 26
            while x <= worldMax.x {
                out.append(Particle(position: SIMD2(x, y), color: fill, size: step * 0.9,
                                    glow: 0.03, depth: 0.25))
                x += step
            }
        }

        // --- Waterline: bright surface following the wave columns ---
        for i in 0..<columnCount {
            let x = columnX(i)
            let y = puddleBaseY + columns[i].height
            let energy = min(abs(columns[i].velocity) / 140, 1)
            var c = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap * 0.7))
            c.w *= 0.55 + energy * 0.4
            out.append(Particle(position: SIMD2(x, y),
                                velocity: SIMD2(0, columns[i].velocity),
                                color: c, size: 2.4 * theme.particleScale,
                                glow: 0.3 + energy * 0.5, depth: 0.05))
        }

        // --- Ripple rings on the surface (perspective-flattened ellipses) ---
        for rp in ripples {
            let fade = 1 - rp.radius / rp.maxRadius
            var c = simd_mix(theme.calmColor, theme.warningColor, SIMD4(repeating: swap * 0.6))
            c.w *= fade * 0.7
            let count = min(40, max(10, Int(rp.radius / 3)))
            for k in 0..<count {
                let a = Float(k) / Float(count) * 2 * .pi
                let px = rp.center + cos(a) * rp.radius
                let py = rp.surfaceY + sin(a) * rp.radius * 0.30
                out.append(Particle(position: SIMD2(px, py), color: c,
                                    size: 1.4, glow: 0.3 + fade * 0.3, depth: 0.05))
            }
        }

        // --- Raindrops (streaks) + faint reflection in the puddle ---
        for d in drops {
            var c = simd_mix(theme.color(d.colorIndex), theme.calmColor, SIMD4(repeating: 0.4))
            c = simd_mix(c, theme.warningColor, SIMD4(repeating: swap * 0.5))
            c.w *= 0.85
            out.append(Particle(position: d.position, velocity: d.velocity, color: c,
                                size: 1.6 * theme.particleScale,
                                glow: 0.35 + flash * 0.6, shape: .streak, depth: d.depth))
            // Reflection of drops close above the surface.
            let sy = surfaceY(atX: d.position.x)
            if d.position.y - sy < bounds.y * 0.16 {
                var rc = c; rc.w *= 0.22
                let ry = 2 * sy - d.position.y
                out.append(Particle(position: SIMD2(d.position.x, ry),
                                    velocity: SIMD2(d.velocity.x, -d.velocity.y),
                                    color: rc, size: 1.4 * theme.particleScale,
                                    glow: 0.1, shape: .streak, depth: d.depth * 0.5 + 0.3))
            }
        }

        // --- Splashes ---
        for sp in splashes {
            var c = theme.calmColor
            c.w *= min(sp.life * 3, 1) * 0.9
            out.append(Particle(position: sp.position, velocity: sp.velocity, color: c,
                                size: 1.5, glow: 0.4 + flash * 0.4, shape: .streak, depth: sp.depth))
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (drops: Int, ripples: Int, splashes: Int) {
        (drops.count, ripples.count, splashes.count)
    }
}
