import Foundation
import simd

/// Water Tank — a glass reservoir whose water level is RAM usage. Memory
/// pressure whips up the surface waves; swap overflows the tank in glowing
/// red spill droplets down the sides.
public final class WaterTankPlugin: AnimationPlugin {
    public let name = "Water Tank"

    private struct SurfaceColumn {
        var height: Float      // offset from the rest level
        var velocity: Float
    }
    private struct Droplet {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var overflow: Bool
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var columns: [SurfaceColumn] = []
    private var droplets: [Droplet] = []
    private var level: Float = 0            // smoothed water level 0…1
    private var time: Float = 0
    private var tank = (left: Float(0), right: Float(0), bottom: Float(0), top: Float(0))

    private let columnCount = 96

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        let width = min(bounds.x * 0.5, bounds.y * 0.7)
        tank.left = bounds.x / 2 - width / 2
        tank.right = bounds.x / 2 + width / 2
        tank.bottom = bounds.y * 0.12
        tank.top = bounds.y * 0.82
        columns = Array(repeating: SurfaceColumn(height: 0, velocity: 0), count: columnCount)
        droplets.removeAll(keepingCapacity: true)
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        level += (state.ramPercent - level) * min(1, dt * 1.2)

        // --- 1D wave simulation on the surface (spring + neighbor coupling) ---
        // Stress whips the surface into a storm: more kicks, harder kicks.
        let agitation = min(1, state.memoryPressure * 0.5 + state.cpuPercent * 0.2
                               + state.stress * 0.8)
        let stiffness: Float = 40
        let dampen: Float = 1 - min(0.985, 0.9 + (1 - agitation) * 0.08)

        // Random wind kicks scale with agitation; inference adds rhythmic chop.
        if agitation > 0.02 {
            let kicks = 1 + Int(agitation * agitation * 12)
            for _ in 0..<kicks {
                let i = Int.random(in: 0..<columnCount)
                columns[i].velocity += randomFloat(-1...1) * agitation * 220 * dt * 30
            }
        }
        if state.inferenceRunning {
            let i = Int((sin(time * 5) * 0.5 + 0.5) * Float(columnCount - 1))
            columns[i].velocity += sin(time * 18) * 90 * dt * 30
        }

        var next = columns
        for i in 0..<columnCount {
            let left = columns[max(i - 1, 0)].height
            let right = columns[min(i + 1, columnCount - 1)].height
            let spread = (left + right - 2 * columns[i].height) * stiffness
            next[i].velocity += (spread - columns[i].height * stiffness * 0.4) * dt
            next[i].velocity *= (1 - dampen)
            next[i].height += next[i].velocity * dt
        }
        columns = next

        // --- Overflow: swap pushes water over the rim ---
        let surfaceY = waterSurfaceY()
        if state.swapPercent > 0.03, surfaceY > tank.top - 8 {
            let rate = Int(1 + state.swapPercent * 6)
            for _ in 0..<rate where droplets.count < 500 {
                let side: Float = Bool.random() ? tank.left : tank.right
                droplets.append(Droplet(
                    position: SIMD2(side + randomFloat(-4...4), tank.top),
                    velocity: SIMD2(side == tank.left ? randomFloat(-60...(-20))
                                                      : randomFloat(20...60),
                                    randomFloat(10...60)),
                    life: randomFloat(1.5...3), overflow: true))
            }
        }

        // --- Splash droplets from violent waves ---
        if agitation > 0.4 {
            for i in 0..<columnCount where abs(columns[i].velocity) > 90 && droplets.count < 500 {
                let x = tank.left + (tank.right - tank.left) * Float(i) / Float(columnCount - 1)
                droplets.append(Droplet(
                    position: SIMD2(x, surfaceY + columns[i].height),
                    velocity: SIMD2(randomFloat(-30...30), abs(columns[i].velocity) * 1.5),
                    life: randomFloat(0.5...1.2), overflow: false))
                columns[i].velocity *= 0.6
            }
        }

        for i in droplets.indices {
            droplets[i].velocity.y -= 700 * dt
            droplets[i].position += droplets[i].velocity * dt
            droplets[i].life -= dt
        }
        droplets.removeAll { $0.life <= 0 || $0.position.y < -20 }
    }

    private func waterSurfaceY() -> Float {
        tank.bottom + (tank.top - tank.bottom) * level
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []
        let surfaceY = waterSurfaceY()
        let width = tank.right - tank.left

        // Glass walls: faint dotted outline.
        var glass = theme.color(0); glass.w *= 0.18
        let wallStep: Float = 14
        var y = tank.bottom
        while y <= tank.top {
            out.append(Particle(position: SIMD2(tank.left, y), color: glass, size: 1.6))
            out.append(Particle(position: SIMD2(tank.right, y), color: glass, size: 1.6))
            y += wallStep
        }
        var x = tank.left
        while x <= tank.right {
            out.append(Particle(position: SIMD2(x, tank.bottom), color: glass, size: 1.6))
            x += wallStep
        }

        // Water body: layered rows of soft particles below the animated surface.
        let fillTint = theme.stressColor(max(0, level - 0.6) / 0.4)
        let rowSpacing: Float = 10
        var rowY = tank.bottom + 4
        var rowIndex = 0
        while rowY < surfaceY - 4 {
            let wobble = sin(time * 1.3 + Float(rowIndex) * 0.7) * 2
            let colsInRow = Int(width / 12)
            for c in 0...colsInRow {
                let px = tank.left + width * Float(c) / Float(max(colsInRow, 1))
                var color = fillTint
                let depth = (rowY - tank.bottom) / max(surfaceY - tank.bottom, 1)
                color.w *= 0.10 + depth * 0.10
                out.append(Particle(position: SIMD2(px + wobble, rowY),
                                    color: color, size: 7, glow: 0.05))
            }
            rowY += rowSpacing
            rowIndex += 1
        }

        // Surface: bright wave crest following the simulated columns.
        for i in 0..<columnCount {
            let px = tank.left + width * Float(i) / Float(columnCount - 1)
            let py = surfaceY + columns[i].height
            var c = theme.calmColor
            c.w *= 0.85
            let energy = min(abs(columns[i].velocity) / 120, 1)
            out.append(Particle(position: SIMD2(px, py),
                                velocity: SIMD2(0, columns[i].velocity),
                                color: simd_mix(c, theme.warningColor, SIMD4(repeating: energy * 0.5)),
                                size: 3.2 * theme.particleScale,
                                glow: 0.3 + energy * 0.5))
        }

        // Droplets (splash + red overflow).
        for d in droplets {
            var c = d.overflow ? theme.warningColor : theme.calmColor
            c.w *= min(d.life, 1) * 0.9
            out.append(Particle(position: d.position, velocity: d.velocity, color: c,
                                size: d.overflow ? 3.0 : 2.0,
                                glow: d.overflow ? 0.9 : 0.4, shape: .streak))
        }
        renderer.submit(out)
    }
}
