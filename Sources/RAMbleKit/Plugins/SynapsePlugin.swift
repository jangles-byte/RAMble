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
        var position: SIMD2<Float>
        var radius: Float
        var colorIndex: Int       // palette class, like the varied node colors
        var charge: Float = 0     // 0…1 excitement; >= 1 triggers a fire
        var flash: Float = 0      // render flash after firing, decays fast
        var refractory: Float = 0 // cooldown before it may fire again
        var edges: [Int] = []     // indices into `edges`
        var isHub: Bool = false
        var wobblePhase: Float = 0
    }

    private struct Edge {
        var a: Int
        var b: Int
        var control: SIMD2<Float> // quadratic bezier control point (the arc)
        var length: Float
        var dots: [SIMD2<Float>]  // precomputed dotted-line sample points
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

    private let nodeCount = 88
    private let hubCount = 6
    private let maxSignals = 900

    public init() {}

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

        // Scatter nodes with a minimum spacing, denser toward the middle.
        let margin = min(bounds.x, bounds.y) * 0.07
        let minDist = min(bounds.x, bounds.y) * 0.055
        var attempts = 0
        while nodes.count < nodeCount, attempts < nodeCount * 60 {
            attempts += 1
            // Bias positions toward the center for an organic cluster.
            let u = (randomFloat(0...1) + randomFloat(0...1)) / 2
            let v = (randomFloat(0...1) + randomFloat(0...1)) / 2
            let p = SIMD2(margin + u * (bounds.x - margin * 2),
                          margin + v * (bounds.y - margin * 2))
            if nodes.allSatisfy({ simd_distance($0.position, p) > minDist }) {
                nodes.append(Node(
                    position: p,
                    radius: randomFloat(2.6...4.4),
                    colorIndex: Int.random(in: 0..<max(theme.palette.count, 1)),
                    wobblePhase: randomFloat(0...(2 * .pi))))
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
            nodes[i].radius *= 1.8
        }

        // Edges: everyone links to their 2 nearest neighbors; hubs reach out
        // with extra long-range fibers, like the dense center of the inspo.
        var seen = Set<Int>()
        func addEdge(_ i: Int, _ j: Int) {
            guard i != j else { return }
            let key = min(i, j) * 100_000 + max(i, j)
            guard !seen.contains(key) else { return }
            seen.insert(key)

            let a = nodes[i].position
            let b = nodes[j].position
            let mid = (a + b) / 2
            let delta = b - a
            let length = simd_length(delta)
            let perp = SIMD2(-delta.y, delta.x) / max(length, 1)
            // Longer fibers arc more, like relaxed cables.
            let bulge = length * randomFloat(0.10...0.30) * (Bool.random() ? 1 : -1)
            let control = mid + perp * bulge

            var dots: [SIMD2<Float>] = []
            let dotCount = max(3, Int(length / 16))
            for d in 1..<dotCount {
                dots.append(bezier(a, control, b, Float(d) / Float(dotCount)))
            }
            let edgeIndex = edges.count
            edges.append(Edge(a: i, b: j, control: control,
                              length: max(length * 1.05, 1), dots: dots))
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

    // MARK: - Simulation

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        guard !nodes.isEmpty else { return }

        let intensity = max(state.intensity, 0.05)

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
            signals[i].t += signals[i].speed * speedBoost * dt / edges[signals[i].edgeIndex].length
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

        // Fibers: faint dotted arcs, waking up when an endpoint is excited.
        for e in edges {
            let excitement = max(nodes[e.a].charge + nodes[e.a].flash,
                                 nodes[e.b].charge + nodes[e.b].flash)
            var c = theme.color(2)
            c.w = 0.05 + min(excitement, 1) * 0.14
            for dot in e.dots {
                out.append(Particle(position: dot, color: c, size: 1.0,
                                    glow: excitement * 0.2))
            }
        }

        // Signals: bright pulses racing along the fibers (trails come free
        // from the renderer's accumulation buffer).
        for s in signals {
            let e = edges[s.edgeIndex]
            let t = s.forward ? s.t : 1 - s.t
            let a = nodes[e.a].position
            let b = nodes[e.b].position
            let pos = bezier(a, e.control, b, t)
            // Finite-difference tangent for streak orientation.
            let ahead = bezier(a, e.control, b, min(t + 0.03, 1))
            let velocity = (ahead - pos) * 30 * (s.forward ? 1 : -1)
            var c = simd_mix(theme.color(s.colorIndex), theme.calmColor,
                             SIMD4(repeating: 0.35))
            c.w = 0.95
            out.append(Particle(position: pos, velocity: velocity, color: c,
                                size: 2.2 * theme.particleScale, glow: 0.85,
                                shape: .streak))
        }

        // Nodes: soft halo + colored core; firing nodes flash white-hot.
        for n in nodes {
            let excitement = min(n.charge + n.flash, 1.5)
            let wobble = 1 + sin(time * 1.8 + n.wobblePhase) * 0.06
            var halo = theme.stressColor(renderer.currentState.stress * 0.6)
            halo.w = 0.05 + excitement * 0.22
            out.append(Particle(position: n.position, color: halo,
                                size: n.radius * 3.2 * wobble,
                                glow: 0.2 + excitement * 0.5))

            var core = theme.color(n.colorIndex)
            core = simd_mix(core, SIMD4(1, 1, 1, 1), SIMD4(repeating: n.flash * 0.7))
            core.w = 0.75 + excitement * 0.25
            out.append(Particle(position: n.position, color: core,
                                size: n.radius * theme.particleScale * wobble,
                                glow: 0.35 + excitement * 0.9))
        }
        renderer.submit(out)
    }

    /// Test hooks.
    public var testCounts: (nodes: Int, edges: Int, signals: Int) {
        (nodes.count, edges.count, signals.count)
    }
}
