import SwiftUI
import AppKit

/// The RAMble settings window: animation, theme, opacity, FPS, displays,
/// process watch list, and startup behavior.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var stateEngine: StateEngine

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "sparkles") }
            displaysTab
                .tabItem { Label("Displays", systemImage: "display.2") }
            monitoringTab
                .tabItem { Label("Monitoring", systemImage: "waveform.path.ecg") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 440, height: 420)
    }

    private var appearanceTab: some View {
        Form {
            Toggle("Show overlay", isOn: $settings.overlayEnabled)
            Picker("Animation", selection: $settings.animationName) {
                ForEach(PluginRegistry.shared.availableNames, id: \.self) { Text($0) }
            }
            Picker("Theme", selection: $settings.themeName) {
                ForEach(Themes.all) { Text($0.name).tag($0.name) }
            }
            Slider(value: $settings.opacity, in: 0.1...1.0) {
                Text("Opacity")
            } minimumValueLabel: { Image(systemName: "circle.dotted") }
              maximumValueLabel: { Image(systemName: "circle.fill") }
            Slider(value: $settings.scale, in: 0.5...2.0) {
                Text("Scale")
            } minimumValueLabel: { Image(systemName: "minus.magnifyingglass") }
              maximumValueLabel: { Image(systemName: "plus.magnifyingglass") }
            Picker("Frame rate limit", selection: $settings.fpsLimit) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
                Text("90 FPS").tag(90)
                Text("120 FPS").tag(120)
            }
        }
        .padding()
    }

    private var displaysTab: some View {
        Form {
            Text("Choose which displays show the overlay. With none selected, the overlay appears everywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(NSScreen.screens, id: \.self) { screen in
                if let id = OverlayController.displayID(of: screen) {
                    Toggle(screen.localizedName, isOn: displayBinding(id))
                }
            }
        }
        .padding()
    }

    private func displayBinding(_ id: CGDirectDisplayID) -> Binding<Bool> {
        Binding(
            get: {
                settings.enabledDisplayIDs.isEmpty || settings.enabledDisplayIDs.contains(id)
            },
            set: { enabled in
                var ids = settings.enabledDisplayIDs.isEmpty
                    ? NSScreen.screens.compactMap(OverlayController.displayID(of:))
                    : settings.enabledDisplayIDs
                if enabled { if !ids.contains(id) { ids.append(id) } }
                else { ids.removeAll { $0 == id } }
                settings.enabledDisplayIDs = ids
            })
    }

    private var monitoringTab: some View {
        Form {
            Section("Desktop meters") {
                Toggle("Show meters on desktop", isOn: $settings.showMeters)
                Picker("Position", selection: $settings.metersCorner) {
                    ForEach(MeterCorner.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.showMeters)
            }
            Section("Watched AI processes") {
                Text(ProcessMonitor.defaultWatchList.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Extra processes (comma-separated)", text: $settings.customProcesses)
            }
            Section("Live state") {
                LabeledContent("RAM", value: percent(stateEngine.state.ramPercent))
                LabeledContent("Memory pressure", value: percent(stateEngine.state.memoryPressure))
                LabeledContent("Swap", value: percent(stateEngine.state.swapPercent))
                LabeledContent("CPU", value: percent(stateEngine.state.cpuPercent))
                LabeledContent("GPU", value: percent(stateEngine.state.gpuPercent))
                LabeledContent("Stress", value: percent(stateEngine.state.stress))
                LabeledContent("Inference",
                               value: stateEngine.state.inferenceRunning
                               ? "\(Int(stateEngine.state.tokensPerSecond)) tok/s (est.)"
                               : "idle")
                if !stateEngine.state.loadedModels.isEmpty {
                    LabeledContent("Models",
                                   value: stateEngine.state.loadedModels.joined(separator: ", "))
                }
            }
        }
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Start at login", isOn: $settings.startAtLogin)
            Toggle("Hide Dock icon", isOn: $settings.hideDockIcon)
            Text("RAMble lives in the menu bar. Quit or reopen settings from the menu bar icon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func percent(_ v: Float) -> String { "\(Int(v * 100))%" }
}

/// Hosts the SwiftUI settings view in a regular window.
final class SettingsWindowController: NSWindowController {
    convenience init(settings: SettingsStore, stateEngine: StateEngine) {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: settings, stateEngine: stateEngine))
        let window = NSWindow(contentViewController: hosting)
        window.title = "RAMble Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
