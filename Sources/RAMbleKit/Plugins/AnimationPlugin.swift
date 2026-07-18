import Foundation
import simd

/// A modular animation. Plugins receive the unified `SystemState` and never
/// query the operating system directly.
///
/// Lifecycle:
/// 1. `prepare(bounds:theme:)` — called when the plugin becomes active or the
///    view resizes. Build/rebuild your simulation here.
/// 2. `update(state:deltaTime:)` — once per frame with the latest state.
/// 3. `render(renderer:)` — submit particles via `renderer.submit(_:)`.
public protocol AnimationPlugin: AnyObject {
    var name: String { get }

    func prepare(bounds: SIMD2<Float>, theme: Theme)
    func update(state: SystemState, deltaTime: Float)
    func render(renderer: Renderer)

    /// Called when the user switches themes while the plugin is active.
    func themeDidChange(_ theme: Theme)

    /// Called whenever the *screen's* extent in scene coordinates changes
    /// (i.e. when the scale setting moves). The scene box (`bounds` from
    /// `prepare`) holds the structure; `worldMin`…`worldMax` are the real
    /// screen edges — physics objects may escape the scene but are trapped
    /// by the world. At scale 1 the two are identical.
    func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>)
}

public extension AnimationPlugin {
    func themeDidChange(_ theme: Theme) {}
    func worldChanged(worldMin: SIMD2<Float>, worldMax: SIMD2<Float>) {}
}

/// Factory + lookup for available animations. Register custom plugins here
/// before the app starts (see docs/PLUGIN_SDK.md).
public final class PluginRegistry {
    public static let shared = PluginRegistry()

    private var factories: [(name: String, make: () -> AnimationPlugin)] = []

    private init() {
        register(name: "Synapse") { SynapsePlugin() }
        register(name: "Plinko") { PlinkoPlugin() }
        register(name: "Galaxy") { GalaxyPlugin() }
        register(name: "Water Tank") { WaterTankPlugin() }
        register(name: "Motherboard") { MotherboardPlugin() }
        register(name: "Factory") { FactoryPlugin() }
    }

    public var availableNames: [String] { factories.map(\.name) }

    public func register(name: String, make: @escaping () -> AnimationPlugin) {
        factories.removeAll { $0.name == name }
        factories.append((name, make))
    }

    public func makePlugin(named name: String) -> AnimationPlugin? {
        factories.first { $0.name == name }?.make()
    }
}

// MARK: - Shared math helpers for plugins

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

@inline(__always) func randomFloat(_ range: ClosedRange<Float>) -> Float {
    Float.random(in: range)
}
