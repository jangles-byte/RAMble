import Testing
import simd
@testable import RAMbleKit

@Suite struct ThemeAndPluginTests {
    @Test func allThemesAreRegisteredAndDistinct() {
        #expect(Themes.all.count == 7)
        #expect(Set(Themes.all.map(\.name)).count == 7)
        for theme in Themes.all {
            #expect(!theme.palette.isEmpty, "\(theme.name) needs a palette")
            #expect(theme.particleScale > 0)
        }
    }

    @Test func themeLookupFallsBackToGlass() {
        #expect(Themes.named("Cyberpunk").name == "Cyberpunk")
        #expect(Themes.named("Nope").name == "Glass")
    }

    @Test func stressColorInterpolates() {
        let theme = Themes.glass
        #expect(theme.stressColor(0) == theme.calmColor)
        #expect(theme.stressColor(1) == theme.warningColor)
        #expect(theme.stressColor(9) == theme.warningColor)  // clamped
    }

    @Test func registryBuildsEveryBuiltInPlugin() {
        let names = PluginRegistry.shared.availableNames
        #expect(Set(names).isSuperset(of:
            ["Plinko", "Galaxy", "Water Tank", "Motherboard", "Factory"]))
        for name in ["Plinko", "Galaxy", "Water Tank", "Motherboard", "Factory"] {
            let plugin = PluginRegistry.shared.makePlugin(named: name)
            #expect(plugin?.name == name)
        }
    }

    @Test func pluginsSurviveExtremeStatesWithoutCrashing() {
        var extreme = SystemState()
        extreme.ramPercent = 1; extreme.memoryPressure = 1; extreme.swapPercent = 1
        extreme.cpuPercent = 1; extreme.gpuPercent = 1; extreme.diskPressure = 1
        extreme.inferenceRunning = true
        extreme.tokensPerSecond = 500
        extreme.modelJustLoaded = true
        extreme.perCoreUsage = Array(repeating: 1, count: 10)

        for name in ["Plinko", "Galaxy", "Water Tank", "Motherboard", "Factory"] {
            guard let plugin = PluginRegistry.shared.makePlugin(named: name) else {
                Issue.record("missing plugin \(name)")
                continue
            }
            plugin.prepare(bounds: SIMD2(1440, 900), theme: Themes.synthwave)
            for _ in 0..<300 {  // ~5 seconds of frames at max stress
                plugin.update(state: extreme, deltaTime: 1.0 / 60.0)
            }
            let calm = SystemState()
            for _ in 0..<300 {
                plugin.update(state: calm, deltaTime: 1.0 / 60.0)
            }
        }
    }

    @Test func customPluginRegistration() {
        final class NullPlugin: AnimationPlugin {
            let name = "Null"
            func prepare(bounds: SIMD2<Float>, theme: Theme) {}
            func update(state: SystemState, deltaTime: Float) {}
            func render(renderer: Renderer) {}
        }
        PluginRegistry.shared.register(name: "Null") { NullPlugin() }
        #expect(PluginRegistry.shared.makePlugin(named: "Null") != nil)
        #expect(PluginRegistry.shared.availableNames.contains("Null"))
    }
}
