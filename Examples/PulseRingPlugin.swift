import Foundation
import simd
import RAMbleKit

/// Example third-party plugin: a minimal breathing ring.
///
/// The ring's radius follows RAM usage, its color follows the stress score,
/// and token generation makes it shimmer. ~60 lines, no Metal knowledge needed.
///
/// To use it, add this file to your build and register it before the app runs
/// (e.g. at the top of main.swift):
///
///     PluginRegistry.shared.register(name: "Pulse Ring") { PulseRingPlugin() }
///
/// It then appears in the menu bar Animation menu and Settings automatically.
/// See docs/PLUGIN_SDK.md for the full plugin guide.
public final class PulseRingPlugin: AnimationPlugin {
    public let name = "Pulse Ring"

    private var bounds = SIMD2<Float>(800, 600)
    private var theme = Themes.glass
    private var time: Float = 0
    private var smoothedRAM: Float = 0
    private var shimmer: Float = 0

    private let segmentCount = 140

    public init() {}

    public func prepare(bounds: SIMD2<Float>, theme: Theme) {
        self.bounds = bounds
        self.theme = theme
    }

    public func themeDidChange(_ theme: Theme) { self.theme = theme }

    public func update(state: SystemState, deltaTime: Float) {
        time += deltaTime
        smoothedRAM += (state.ramPercent - smoothedRAM) * min(1, deltaTime * 2)
        let targetShimmer: Float = state.inferenceRunning ? 1 : 0
        shimmer += (targetShimmer - shimmer) * min(1, deltaTime * 3)
        // Stash stress for render via the state we care about.
        lastStress = state.stress
        breathe = 1 + sin(time * (1 + state.cpuPercent * 4)) * 0.03
    }

    private var lastStress: Float = 0
    private var breathe: Float = 1

    public func render(renderer: Renderer) {
        let center = bounds * 0.5
        let radius = min(bounds.x, bounds.y) * (0.15 + smoothedRAM * 0.25) * breathe
        var out: [Particle] = []
        out.reserveCapacity(segmentCount)
        for i in 0..<segmentCount {
            let a = Float(i) / Float(segmentCount) * 2 * .pi
            let wobble = shimmer * sin(a * 9 + time * 12) * radius * 0.04
            var color = theme.stressColor(lastStress)
            color.w *= 0.8
            out.append(Particle(
                position: center + SIMD2(cos(a), sin(a)) * (radius + wobble),
                color: color,
                size: 2.5 * theme.particleScale,
                glow: 0.3 + shimmer * 0.5))
        }
        renderer.submit(out)
    }
}
