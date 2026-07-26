import Foundation
import Combine
import ServiceManagement

/// UserDefaults-backed app settings, observed by the UI and the overlay
/// coordinators.
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var animationName: String {
        didSet { defaults.set(animationName, forKey: "animationName") }
    }
    @Published public var themeName: String {
        didSet { defaults.set(themeName, forKey: "themeName") }
    }
    @Published public var opacity: Double {
        didSet { defaults.set(opacity, forKey: "opacity") }
    }
    @Published public var scale: Double {
        didSet { defaults.set(scale, forKey: "scale") }
    }
    /// Activity multiplier: 0.2 (slow drip) … 2.5 (busy screen).
    /// Charts-only mode: hide the animation entirely but keep the desktop
    /// meters. The Metal view pauses, so the animation costs nothing.
    @Published public var chartsOnly: Bool {
        didSet { defaults.set(chartsOnly, forKey: "chartsOnly") }
    }
    /// Internal render resolution as a fraction of native (1.0 = full).
    /// GPU cost scales with the square-ish of this; 0.25 ≈ 6% of the pixels.
    @Published public var resolution: Double {
        didSet { defaults.set(resolution, forKey: "resolution") }
    }
    @Published public var intensity: Double {
        didSet { defaults.set(intensity, forKey: "intensity") }
    }
    @Published public var fpsLimit: Int {
        didSet { defaults.set(fpsLimit, forKey: "fpsLimit") }
    }
    @Published public var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: "overlayEnabled") }
    }
    /// Display IDs the overlay should appear on; empty = all displays.
    @Published public var enabledDisplayIDs: [UInt32] {
        didSet { defaults.set(enabledDisplayIDs.map(Int.init), forKey: "enabledDisplayIDs") }
    }
    @Published public var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: "hideDockIcon") }
    }
    @Published public var startAtLogin: Bool {
        didSet {
            defaults.set(startAtLogin, forKey: "startAtLogin")
            applyLoginItem()
        }
    }
    /// Whether the first-run welcome window has been shown.
    @Published public var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") }
    }
    /// Comma-separated user-defined process names to watch in addition to defaults.
    @Published public var customProcesses: String {
        didSet { defaults.set(customProcesses, forKey: "customProcesses") }
    }
    /// Float the overlay above every window instead of behind them.
    @Published public var overlayOnTop: Bool {
        didSet { defaults.set(overlayOnTop, forKey: "overlayOnTop") }
    }
    /// Show the meters panel on the desktop overlay.
    /// Meters widget style: "bars" (labeled meters) or "engine" (the
    /// Engine Room cutaway — docs/engine-widget-design.md).
    @Published public var metersStyle: String {
        didSet { defaults.set(metersStyle, forKey: "metersStyle") }
    }
    @Published public var showMeters: Bool {
        didSet { defaults.set(showMeters, forKey: "showMeters") }
    }
    /// Opacity of the meters panel, independent of the overlay opacity.
    @Published public var metersOpacity: Double {
        didSet { defaults.set(metersOpacity, forKey: "metersOpacity") }
    }
    /// Which corner the meters panel starts in (dragging overrides it).
    @Published public var metersCorner: MeterCorner {
        didSet { defaults.set(metersCorner.rawValue, forKey: "metersCorner") }
    }
    /// Dragged panel positions, keyed by display ID → [x, y] (screen coords).
    @Published public var metersPositions: [String: [Double]] {
        didSet { defaults.set(metersPositions, forKey: "metersPositions") }
    }

    private let defaults: UserDefaults

    public var watchList: [String] {
        let custom = customProcesses.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ProcessMonitor.defaultWatchList + custom
    }

    public var theme: Theme { Themes.named(themeName) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        animationName = defaults.string(forKey: "animationName") ?? "Synapse"
        themeName = defaults.string(forKey: "themeName") ?? "Glass"
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.85
        scale = defaults.object(forKey: "scale") as? Double ?? 1.0
        chartsOnly = defaults.object(forKey: "chartsOnly") as? Bool ?? false
        resolution = defaults.object(forKey: "resolution") as? Double ?? 1.0
        intensity = defaults.object(forKey: "intensity") as? Double ?? 1.0
        fpsLimit = defaults.object(forKey: "fpsLimit") as? Int ?? 60
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
        enabledDisplayIDs = (defaults.array(forKey: "enabledDisplayIDs") as? [Int])?
            .map(UInt32.init) ?? []
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? true
        startAtLogin = defaults.object(forKey: "startAtLogin") as? Bool ?? false
        customProcesses = defaults.string(forKey: "customProcesses") ?? ""
        hasSeenWelcome = defaults.object(forKey: "hasSeenWelcome") as? Bool ?? false
        overlayOnTop = defaults.object(forKey: "overlayOnTop") as? Bool ?? false
        metersStyle = defaults.string(forKey: "metersStyle") ?? "bars"
        showMeters = defaults.object(forKey: "showMeters") as? Bool ?? false
        metersOpacity = defaults.object(forKey: "metersOpacity") as? Double ?? 0.9
        metersCorner = MeterCorner(rawValue:
            defaults.string(forKey: "metersCorner") ?? "") ?? .topRight
        metersPositions = defaults.dictionary(forKey: "metersPositions")
            as? [String: [Double]] ?? [:]
    }

    private func applyLoginItem() {
        // SMAppService only works from a bundled .app; ignore failures when
        // running as a bare executable during development.
        do {
            if startAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("RAMble: login item change failed (unbundled dev build?): \(error)")
        }
    }
}
