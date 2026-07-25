import Foundation
import simd

/// Synapse — built on the "Arterial" design
/// (docs/synapse-design.md). A directional neural artery in three depth
/// layers: a blazing trunk of hubs crossing the screen left to right, a
/// dense canopy of dendrites around it, and a ghost web breathing in the
/// fog behind. At rest the web is ash-silver with a slow shimmer running
/// the trunk; color exists only in moving signal. Every token the model
/// generates enters at the left edge as a comet-tailed pulse of color and
/// crosses the entire trunk, shedding cascades at each hub; cascades that
/// reach a twig's end burst into embers.
///
/// Mapping:
/// - Tokens/sec     → trunk pulses (one per token; the signature move)
/// - CPU + GPU load → ambient dendrite firings (the resting heartbeat)
/// - Stress         → warms every lit color and quickens all motion
/// - Model load     → the trunk detonates hub by hub
/// - Generation end → one last slow farewell pulse crosses the trunk
public final class SynapsePlugin: AnimationPlugin {
    public let name = "Synapse"

    private struct Node {
        var home: SIMD2<Float>
        var position: SIMD2<Float>
        var z: Float = 0
        var radius: Float
        var colorIndex: Int       // bloom color; overwritten by arriving signals
        var charge: Float = 0
        var flash: Float = 0
        var refractory: Float = 0
        var edges: [Int] = []
        var level: Int = 0        // 0 = trunk, 1 = branch, 2 = twig, 3 = ghost
        var trunkOrder: Int = -1
        var isHub: Bool = false
        var wobblePhase: Float = 0
        var driftFreq = SIMD2<Float>(0.1, 0.1)
        var driftPhase = SIMD2<Float>(0, 0)
        var zFreq: Float = 0.1
        var zPhase: Float = 0
        var zBase: Float = 0
    }

    /// Edges store topology + arc shape only; geometry is evaluated live each
    /// frame from the floating node positions, so the fibers flex and breathe.
    private struct Edge {
        var a: Int
        var b: Int
        var bulge: Float
        var isTrunk: Bool = false
        var isGhost: Bool = false
    }

    private struct Signal {
        var edgeIndex: Int
        var t: Float
        var forward: Bool
        var speed: Float
        var colorIndex: Int
        var strength: Float
        var isToken: Bool = false // token pulses ride the trunk, bigger, hotter
    }

    /// Free-flying sparks thrown when a cascade reaches a twig's end.
    private struct Ember {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float
        var maxLife: Float
        var colorIndex: Int
        var z: Float
    }

    /// Synaptic dust: near-invisible motes drifting between the layers.
    private struct Mote {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var phase: Float
        var z: Float
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var nodes: [Node] = []
    private var edges: [Edge] = []
    private var signals: [Signal] = []
    private var embers: [Ember] = []
    private var motes: [Mote] = []
    private var trunk: [Int] = []       // node indices, left → right
    private var trunkEdges: [Int] = []  // edge indices, trunk[k] → trunk[k+1]
    private var fireAccumulator: Float = 0
    private var tokenAccumulator: Float = 0
    private var time: Float = 0
    private var loadEma: Float = 0
    private var surgeArmed = true

    private let trunkCount = 9
    private let ghostCount = 28
    private let moteCount = 70
    private let maxSignals = 900
    private let maxEmbers = 260

    public init() {}

    // Static node emitters would pile up in the trail buffer; keep persistence
    // low so the signals still streak but the nodes stay crisp.
    public var preferredTrailPersistence: Float? { 0.5 }

    // MARK: - Graph construction

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        signals.removeAll(keepingCapacity: true)
        embers.removeAll(keepingCapacity: true)
        buildGraph()
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func bezier(_ a: SIMD2<Float>, _ c: SIMD2<Float>, _ b: SIMD2<Float>,
                        _ t: Float) -> SIMD2<Float> {
        let u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }

    private func makeNode(_ p: SIMD2<Float>, radius: Float, level: Int) -> Node {
        Node(home: p, position: p, radius: radius,
             colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
             level: level,
             wobblePhase: randomFloat(0...(2 * .pi)),
             driftFreq: SIMD2(randomFloat(0.05...0.16), randomFloat(0.05...0.16)),
             driftPhase: SIMD2(randomFloat(0...(2 * .pi)), randomFloat(0...(2 * .pi))),
             zFreq: randomFloat(0.04...0.11),
             zPhase: randomFloat(0...(2 * .pi)),
             zBase: randomFloat(-0.4...0.4))
    }

    private func addEdge(_ i: Int, _ j: Int, bulge: Float,
                         isTrunk: Bool = false, isGhost: Bool = false) -> Int {
        let edgeIndex = edges.count
        edges.append(Edge(a: i, b: j, bulge: bulge, isTrunk: isTrunk, isGhost: isGhost))
        nodes[i].edges.append(edgeIndex)
        nodes[j].edges.append(edgeIndex)
        return edgeIndex
    }

    private func buildGraph() {
        nodes.removeAll()
        edges.removeAll()
        trunk.removeAll()
        trunkEdges.removeAll()
        motes.removeAll()
        guard bounds.x > 64, bounds.y > 64 else { return }

        let marginX = bounds.x * 0.05
        let wavePhase = randomFloat(0...(2 * .pi))

        // The artery: a gentle S-curve of hubs crossing the full width,
        // pulled toward the viewer.
        for k in 0..<trunkCount {
            let t = Float(k) / Float(trunkCount - 1)
            let x = marginX + t * (bounds.x - marginX * 2)
            let y = bounds.y * (0.5 + 0.11 * sin(t * 3.6 + wavePhase))
            let isHub = k % 2 == 1
            var n = makeNode(SIMD2(x, y), radius: isHub ? 6.2 : 4.4, level: 0)
            n.trunkOrder = k
            n.isHub = isHub
            n.zBase = -0.35
            trunk.append(nodes.count)
            nodes.append(n)
        }
        for k in 0..<(trunkCount - 1) {
            trunkEdges.append(addEdge(trunk[k], trunk[k + 1],
                                      bulge: randomFloat(0.04...0.09) * (Bool.random() ? 1 : -1),
                                      isTrunk: true))
        }

        // The canopy: branches alternate up/down from each trunk node, twigs
        // continue outward. Density thins toward the screen edges — the dark
        // corners are deliberate.
        for (k, trunkIdx) in trunk.enumerated() {
            let branchCount = nodes[trunkIdx].isHub ? 5 : 3
            for b in 0..<branchCount {
                let up: Float = (b % 2 == 0) ? 1 : -1
                let ang = up * randomFloat(0.5...1.25)
                let len = bounds.y * randomFloat(0.13...0.22)
                let dir = SIMD2(cos(ang) * (Bool.random() ? 1 : -1), sin(ang))
                var p = nodes[trunkIdx].home + dir * len
                p.x = min(max(p.x, marginX * 0.5), bounds.x - marginX * 0.5)
                p.y = min(max(p.y, bounds.y * 0.07), bounds.y * 0.93)
                let branchIdx = nodes.count
                nodes.append(makeNode(p, radius: 3.4, level: 1))
                _ = addEdge(trunkIdx, branchIdx,
                            bulge: randomFloat(0.12...0.28) * (Bool.random() ? 1 : -1))

                let centerT = abs(Float(k) / Float(trunkCount - 1) - 0.5) * 2
                let twigCount = centerT > 0.75 ? 1 : Int.random(in: 2...3)
                for _ in 0..<twigCount {
                    let tAng = ang + randomFloat(-0.8...0.8)
                    let tLen = len * randomFloat(0.45...0.75)
                    var tp = p + SIMD2(cos(tAng) * (Bool.random() ? 1 : -1), sin(tAng)) * tLen
                    tp.x = min(max(tp.x, marginX * 0.35), bounds.x - marginX * 0.35)
                    tp.y = min(max(tp.y, bounds.y * 0.04), bounds.y * 0.96)
                    let twigIdx = nodes.count
                    nodes.append(makeNode(tp, radius: 2.6, level: 2))
                    _ = addEdge(branchIdx, twigIdx,
                                bulge: randomFloat(0.15...0.32) * (Bool.random() ? 1 : -1))
                }
            }
        }

        // Cross-links between nearby outer nodes so cascades travel sideways.
        let outer = nodes.indices.filter { nodes[$0].level == 1 || nodes[$0].level == 2 }
        var added = 0
        for i in outer.shuffled() where added < 10 {
            guard let j = outer
                .filter({ $0 != i && !sharesEdge(i, $0) })
                .min(by: { simd_distance(nodes[$0].home, nodes[i].home)
                         < simd_distance(nodes[$1].home, nodes[i].home) }),
                simd_distance(nodes[j].home, nodes[i].home) < bounds.x * 0.14
            else { continue }
            _ = addEdge(i, j, bulge: randomFloat(0.10...0.24) * (Bool.random() ? 1 : -1))
            added += 1
        }

        // The ghost web: far-layer neurons breathing in the fog. They never
        // fire — they give the scene its depth and fullness.
        var ghostIndices: [Int] = []
        for _ in 0..<ghostCount {
            let p = SIMD2(randomFloat((bounds.x * 0.04)...(bounds.x * 0.96)),
                          randomFloat((bounds.y * 0.12)...(bounds.y * 0.88)))
            var n = makeNode(p, radius: randomFloat(1.8...2.6), level: 3)
            n.zBase = 0.75
            ghostIndices.append(nodes.count)
            nodes.append(n)
        }
        for (idx, i) in ghostIndices.enumerated() where idx > 0 {
            let j = ghostIndices[..<idx]
                .min { simd_distance(nodes[$0].home, nodes[i].home)
                     < simd_distance(nodes[$1].home, nodes[i].home) }!
            if simd_distance(nodes[j].home, nodes[i].home) < bounds.x * 0.22 {
                _ = addEdge(i, j, bulge: randomFloat(0.08...0.2) * (Bool.random() ? 1 : -1),
                            isGhost: true)
            }
        }

        // Synaptic dust.
        for _ in 0..<moteCount {
            motes.append(Mote(
                position: SIMD2(randomFloat(0...bounds.x), randomFloat(0...bounds.y)),
                velocity: SIMD2(randomFloat(-4...7), randomFloat(-3...3)),
                phase: randomFloat(0...(2 * .pi)),
                z: randomFloat(-0.2...0.7)))
        }
    }

    private func sharesEdge(_ i: Int, _ j: Int) -> Bool {
        nodes[i].edges.contains { edges[$0].a == j || edges[$0].b == j }
    }

    /// Live edge geometry from the floating node positions.
    private func edgeGeometry(_ e: Edge)
    -> (a: SIMD2<Float>, b: SIMD2<Float>, control: SIMD2<Float>, length: Float) {
        let a = nodes[e.a].position
        let b = nodes[e.b].position
        let delta = b - a
        let len = max(simd_length(delta), 1)
        let perp = SIMD2(-delta.y, delta.x) / len
        return (a, b, (a + b) / 2 + perp * e.bulge * len, len * 1.05)
    }

    // MARK: - Simulation

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        guard !nodes.isEmpty else { return }

        let intensity = max(state.intensity, 0.05)

        // The whole web floats gently; the trunk drifts least so the artery
        // stays legible as structure, the ghost layer sways most.
        let floatSpeed = 0.7 + intensity * 0.45 + state.stress * 0.5
        let amp = min(bounds.x, bounds.y) * 0.022
        for i in nodes.indices {
            let n = nodes[i]
            let levelAmp: Float = [0.45, 1.0, 1.25, 1.5][n.level]
            nodes[i].position = n.home + SIMD2(
                sin(time * n.driftFreq.x * floatSpeed + n.driftPhase.x),
                cos(time * n.driftFreq.y * floatSpeed + n.driftPhase.y)) * (amp * levelAmp)
            nodes[i].z = n.level == 3
                ? n.zBase + sin(time * n.zFreq * floatSpeed + n.zPhase) * 0.1
                : max(-1, min(1, n.zBase + sin(time * n.zFreq * floatSpeed + n.zPhase) * 0.35))
        }

        // Signature move: one token, one pulse entering the trunk at the left.
        if state.inferenceRunning {
            // Cap the visualized rate so pulses stay distinct events — past
            // ~12/s they'd merge into a continuous blaze and stop reading as
            // "one token, one pulse".
            tokenAccumulator += min(state.tokensPerSecond, 12) * dt
            while tokenAccumulator >= 1, signals.count < maxSignals {
                tokenAccumulator -= 1
                launchTokenPulse(strength: 0.9, speed: randomFloat(300...380))
            }
        } else {
            tokenAccumulator = 0
        }

        // Ambient heartbeat: dendrites fire with CPU/GPU load.
        fireAccumulator += (0.8 + state.cpuPercent * 6 + state.gpuPercent * 4) * intensity * dt
        while fireAccumulator >= 1 {
            fireAccumulator -= 1
            let outer = Int.random(in: 0..<nodes.count)
            if nodes[outer].level == 1 || nodes[outer].level == 2 {
                fire(node: outer, strength: 0.5)
            }
        }

        // Surge response: a sudden compute spike is an event, not a trend —
        // the network jolts the moment it happens.
        let load = max(state.cpuPercent, state.gpuPercent)
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            for i in trunk.shuffled().prefix(2) { fire(node: i, strength: 0.9, fanoutOverride: 6) }
            launchTokenPulse(strength: 1.0, speed: 420)
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)

        // Event bursts.
        if state.modelJustLoaded {
            for i in trunk where nodes[i].isHub { fire(node: i, strength: 1.0, fanoutOverride: 8) }
            launchTokenPulse(strength: 1.2, speed: 260)
        }
        if state.generationJustFinished {
            launchTokenPulse(strength: 1.2, speed: 170)   // slow farewell pulse
        }

        // Decay.
        for i in nodes.indices {
            nodes[i].charge = max(0, nodes[i].charge - dt * 0.9)
            nodes[i].flash = max(0, nodes[i].flash - dt * 2.6)
            nodes[i].refractory = max(0, nodes[i].refractory - dt)
        }

        // Embers fly free, slow, and die.
        for i in embers.indices {
            embers[i].velocity *= max(0, 1 - dt * 1.8)
            embers[i].position += embers[i].velocity * dt
            embers[i].life -= dt
        }
        embers.removeAll { $0.life <= 0 }

        // Dust drifts, wrapping at the edges.
        for i in motes.indices {
            motes[i].position += motes[i].velocity * dt
            if motes[i].position.x > bounds.x + 8 { motes[i].position.x = -8 }
            if motes[i].position.x < -8 { motes[i].position.x = bounds.x + 8 }
            if motes[i].position.y > bounds.y + 8 { motes[i].position.y = -8 }
            if motes[i].position.y < -8 { motes[i].position.y = bounds.y + 8 }
        }

        // Signals travel; arrivals excite (and color) the far node.
        let speedBoost = (1 + state.stress * 1.2) * (0.6 + intensity * 0.4)
        var arrived: [(signal: Signal, node: Int)] = []
        for i in signals.indices {
            signals[i].t += signals[i].speed * speedBoost * dt
                / edgeGeometry(edges[signals[i].edgeIndex]).length
            if signals[i].t >= 1 {
                let e = edges[signals[i].edgeIndex]
                arrived.append((signals[i], signals[i].forward ? e.b : e.a))
            }
        }
        signals.removeAll { $0.t >= 1 }

        for (signal, target) in arrived {
            nodes[target].charge += signal.strength
            nodes[target].flash = max(nodes[target].flash, signal.isToken ? 1.0 : 0.6)
            nodes[target].colorIndex = signal.colorIndex   // color rides the signal

            if signal.isToken, nodes[target].trunkOrder >= 0 {
                let k = nodes[target].trunkOrder
                // Shed cascades into the dendrites — but only at hubs, so the
                // storm stays articulated instead of lighting everything at once.
                for edgeIndex in nodes[target].edges
                where nodes[target].isHub && !edges[edgeIndex].isTrunk
                    && signals.count < maxSignals {
                    signals.append(Signal(
                        edgeIndex: edgeIndex, t: 0,
                        forward: edges[edgeIndex].a == target,
                        speed: randomFloat(150...220),
                        colorIndex: signal.colorIndex,
                        strength: 0.55))
                }
                // …and keep crossing the screen.
                if k < trunkEdges.count, signals.count < maxSignals {
                    signals.append(Signal(
                        edgeIndex: trunkEdges[k], t: 0, forward: true,
                        speed: signal.speed, colorIndex: signal.colorIndex,
                        strength: signal.strength, isToken: true))
                }
            } else {
                // A cascade reaching a twig's end bursts into embers.
                if nodes[target].level == 2 {
                    spawnEmbers(at: nodes[target].position, z: nodes[target].z,
                                colorIndex: signal.colorIndex)
                }
                if nodes[target].charge >= 1, nodes[target].refractory <= 0 {
                    fire(node: target, strength: 0.45)
                }
            }
        }
    }

    private func spawnEmbers(at p: SIMD2<Float>, z: Float, colorIndex: Int) {
        for _ in 0..<3 where embers.count < maxEmbers {
            let ang = randomFloat(0...(2 * .pi))
            let spd = randomFloat(30...80)
            let life = randomFloat(0.4...0.8)
            embers.append(Ember(position: p,
                                velocity: SIMD2(cos(ang), sin(ang)) * spd,
                                life: life, maxLife: life,
                                colorIndex: colorIndex, z: z))
        }
    }

    private func launchTokenPulse(strength: Float, speed: Float) {
        guard let first = trunkEdges.first, signals.count < maxSignals else { return }
        let color = Int.random(in: 0..<max(theme.palette.count, 1))
        nodes[trunk[0]].flash = 1
        nodes[trunk[0]].colorIndex = color
        signals.append(Signal(edgeIndex: first, t: 0, forward: true, speed: speed,
                              colorIndex: color, strength: strength, isToken: true))
    }

    private func fire(node i: Int, strength: Float, fanoutOverride: Int? = nil) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].flash = max(nodes[i].flash, 0.8)
        nodes[i].charge = 0
        nodes[i].refractory = 0.55
        let fanout = fanoutOverride ?? 2
        for edgeIndex in nodes[i].edges.shuffled().prefix(fanout) {
            guard signals.count < maxSignals,
                  !edges[edgeIndex].isTrunk, !edges[edgeIndex].isGhost else { continue }
            signals.append(Signal(
                edgeIndex: edgeIndex, t: 0,
                forward: edges[edgeIndex].a == i,
                speed: randomFloat(150...240),
                colorIndex: nodes[i].colorIndex,
                strength: strength))
        }
    }

    // MARK: - Render

    /// The resting material: ash-silver, faintly tinted by the theme. Color
    /// belongs to signal; this is what everything cools back down to.
    private func ash(_ alpha: Float) -> SIMD4<Float> {
        var c = simd_mix(SIMD4(0.72, 0.76, 0.82, 1), theme.calmColor,
                         SIMD4(repeating: 0.22))
        c.w = alpha
        return c
    }

    /// Push a palette color away from white so it survives HDR bloom.
    /// Pastel themes (Glass) otherwise render "color" as more white.
    private func deepen(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var d = simd_mix(c, c * c, SIMD4(repeating: 0.75))
        d.w = c.w
        return d
    }

    public func render(renderer: Renderer) {
        guard !nodes.isEmpty else { return }
        let stress = renderer.currentState.stress
        var out: [Particle] = []
        out.reserveCapacity(edges.count * 16 + nodes.count * 2 + signals.count * 3
                            + embers.count + motes.count)

        // Synaptic dust: the faintest layer, drifting through the fog.
        for m in motes {
            var c = ash(0.030 + 0.015 * sin(time * 0.7 + m.phase))
            c.w = max(c.w, 0.015)
            out.append(Particle(position: m.position, color: c, size: 1.2,
                                glow: 0, depth: m.z))
        }

        // Fibers: silver dotted arcs. Ghost-web fibers sit deep and dim; the
        // trunk runs densest and brightest with a slow shimmer traveling its
        // length. A fiber only takes color while an endpoint is excited.
        for e in edges {
            let g = edgeGeometry(e)
            let za = nodes[e.a].z, zb = nodes[e.b].z

            if e.isGhost {
                let c = ash(0.028)
                let dotCount = max(3, Int(g.length / 20))
                for d in 1..<dotCount {
                    let t = Float(d) / Float(dotCount)
                    out.append(Particle(position: bezier(g.a, g.control, g.b, t),
                                        color: c, size: 0.8, glow: 0,
                                        depth: lerp(za, zb, t)))
                }
                continue
            }

            let excitement = min(max(nodes[e.a].charge + nodes[e.a].flash,
                                     nodes[e.b].charge + nodes[e.b].flash), 1)
            let hotIndex = nodes[e.a].flash > nodes[e.b].flash
                ? nodes[e.a].colorIndex : nodes[e.b].colorIndex
            var c = simd_mix(ash(1), deepen(theme.color(hotIndex)),
                             SIMD4(repeating: excitement * 0.65))
            c = simd_mix(c, theme.stressColor(stress), SIMD4(repeating: stress * 0.25 * excitement))
            let dotCount = max(3, Int(g.length / (e.isTrunk ? 6 : 13)))
            for d in 1..<dotCount {
                let t = Float(d) / Float(dotCount)
                let pos = bezier(g.a, g.control, g.b, t)
                var alpha = (e.isTrunk ? 0.055 : 0.045) + excitement * 0.08
                if e.isTrunk {
                    // The pulse under the skin: a shimmer travels the artery.
                    alpha *= 0.75 + 0.45 * sin(time * 1.6 - pos.x * 0.012)
                }
                var dc = c
                dc.w = alpha
                out.append(Particle(position: pos, color: dc,
                                    size: e.isTrunk ? 1.35 : 0.9,
                                    glow: (e.isTrunk ? 0.08 : 0.0) + excitement * 0.16,
                                    depth: lerp(za, zb, t)))
            }
        }

        // Signals: the only fully-colored things on screen. Token pulses are
        // unmistakable — larger, hotter, dragging a comet tail up the trunk.
        for s in signals {
            let e = edges[s.edgeIndex]
            let t = s.forward ? s.t : 1 - s.t
            let g = edgeGeometry(e)
            let pos = bezier(g.a, g.control, g.b, t)
            let ahead = bezier(g.a, g.control, g.b, min(t + 0.03, 1))
            let velocity = (ahead - pos) * 22 * (s.forward ? 1 : -1)
            var c = simd_mix(deepen(theme.color(s.colorIndex)), theme.stressColor(stress),
                             SIMD4(repeating: stress * 0.35))
            c.w = 1.0
            let depth = lerp(nodes[e.a].z, nodes[e.b].z, t)
            out.append(Particle(position: pos, velocity: velocity, color: c,
                                size: (s.isToken ? 2.4 : 1.5) * theme.particleScale,
                                glow: s.isToken ? 1.35 : 1.1,
                                shape: .streak, depth: depth))
            if s.isToken {
                for (dt2, fade) in [(Float(0.028), Float(0.55)), (Float(0.055), Float(0.28))] {
                    let tt = max(t - dt2 * (s.forward ? 1 : -1), 0)
                    var tc = c
                    tc.w = fade
                    out.append(Particle(position: bezier(g.a, g.control, g.b, tt),
                                        velocity: velocity * 0.6, color: tc,
                                        size: 1.6 * theme.particleScale * fade + 0.8,
                                        glow: 0.7 * fade, shape: .streak, depth: depth))
                }
            }
        }

        // Embers: cascade endings that fly free and die.
        for em in embers {
            let lifeT = em.life / em.maxLife
            var c = deepen(theme.color(em.colorIndex))
            c.w = lifeT * 0.85
            out.append(Particle(position: em.position, velocity: em.velocity,
                                color: c, size: 1.1 + lifeT * 0.6,
                                glow: 0.5 * lifeT, shape: .streak, depth: em.z))
        }

        // Nodes: silver at rest; an excited node blooms into the color the
        // signal carried, then cools back to ash. Ghost nodes only breathe.
        for n in nodes {
            if n.level == 3 {
                var c = ash(0.20 + 0.10 * sin(time * 0.5 + n.wobblePhase))
                c.w *= 1.0
                out.append(Particle(position: n.position, color: c,
                                    size: n.radius, glow: 0.04, depth: n.z))
                continue
            }

            let excitement = min(n.charge + n.flash, 1.2)
            let wobble = 1 + sin(time * 1.8 + n.wobblePhase) * 0.06

            var halo = simd_mix(ash(1), deepen(theme.color(n.colorIndex)),
                                SIMD4(repeating: min(excitement, 1) * 0.8))
            halo.w = 0.03 + excitement * 0.11
            out.append(Particle(position: n.position, color: halo,
                                size: n.radius * 2.1 * wobble,
                                glow: 0.12 + excitement * 0.4, depth: n.z))

            var core = simd_mix(ash(1), deepen(theme.color(n.colorIndex)),
                                SIMD4(repeating: min(excitement, 1)))
            core = simd_mix(core, theme.stressColor(stress),
                            SIMD4(repeating: stress * 0.3 * min(excitement, 1)))
            core = simd_mix(core, SIMD4(1, 1, 1, 1), SIMD4(repeating: n.flash * 0.18))
            core.w = 0.8 + excitement * 0.2
            out.append(Particle(position: n.position, color: core,
                                size: n.radius * theme.particleScale * wobble,
                                glow: 0.3 + excitement * 1.0, depth: n.z))
        }
        renderer.submit(out)
    }

    /// Test hooks.
    public var testCounts: (nodes: Int, edges: Int, signals: Int) {
        (nodes.count, edges.count, signals.count)
    }
}
