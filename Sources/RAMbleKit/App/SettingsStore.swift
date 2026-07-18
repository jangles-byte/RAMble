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
    /// Comma-separated user-defined process names to watch in addition to defaults.
    @Published public var customProcesses: String {
        didSet { defaults.set(customProcesses, forKey: "customProcesses") }
    }
    /// Float the overlay above every window instead of behind them.
    @Published public var overlayOnTop: Bool {
        didSet { defaults.set(overlayOnTop, forKey: "overlayOnTop") }
    }
    /// Show the meters panel on the desktop overlay.
    @Published public var showMeters: Bool {
        didSet { defaults.set(showMeters, forKey: "showMeters") }
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
        animationName = defaults.string(forKey: "animationName") ?? "Galaxy"
        themeName = defaults.string(forKey: "themeName") ?? "Glass"
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.85
        scale = defaults.object(forKey: "scale") as? Double ?? 1.0
        fpsLimit = defaults.object(forKey: "fpsLimit") as? Int ?? 60
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
        enabledDisplayIDs = (defaults.array(forKey: "enabledDisplayIDs") as? [Int])?
            .map(UInt32.init) ?? []
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? true
        startAtLogin = defaults.object(forKey: "startAtLogin") as? Bool ?? false
        customProcesses = defaults.string(forKey: "customProcesses") ?? ""
        overlayOnTop = defaults.object(forKey: "overlayOnTop") as? Bool ?? false
        showMeters = defaults.object(forKey: "showMeters") as? Bool ?? false
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
