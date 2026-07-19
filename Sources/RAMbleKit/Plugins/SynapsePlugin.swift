import Foundation
import simd

/// Synapse — the flagship. A living neural graph: glowing nodes joined by
/// curved fibers, with signal pulses racing along the edges and triggering
/// cascade fires downstream, like watching an LLM think.
///
/// Mapping:
/// - Baseline firing rate follows the intensity setting and CPU/GPU load.
/// - Token generation pours fuel on it — cascades storm while a model talks.
/// - Stress heats node colors toward the warning tone and speeds signals up.
/// - Model load detonates a burst from the biggest hub; generation finish
///   sends a farewell ripple.
public final class SynapsePlugin: AnimationPlugin {
    public let name = "Synapse"

    private struct Node {
        var home: SIMD2<Float>    // anchor; the node floats around this
        var position: SIMD2<Float>
        var z: Float = 0          // pseudo-3D depth, -1 near … +1 far
        var radius: Float
        var colorIndex: Int       // palette class, like the varied node colors
        var charge: Float = 0     // 0…1 excitement; >= 1 triggers a fire
        var flash: Float = 0      // render flash after firing, decays fast
        var refractory: Float = 0 // cooldown before it may fire again
        var edges: [Int] = []     // indices into `edges`
        var isHub: Bool = false
        var wobblePhase: Float = 0
        // Per-node drift: slow 3D Lissajous float, unique to each node.
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
        var bulge: Float          // perpendicular arc ratio of live length
    }

    private struct Signal {
        var edgeIndex: Int
        var t: Float              // 0…1 along the edge
        var forward: Bool         // a→b or b→a
        var speed: Float          // points/sec
        var colorIndex: Int
        var strength: Float       // how much charge it delivers
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var nodes: [Node] = []
    private var edges: [Edge] = []
    private var signals: [Signal] = []
    private var fireAccumulator: Float = 0
    private var time: Float = 0

    private let nodeCount = 64
    private let hubCount = 5
    private let maxSignals = 900

    public init() {}

    // Static node emitters would pile up in the trail buffer; keep persistence
    // low so the signals still streak but the nodes stay crisp.
    public var preferredTrailPersistence: Float? { 0.5 }

    // MARK: - Graph construction

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        signals.removeAll(keepingCapacity: true)
        buildGraph()
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func bezier(_ a: SIMD2<Float>, _ c: SIMD2<Float>, _ b: SIMD2<Float>,
                        _ t: Float) -> SIMD2<Float> {
        let u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }

    private func buildGraph() {
        nodes.removeAll()
        edges.removeAll()
        guard bounds.x > 64, bounds.y > 64 else { return }

        // Scatter nodes with a generous minimum spacing so halos never merge
        // into blobs, with only a gentle pull toward the middle.
        let margin = min(bounds.x, bounds.y) * 0.07
        let minDist = min(bounds.x, bounds.y) * 0.085
        var attempts = 0
        while nodes.count < nodeCount, attempts < nodeCount * 80 {
            attempts += 1
            // Slight center bias (blend one uniform with one triangular sample).
            let u = randomFloat(0...1) * 0.45 + (randomFloat(0...1) + randomFloat(0...1)) / 2 * 0.55
            let v = randomFloat(0...1) * 0.45 + (randomFloat(0...1) + randomFloat(0...1)) / 2 * 0.55
            let p = SIMD2(margin + u * (bounds.x - margin * 2),
                          margin + v * (bounds.y - margin * 2))
            if nodes.allSatisfy({ simd_distance($0.home, p) > minDist }) {
                nodes.append(Node(
                    home: p,
                    position: p,
                    radius: randomFloat(2.6...4.4),
                    colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
                    wobblePhase: randomFloat(0...(2 * .pi)),
                    driftFreq: SIMD2(randomFloat(0.05...0.16), randomFloat(0.05...0.16)),
                    driftPhase: SIMD2(randomFloat(0...(2 * .pi)), randomFloat(0...(2 * .pi))),
                    zFreq: randomFloat(0.04...0.11),
                    zPhase: randomFloat(0...(2 * .pi)),
                    zBase: randomFloat(-0.5...0.5)))
            }
        }
        guard nodes.count > 8 else { return }

        // Promote the most central nodes to hubs (bigger, better connected).
        let center = bounds * 0.5
        let byCentrality = nodes.indices.sorted {
            simd_distance(nodes[$0].position, center) < simd_distance(nodes[$1].position, center)
        }
        for i in byCentrality.prefix(hubCount) {
            nodes[i].isHub = true
            nodes[i].radius *= 1.55
        }

        // Edges: everyone links to their 2 nearest neighbors; hubs reach out
        // with extra long-range fibers, like the dense center of the inspo.
        var seen = Set<Int>()
        func addEdge(_ i: Int, _ j: Int) {
            guard i != j else { return }
            let key = min(i, j) * 100_000 + max(i, j)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let edgeIndex = edges.count
            // Arc ratio only — geometry evaluates live as the nodes float.
            edges.append(Edge(a: i, b: j,
                              bulge: randomFloat(0.10...0.30) * (Bool.random() ? 1 : -1)))
            nodes[i].edges.append(edgeIndex)
            nodes[j].edges.append(edgeIndex)
        }

        for i in nodes.indices {
            let nearest = nodes.indices
                .filter { $0 != i }
                .sorted { simd_distance(nodes[$0].position, nodes[i].position)
                        < simd_distance(nodes[$1].position, nodes[i].position) }
            for j in nearest.prefix(2) { addEdge(i, j) }
        }
        for i in nodes.indices where nodes[i].isHub {
            for _ in 0..<6 { addEdge(i, Int.random(in: 0..<nodes.count)) }
        }
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

        // The whole constellation floats: each node wanders a slow, unique
        // 3D Lissajous orbit around its home. Edges and signals follow live.
        let floatSpeed = 0.7 + intensity * 0.45 + state.stress * 0.5
        let amp = min(bounds.x, bounds.y) * 0.030
        for i in nodes.indices {
            let n = nodes[i]
            let a = amp * (n.isHub ? 0.55 : 1.0)
            nodes[i].position = n.home + SIMD2(
                sin(time * n.driftFreq.x * floatSpeed + n.driftPhase.x),
                cos(time * n.driftFreq.y * floatSpeed + n.driftPhase.y)) * a
            nodes[i].z = max(-1, min(1, n.zBase + sin(time * n.zFreq * floatSpeed + n.zPhase) * 0.45))
        }

        // Spontaneous firing: the network's resting heartbeat plus load.
        var fireRate: Float = (1.5 + state.cpuPercent * 14 + state.gpuPercent * 10)
            * intensity
        if state.inferenceRunning {
            fireRate += min(state.tokensPerSecond, 100) * 0.6 * intensity
        }
        fireAccumulator += fireRate * dt
        while fireAccumulator >= 1 {
            fireAccumulator -= 1
            fire(node: Int.random(in: 0..<nodes.count), strength: 0.55)
        }

        // Event bursts.
        if state.modelJustLoaded, let hub = nodes.indices.first(where: { nodes[$0].isHub }) {
            fire(node: hub, strength: 1.0, fanoutOverride: 12)
        }
        if state.generationJustFinished {
            for i in nodes.indices where nodes[i].isHub { fire(node: i, strength: 0.7) }
        }

        // Node decay.
        for i in nodes.indices {
            nodes[i].charge = max(0, nodes[i].charge - dt * 0.9)
            nodes[i].flash = max(0, nodes[i].flash - dt * 3.2)
            nodes[i].refractory = max(0, nodes[i].refractory - dt)
        }

        // Signals travel; arrivals excite the far node — cascades happen
        // when an excited node tips over its threshold.
        let speedBoost = (1 + state.stress * 1.6) * (0.5 + intensity * 0.5)
        var arrived: [(node: Int, strength: Float)] = []
        for i in signals.indices {
            signals[i].t += signals[i].speed * speedBoost * dt
                / edgeGeometry(edges[signals[i].edgeIndex]).length
            if signals[i].t >= 1 {
                let e = edges[signals[i].edgeIndex]
                let target = signals[i].forward ? e.b : e.a
                arrived.append((target, signals[i].strength))
            }
        }
        signals.removeAll { $0.t >= 1 }
        for (target, strength) in arrived {
            nodes[target].charge += strength
            nodes[target].flash = max(nodes[target].flash, 0.5)
            if nodes[target].charge >= 1, nodes[target].refractory <= 0 {
                fire(node: target, strength: 0.5)
            }
        }
    }

    private func fire(node i: Int, strength: Float, fanoutOverride: Int? = nil) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].flash = 1
        nodes[i].charge = 0
        nodes[i].refractory = 0.55
        let fanout = fanoutOverride ?? (nodes[i].isHub ? 4 : 2)
        for edgeIndex in nodes[i].edges.shuffled().prefix(fanout) {
            guard signals.count < maxSignals else { break }
            signals.append(Signal(
                edgeIndex: edgeIndex,
                t: 0,
                forward: edges[edgeIndex].a == i,
                speed: randomFloat(150...240),
                colorIndex: nodes[i].colorIndex,
                strength: strength))
        }
    }

    // MARK: - Render

    public func render(renderer: Renderer) {
        guard !nodes.isEmpty else { return }
        var out: [Particle] = []
        out.reserveCapacity(edges.count * 8 + nodes.count * 3 + signals.count * 2)

        // Fibers: faint dotted arcs evaluated live from the floating nodes,
        // waking up when an endpoint is excited. Depth blends along the arc.
        for e in edges {
            let excitement = max(nodes[e.a].charge + nodes[e.a].flash,
                                 nodes[e.b].charge + nodes[e.b].flash)
            var c = theme.color(2)
            c.w = 0.04 + min(excitement, 1) * 0.11
            let g = edgeGeometry(e)
            let za = nodes[e.a].z, zb = nodes[e.b].z
            let dotCount = max(3, Int(g.length / 16))
            for d in 1..<dotCount {
                let t = Float(d) / Float(dotCount)
                out.append(Particle(position: bezier(g.a, g.control, g.b, t),
                                    color: c, size: 0.9,
                                    glow: excitement * 0.18,
                                    depth: lerp(za, zb, t)))
            }
        }

        // Signals: bright pulses racing along the fibers (trails come free
        // from the renderer's accumulation buffer).
        for s in signals {
            let e = edges[s.edgeIndex]
            let t = s.forward ? s.t : 1 - s.t
            let g = edgeGeometry(e)
            let pos = bezier(g.a, g.control, g.b, t)
            // Finite-difference tangent for streak orientation.
            let ahead = bezier(g.a, g.control, g.b, min(t + 0.03, 1))
            let velocity = (ahead - pos) * 22 * (s.forward ? 1 : -1)
            let signalDepth = lerp(nodes[e.a].z, nodes[e.b].z, t)
            // Saturated, small, and hot so it blooms as a dart of light rather
            // than smearing into a chrome teardrop.
            var c = simd_mix(theme.color(s.colorIndex), theme.calmColor,
                             SIMD4(repeating: 0.18))
            c.w = 1.0
            out.append(Particle(position: pos, velocity: velocity, color: c,
                                size: 1.5 * theme.particleScale, glow: 1.25,
                                shape: .streak, depth: signalDepth))
        }

        // Nodes: soft halo + colored core; firing nodes flash white-hot.
        // Kept restrained so the HDR bloom does the glowing, not raw size —
        // crisp colored nodes over black, not overlapping cotton-wool.
        for n in nodes {
            let excitement = min(n.charge + n.flash, 1.5)
            let wobble = 1 + sin(time * 1.8 + n.wobblePhase) * 0.06
            var halo = simd_mix(theme.color(n.colorIndex),
                                theme.stressColor(renderer.currentState.stress * 0.6),
                                SIMD4(repeating: 0.4))
            halo.w = 0.03 + excitement * 0.10
            out.append(Particle(position: n.position, color: halo,
                                size: n.radius * 2.0 * wobble,
                                glow: 0.15 + excitement * 0.35, depth: n.z))

            var core = theme.color(n.colorIndex)
            core = simd_mix(core, SIMD4(1, 1, 1, 1), SIMD4(repeating: n.flash * 0.55))
            core.w = 0.85 + excitement * 0.15
            out.append(Particle(position: n.position, color: core,
                                size: n.radius * theme.particleScale * wobble,
                                glow: 0.35 + excitement * 0.9, depth: n.z))
        }
        renderer.submit(out)
    }

    /// Test hooks.
    public var testCounts: (nodes: Int, edges: Int, signals: Int) {
        (nodes.count, edges.count, signals.count)
    }
}
