import Foundation
import simd

/// Factory — system load as industrial throughput. Crates ride conveyor belts
/// between machines; gears spin with CPU, machine backlogs grow under memory
/// pressure, and swap dumps rejected crates off the end of the line.
public final class FactoryPlugin: AnimationPlugin {
    public let name = "Factory"

    private struct Crate {
        var position: SIMD2<Float>
        var beltIndex: Int
        var progress: Float        // 0…1 along the belt
        var colorIndex: Int
        var stalled: Float = 0
        var falling: Bool = false
        var velocity = SIMD2<Float>(0, 0)
        var settled: Float = 0     // rest time after falling; drives fade-out
    }
    private struct Belt {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var length: Float { simd_distance(start, end) }
        func point(_ t: Float) -> SIMD2<Float> {
            simd_mix(start, end, SIMD2(repeating: t))
        }
    }
    private struct Machine {
        var position: SIMD2<Float>
        var backlog: Float = 0     // 0…1 visible queue buildup
        var workPulse: Float = 0
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var worldMin = SIMD2<Float>(0, 0)
    private var worldMax = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var belts: [Belt] = []
    private var machines: [Machine] = []
    private var gears: [(center: SIMD2<Float>, radius: Float, angle: Float, direction: Float)] = []
    private struct Spark {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
    }

    private var crates: [Crate] = []
    private var sparks: [Spark] = []
    private var spawnAccumulator: Float = 0
    private var time: Float = 0
    private var lastState = SystemState()

    private let maxCrates = 400

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        worldMin = SIMD2(0, 0)
        worldMax = bounds
        buildFactory()
        crates.removeAll(keepingCapacity: true)
    }

    public func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {
        self.worldMin = worldMin
        self.worldMax = worldMax
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func buildFactory() {
        belts.removeAll(); machines.removeAll(); gears.removeAll()
        // Three-stage production line snaking across the lower half.
        let y1 = bounds.y * 0.55
        let y2 = bounds.y * 0.38
        let y3 = bounds.y * 0.21
        let left = bounds.x * 0.12
        let right = bounds.x * 0.88

        machines = [
            Machine(position: SIMD2(right, y1)),
            Machine(position: SIMD2(left, y2)),
            Machine(position: SIMD2(right, y3)),
        ]
        belts = [
            Belt(start: SIMD2(left, y1), end: SIMD2(right - 30, y1)),
            Belt(start: SIMD2(right, y1 - 20), end: SIMD2(left + 30, y2)),
            Belt(start: SIMD2(left, y2 - 20), end: SIMD2(right - 30, y3)),
        ]
        // Gears decorate the machines and midpoints of belts.
        for m in machines {
            gears.append((m.position + SIMD2(0, 26), 13, 0, 1))
        }
        for b in belts {
            gears.append((b.point(0.5) + SIMD2(0, -14), 8, 0, -1))
        }
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        lastState = state

        // Gear speed tracks CPU (P-cores drive big gears, E-cores small ones).
        for i in gears.indices {
            let speed = (gears[i].radius > 10
                ? 1 + state.performanceCorePercent * 9
                : 1 + state.efficiencyCorePercent * 7) * (1 + state.stress * 2)
                * max(state.intensity, 0.05)
            gears[i].angle += gears[i].direction * speed * dt
        }

        // Input rate: overall throughput demand.
        var rate = (2 + state.cpuPercent * 18 + state.ramPercent * 10) * state.intensity
        if state.inferenceRunning {
            rate += min(state.tokensPerSecond, 60) * 0.4 * state.intensity
        }
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1, crates.count < maxCrates {
            spawnAccumulator -= 1
            crates.append(Crate(position: belts[0].start, beltIndex: 0, progress: 0,
                                colorIndex: Int.random(in: 0..<6)))
        }

        // Machine service rate drops with memory pressure → backlogs grow.
        let serviceRate = 1 - state.memoryPressure * 0.8
        for i in machines.indices {
            machines[i].workPulse = max(0, machines[i].workPulse - dt * 3)
            machines[i].backlog = max(0, machines[i].backlog - serviceRate * dt * 0.5)
        }
        if state.modelJustLoaded {
            for i in machines.indices { machines[i].workPulse = 1 }
        }

        // Crates advance along belts, respecting headway (visible backups).
        // Stress makes belts RUN FASTER while machines fall behind — crates
        // slam into growing pileups instead of the line going sleepy.
        let beltSpeed: Float = 60 * (0.6 + state.cpuPercent * 1.0 + state.stress * 1.4)
            * max(state.intensity, 0.05)
        crates.sort { ($0.beltIndex, -$0.progress) < ($1.beltIndex, -$1.progress) }
        var leaderProgress: [Int: Float] = [:]
        for i in crates.indices {
            var c = crates[i]
            if c.falling {
                c.velocity.y -= 800 * dt
                c.position += c.velocity * dt
                // Rejected crates bounce off the real screen edges and come
                // to rest on the screen bottom, then fade away.
                if c.position.y < worldMin.y + 4 {
                    c.position.y = worldMin.y + 4
                    c.velocity.y = abs(c.velocity.y) * 0.38
                    c.velocity.x *= 0.90
                }
                if c.position.x < worldMin.x + 4 {
                    c.position.x = worldMin.x + 4
                    c.velocity.x = abs(c.velocity.x) * 0.5
                }
                if c.position.x > worldMax.x - 4 {
                    c.position.x = worldMax.x - 4
                    c.velocity.x = -abs(c.velocity.x) * 0.5
                }
                if simd_length_squared(c.velocity) < 300 { c.settled += dt }
                crates[i] = c
                continue
            }
            let belt = belts[c.beltIndex]
            let headway = 14 / belt.length
            let limit = leaderProgress[c.beltIndex].map { $0 - headway } ?? 2
            let machineIndex = c.beltIndex  // machine at the end of each belt
            // Machine backlog blocks the last stretch of the belt.
            let blockedFrom = 1 - machines[machineIndex].backlog * 0.35
            let desired = c.progress + beltSpeed / belt.length * dt
            let target = min(desired, limit, max(blockedFrom, c.progress))
            if target > c.progress + 0.0001 {
                c.progress = target
                c.stalled = max(0, c.stalled - dt * 2)
            } else {
                c.stalled = min(c.stalled + dt, 2)
            }
            leaderProgress[c.beltIndex] = c.progress
            c.position = belt.point(c.progress)

            if c.progress >= min(1, blockedFrom) - 0.001, c.progress >= limit - 0.001 {
                // Arrived at machine: consume or reject.
                if c.progress >= 0.999 || c.progress >= blockedFrom - 0.001 {
                    machines[machineIndex].backlog = min(1, machines[machineIndex].backlog
                        + 0.06 + lastState.memoryPressure * 0.05)
                }
            }
            if c.progress >= 0.999 {
                machines[machineIndex].workPulse = 1
                // Impact sparks fly when a machine takes a crate.
                if sparks.count < 160 {
                    for _ in 0..<3 {
                        sparks.append(Spark(
                            position: machines[machineIndex].position,
                            velocity: SIMD2(randomFloat(-90...90), randomFloat(40...140)),
                            life: randomFloat(0.25...0.6)))
                    }
                }
                if machineIndex + 1 < belts.count {
                    c.beltIndex = machineIndex + 1
                    c.progress = 0
                } else if state.swapPercent > 0.05, randomFloat(0...1) < state.swapPercent {
                    // Swap: reject the crate off the end of the line.
                    c.falling = true
                    c.velocity = SIMD2(randomFloat(30...90), randomFloat(20...80))
                } else {
                    c.progress = 2  // mark complete for removal
                }
            }
            crates[i] = c
        }
        crates.removeAll { (!$0.falling && $0.progress > 1.5) || $0.settled > 6 }

        for i in sparks.indices {
            sparks[i].velocity.y -= 500 * dt
            sparks[i].position += sparks[i].velocity * dt
            sparks[i].life -= dt
        }
        sparks.removeAll { $0.life <= 0 }
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []

        // Belts: dotted lines.
        var beltColor = theme.color(2); beltColor.w *= 0.2
        for belt in belts {
            let count = Int(belt.length / 12)
            for i in 0...count {
                out.append(Particle(position: belt.point(Float(i) / Float(max(count, 1))),
                                    color: beltColor, size: 1.4))
            }
        }

        // Gears: rings of teeth particles rotating.
        var gearColor = theme.color(1); gearColor.w *= 0.5
        for gear in gears {
            let teeth = gear.radius > 10 ? 10 : 7
            for t in 0..<teeth {
                let a = gear.angle + Float(t) / Float(teeth) * 2 * .pi
                out.append(Particle(
                    position: gear.center + SIMD2(cos(a), sin(a)) * gear.radius,
                    color: gearColor, size: 2.2, glow: 0.15))
            }
            out.append(Particle(position: gear.center, color: gearColor,
                                size: gear.radius * 0.3, glow: 0.1))
        }

        // Machines: square blocks; backlog piles glow toward warning color.
        // Overloaded machines rattle in place.
        let shake = lastState.stress > 0.55 ? (lastState.stress - 0.55) * 9 : 0
        for m in machines {
            var c = simd_mix(theme.color(0), theme.warningColor,
                             SIMD4(repeating: m.backlog))
            c.w = 0.5 + m.workPulse * 0.4
            let rattle = shake * m.backlog
            let pos = m.position + SIMD2(randomFloat(-1...1), randomFloat(-1...1)) * rattle
            out.append(Particle(position: pos, color: c, size: 15,
                                glow: m.workPulse, shape: .square))
            // Backlog pile beside the machine.
            let pile = Int(m.backlog * 6)
            for p in 0..<pile {
                out.append(Particle(
                    position: m.position + SIMD2(-22 - Float(p % 3) * 9,
                                                 Float(p / 3) * 9 - 4),
                    color: theme.warningColor * SIMD4(1, 1, 1, 0.6),
                    size: 3.5, glow: 0.3, shape: .square))
            }
        }

        // Sparks: short-lived bright streaks off working machines.
        for sp in sparks {
            var c = theme.calmColor
            c.w *= min(sp.life * 3, 1)
            out.append(Particle(position: sp.position, velocity: sp.velocity,
                                color: c, size: 1.6, glow: 0.9, shape: .streak))
        }

        // Crates.
        for c in crates {
            let jam = min(c.stalled, 1)
            var color = c.falling
                ? theme.warningColor
                : simd_mix(theme.color(c.colorIndex), theme.warningColor,
                           SIMD4(repeating: jam * 0.6))
            let fade = min(max((6 - c.settled), 0), 1)   // last second fades out
            color.w *= 0.9 * fade
            out.append(Particle(position: c.position, velocity: c.velocity,
                                color: color, size: 3.8 * theme.particleScale,
                                glow: c.falling ? 0.8 : 0.2 + jam * 0.3, shape: .square))
        }
        renderer.submit(out)
    }
}
