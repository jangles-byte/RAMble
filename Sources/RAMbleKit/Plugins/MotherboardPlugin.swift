import Foundation
import simd

/// Motherboard — a stylized circuit board. Data packets travel along traces
/// between CPU cores and memory modules; congestion backs packets up along
/// the traces, and swap reroutes glowing red packets to the "disk" corner.
public final class MotherboardPlugin: AnimationPlugin {
    public let name = "Motherboard"

    private struct Trace {
        var points: [SIMD2<Float>]
        var lengths: [Float]       // cumulative distance at each point
        var totalLength: Float
        var kind: Kind
        enum Kind { case coreToRAM, coreToGPU, ramToDisk }

        func position(at distance: Float) -> SIMD2<Float> {
            let d = max(0, min(distance, totalLength))
            var i = 1
            while i < lengths.count - 1, lengths[i] < d { i += 1 }
            let segStart = lengths[i - 1]
            let segLen = max(lengths[i] - segStart, 0.001)
            let t = (d - segStart) / segLen
            return simd_mix(points[i - 1], points[i], SIMD2(repeating: t))
        }
    }

    private struct Packet {
        var traceIndex: Int
        var distance: Float
        var speed: Float
        var colorIndex: Int
        var stalled: Float = 0
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var traces: [Trace] = []
    private var packets: [Packet] = []
    private var corePositions: [SIMD2<Float>] = []
    private var ramPositions: [SIMD2<Float>] = []
    private var gpuPosition = SIMD2<Float>(0, 0)
    private var diskPosition = SIMD2<Float>(0, 0)
    private var spawnAccumulator: Float = 0
    private var time: Float = 0
    private var coreActivity: [Float] = []
    private var lastState = SystemState()

    private let maxPackets = 700

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        buildBoard()
        packets.removeAll(keepingCapacity: true)
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func buildBoard() {
        traces.removeAll()
        corePositions.removeAll()
        ramPositions.removeAll()

        let cx = bounds.x / 2
        // CPU cluster: 8 cores in a 4x2 grid left of center.
        let coreOrigin = SIMD2<Float>(cx - bounds.x * 0.28, bounds.y * 0.5)
        for row in 0..<2 {
            for col in 0..<4 {
                corePositions.append(coreOrigin +
                    SIMD2(Float(col) * 34 - 51, Float(row) * 34 - 17))
            }
        }
        coreActivity = Array(repeating: 0, count: corePositions.count)

        // RAM modules: 4 slots right of center.
        for i in 0..<4 {
            ramPositions.append(SIMD2(cx + bounds.x * 0.22,
                                      bounds.y * 0.32 + Float(i) * bounds.y * 0.12))
        }
        gpuPosition = SIMD2(cx - bounds.x * 0.05, bounds.y * 0.2)
        diskPosition = SIMD2(cx + bounds.x * 0.32, bounds.y * 0.14)

        // Manhattan-routed traces core→RAM.
        for (ci, core) in corePositions.enumerated() {
            let ram = ramPositions[ci % ramPositions.count]
            let midX = cx + Float(ci % 4) * 9 - 14
            traces.append(makeTrace([core, SIMD2(midX, core.y),
                                     SIMD2(midX, ram.y), ram], kind: .coreToRAM))
        }
        // Core cluster → GPU.
        for ci in [1, 2, 5, 6] {
            let core = corePositions[ci]
            traces.append(makeTrace([core, SIMD2(core.x, gpuPosition.y + 24),
                                     SIMD2(gpuPosition.x, gpuPosition.y + 24), gpuPosition],
                                    kind: .coreToGPU))
        }
        // RAM → disk (swap path).
        for ram in ramPositions {
            traces.append(makeTrace([ram, SIMD2(diskPosition.x - 30, ram.y),
                                     SIMD2(diskPosition.x - 30, diskPosition.y), diskPosition],
                                    kind: .ramToDisk))
        }
    }

    private func makeTrace(_ points: [SIMD2<Float>], kind: Trace.Kind) -> Trace {
        var lengths: [Float] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + simd_distance(points[i - 1], points[i]))
        }
        return Trace(points: points, lengths: lengths,
                     totalLength: lengths.last ?? 1, kind: kind)
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        lastState = state

        for i in coreActivity.indices {
            let usage = i < state.perCoreUsage.count ? state.perCoreUsage[i] : state.cpuPercent
            coreActivity[i] += (usage - coreActivity[i]) * min(1, dt * 4)
        }

        // Traffic follows RAM churn + CPU; swap opens the RAM→disk routes.
        // Stress floods the board with traffic — jams form from sheer volume.
        var rate = (4 + state.ramPercent * 30 + state.cpuPercent * 25
            + state.stress * 60) * state.intensity
        if state.inferenceRunning { rate += min(state.tokensPerSecond, 80) * 0.5 }
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1, packets.count < maxPackets {
            spawnAccumulator -= 1
            let kind: Trace.Kind
            let roll = randomFloat(0...1)
            if state.swapPercent > 0.05, roll < state.swapPercent * 0.6 { kind = .ramToDisk }
            else if roll < 0.25 + state.gpuPercent * 0.4 { kind = .coreToGPU }
            else { kind = .coreToRAM }
            let candidates = traces.indices.filter { traces[$0].kind == kind }
            guard let ti = candidates.randomElement() else { continue }
            packets.append(Packet(traceIndex: ti, distance: 0,
                                  speed: randomFloat(90...150),
                                  colorIndex: Int.random(in: 0..<6)))
        }

        // Moving packets SPEED UP under stress — the board looks frantic, not
        // sluggish. Packets keep a minimum headway; blocked ones stall and
        // back up down the trace (congestion = angry queues, not slow motion).
        let bandwidth = (1 + state.stress * 2.2) * max(state.intensity, 0.05)
        let headway: Float = 9

        // Sort per trace by distance so each packet only checks its leader.
        packets.sort { ($0.traceIndex, $0.distance) < ($1.traceIndex, $1.distance) }
        var leaderDistance: [Int: Float] = [:]  // traceIndex → distance of packet ahead
        for i in packets.indices.reversed() {
            var p = packets[i]
            let limit = leaderDistance[p.traceIndex].map { $0 - headway }
                ?? traces[p.traceIndex].totalLength + 100
            let desired = p.distance + p.speed * bandwidth * dt
            if desired < limit {
                p.distance = desired
                p.stalled = max(0, p.stalled - dt * 2)
            } else {
                p.distance = max(p.distance, limit)
                p.stalled = min(p.stalled + dt, 2)
            }
            leaderDistance[p.traceIndex] = p.distance
            packets[i] = p
        }
        packets.removeAll { $0.distance >= traces[$0.traceIndex].totalLength - 0.5 }
    }

    public func render(renderer: Renderer) {
        var out: [Particle] = []

        // Trace outlines as dim dotted paths.
        var traceColor = theme.color(2); traceColor.w *= 0.16
        func layerDepth(_ kind: Trace.Kind) -> Float {
            switch kind {
            case .coreToGPU: return -0.25
            case .coreToRAM: return 0
            case .ramToDisk: return 0.3
            }
        }
        for trace in traces {
            var d: Float = 0
            let step: Float = 12
            while d < trace.totalLength {
                out.append(Particle(position: trace.position(at: d),
                                    color: traceColor, size: 1.3,
                                    depth: layerDepth(trace.kind)))
                d += step
            }
        }

        // Soft halos ground the chips so they feel lit from within.
        func halo(_ pos: SIMD2<Float>, _ intensity: Float, _ size: Float) {
            var h = theme.stressColor(intensity)
            h.w = 0.05 + intensity * 0.10
            out.append(Particle(position: pos, color: h, size: size, glow: 0.2))
        }
        var coreCenter = SIMD2<Float>(0, 0)
        for p in corePositions { coreCenter += p }
        coreCenter /= Float(max(corePositions.count, 1))
        halo(coreCenter, lastState.cpuPercent, 64)
        halo(gpuPosition, lastState.gpuPercent, 46)
        halo(diskPosition, lastState.swapPercent, 40)

        // CPU cores: squares that brighten with per-core load.
        for (i, pos) in corePositions.enumerated() {
            let activity = i < coreActivity.count ? coreActivity[i] : 0
            var c = theme.stressColor(activity)
            c.w = 0.35 + activity * 0.6
            out.append(Particle(position: pos, color: c, size: 11,
                                glow: activity * 0.8, shape: .square))
        }

        // RAM modules: fill level mirrors overall RAM usage.
        for (i, pos) in ramPositions.enumerated() {
            let filled = lastState.ramPercent * 4 - Float(i)
            let fill = max(0, min(1, filled))
            var c = simd_mix(theme.color(1), theme.stressColor(lastState.memoryPressure),
                             SIMD4(repeating: fill))
            c.w = 0.25 + fill * 0.65
            out.append(Particle(position: pos, color: c, size: 13,
                                glow: fill * 0.5, shape: .square))
        }

        // GPU block pulses with utilization; disk glows red under swap.
        var gpuC = theme.stressColor(lastState.gpuPercent)
        gpuC.w = 0.3 + lastState.gpuPercent * 0.6
        out.append(Particle(position: gpuPosition, color: gpuC, size: 16,
                            glow: lastState.gpuPercent, shape: .square))
        var diskC = simd_mix(theme.color(0), theme.warningColor,
                             SIMD4(repeating: lastState.swapPercent))
        diskC.w = 0.3 + lastState.swapPercent * 0.6
        out.append(Particle(position: diskPosition, color: diskC, size: 14,
                            glow: lastState.swapPercent, shape: .square))

        // Packets. Stalled ones vibrate — a jam reads as buzzing, not frozen.
        for p in packets {
            let trace = traces[p.traceIndex]
            var pos = trace.position(at: p.distance)
            let jam = min(p.stalled, 1)
            if jam > 0.1 {
                pos += SIMD2(randomFloat(-1.5...1.5), randomFloat(-1.5...1.5)) * jam
            }
            var c = trace.kind == .ramToDisk
                ? theme.warningColor
                : simd_mix(theme.color(p.colorIndex), theme.warningColor,
                           SIMD4(repeating: jam * 0.7))
            c.w *= 0.9
            out.append(Particle(position: pos, color: c,
                                size: 2.6 * theme.particleScale,
                                glow: 0.4 + jam * 0.4,
                                depth: layerDepth(trace.kind)))
        }
        renderer.submit(out)
    }
}
