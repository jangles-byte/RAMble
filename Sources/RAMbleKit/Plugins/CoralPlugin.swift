import Foundation
import simd

/// Coral — differential growth as the machine's accretion
/// (docs/coral-design.md). A closed chain of nodes repels locally, stays
/// linked, and inserts new nodes where segments stretch — brain folds,
/// ruffled reef edges. The shape is a fossil record of the machine's work:
/// load grows folds, the growing edge glows young, and a model load wipes
/// the reef clean like a tide.
///
/// Mapping:
/// - CPU + GPU  → growth rate (insertions per second)
/// - Tokens     → growth spurts; the rim burns a coastline of fresh color
/// - RAM        → the organism's size budget
/// - Stress     → folds tighten and wrinkle nervously
/// - Swap       → the old body stains red
/// - Model load → the reef resets to a new-born ring
public final class CoralPlugin: AnimationPlugin {
    public let name = "Coral"

    private struct CoralNode {
        var position: SIMD2<Float>
        var age: Float = 1        // 1 = just born, decays to 0 (ash)
    }

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var chain: [CoralNode] = []
    private var time: Float = 0
    private var growthAccumulator: Float = 0
    private var colorAnchor = 0
    private var loadEma: Float = 0
    private var surgeArmed = true

    private let restLen: Float = 8
    private let maxLen: Float = 11
    private let minLen: Float = 4
    private let hashCell: Float = 16
    private let hardCap = 1900

    public init() {}

    public var preferredTrailPersistence: Float? { 0.45 }

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
        seedRing()
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    private func seedRing() {
        chain.removeAll(keepingCapacity: true)
        let c = bounds * 0.5
        let r = min(bounds.x, bounds.y) * 0.06
        let n = 42
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            chain.append(CoralNode(position: c + SIMD2(cos(a), sin(a)) * r, age: 0.4))
        }
    }

    public func update(state: SystemState, deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt
        let intensity = max(state.intensity, 0.05)
        let stress = state.stress

        if state.modelJustLoaded {
            colorAnchor += 1
            seedRing()
        }
        guard chain.count > 4 else { return }

        // Personal space shrinks under stress — the folds wrinkle tighter.
        // Radius ≈ 1.5× maxLen per the reference, or folds never form.
        let repelR: Float = 16 - stress * 4
        let repelR2 = repelR * repelR

        // Spatial hash for repulsion.
        let cols = max(1, Int(bounds.x / hashCell) + 1)
        let rows = max(1, Int(bounds.y / hashCell) + 1)
        var grid = [[Int]](repeating: [], count: cols * rows)
        for (i, n) in chain.enumerated() {
            let cx = min(max(Int(n.position.x / hashCell), 0), cols - 1)
            let cy = min(max(Int(n.position.y / hashCell), 0), rows - 1)
            grid[cy * cols + cx].append(i)
        }

        let count = chain.count
        var forces = [SIMD2<Float>](repeating: .zero, count: count)
        let centroid = chain.reduce(SIMD2<Float>(0, 0)) { $0 + $1.position }
            / Float(count)

        for i in 0..<count {
            let p = chain[i].position
            var f = SIMD2<Float>(0, 0)

            // Local repulsion from any nearby node (this makes the folds).
            let cx = min(max(Int(p.x / hashCell), 0), cols - 1)
            let cy = min(max(Int(p.y / hashCell), 0), rows - 1)
            for gy in max(cy - 1, 0)...min(cy + 1, rows - 1) {
                for gx in max(cx - 1, 0)...min(cx + 1, cols - 1) {
                    for j in grid[gy * cols + gx] where j != i {
                        let d = p - chain[j].position
                        let d2 = simd_length_squared(d)
                        if d2 < repelR2, d2 > 0.01 { f += d / d2 * 30 }
                    }
                }
            }

            // Chain springs to the two neighbours — soft, so surplus length
            // folds instead of snapping taut.
            for j in [(i + count - 1) % count, (i + 1) % count] {
                let d = chain[j].position - p
                let len = max(simd_length(d), 0.001)
                f += d / len * (len - restLen) * 2.2
            }

            // Outward push plus a tangential wiggle — the asymmetry that
            // seeds folds. Purely radial force grows the dull balloon.
            let outward = p - centroid
            let oLen = max(simd_length(outward), 0.001)
            let perp = SIMD2(-outward.y, outward.x) / oLen
            f += outward / oLen * 2.0
            f += perp * sin(time * 0.6 + Float(i) * 0.53) * 2.4
            f += SIMD2(randomFloat(-1...1), randomFloat(-1...1)) * (0.8 + stress * 6)

            forces[i] = f
        }

        // Overdamped integration; clamp inside the screen with a soft margin.
        for i in 0..<count {
            var p = chain[i].position + forces[i] * dt * 3.2
            p.x = min(max(p.x, bounds.x * 0.03), bounds.x * 0.97)
            p.y = min(max(p.y, bounds.y * 0.04), bounds.y * 0.96)
            chain[i].position = p
            chain[i].age = max(0, chain[i].age - dt * 0.25)
        }

        // Surge response: a compute spike is a growth spurt — the rim
        // erupts with a burst of fresh, glowing insertions.
        let load = max(state.cpuPercent, state.gpuPercent)
        if surgeArmed, load - loadEma > 0.18 {
            surgeArmed = false
            growthAccumulator += 14
        } else if load - loadEma < 0.08 {
            surgeArmed = true
        }
        loadEma += (load - loadEma) * min(1, dt * 0.8)

        // Growth: insertions are the work made visible. A few per frame, max.
        let sizeCap = min(Int(300 + state.ramPercent * 1300), hardCap)
        var rate = (0.5 + state.cpuPercent * 5 + state.gpuPercent * 4) * intensity * 6
        if state.inferenceRunning { rate += min(state.tokensPerSecond, 12) * 1.5 }
        growthAccumulator += rate * dt
        // Growth inserts at RANDOM segments, not just stretched ones — a
        // convex ring never stretches unevenly, so stretch-only insertion
        // grows the dull balloon forever. Surplus perimeter has nowhere to
        // go, and *that* is what buckles the curve into folds.
        var inserted = 0
        while growthAccumulator >= 1, inserted < 6, chain.count < sizeCap {
            growthAccumulator -= 1
            inserted += 1
            let i = Int.random(in: 0..<chain.count)
            let j = (i + 1) % chain.count
            let mid = (chain[i].position + chain[j].position) * 0.5
                + SIMD2(randomFloat(-1.5...1.5), randomFloat(-1.5...1.5))
            chain.insert(CoralNode(position: mid, age: 1), at: i + 1)
        }

        // Remove collapsed segments.
        if chain.count > 48 {
            var i = 0
            while i < chain.count, chain.count > 48 {
                let j = (i + 1) % chain.count
                if simd_distance(chain[i].position, chain[j].position) < minLen {
                    chain.remove(at: j == 0 ? i : j)
                }
                i += 1
            }
        }
    }

    // MARK: - Render

    private func deepen(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var d = simd_mix(c, c * c, SIMD4(repeating: 0.75))
        d.w = c.w
        return d
    }

    public func render(renderer: Renderer) {
        guard chain.count > 4 else { return }
        let state = renderer.currentState
        var out: [Particle] = []
        out.reserveCapacity(chain.count * 2)

        var ash = simd_mix(SIMD4<Float>(0.72, 0.76, 0.82, 1), theme.calmColor,
                           SIMD4(repeating: 0.22))
        ash = simd_mix(ash, theme.warningColor, SIMD4(repeating: state.swapPercent * 0.5))
        let young = deepen(theme.color(colorAnchor))

        for (i, n) in chain.enumerated() {
            // Youth earns the color: the growing edge glows, the body is ash.
            var c = simd_mix(ash, young, SIMD4(repeating: min(n.age * 1.4, 1)))
            c.w = 0.6 + n.age * 0.4
            out.append(Particle(position: n.position, color: c,
                                size: 1.9 + n.age * 0.9,
                                glow: 0.1 + n.age * 0.9))

            // A midpoint dot per segment keeps the curve reading as one line.
            let next = chain[(i + 1) % chain.count]
            var mc = ash
            mc.w = 0.22
            out.append(Particle(position: (n.position + next.position) * 0.5,
                                color: mc, size: 1.0, glow: 0))
        }
        renderer.submit(out)
    }

    /// Test hook.
    public var testCounts: (nodes: Int, capReached: Bool) {
        (chain.count, chain.count >= hardCap)
    }
}
