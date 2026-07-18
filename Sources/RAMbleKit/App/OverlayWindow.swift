import AppKit
import MetalKit
import Combine

/// A borderless, transparent, click-through window pinned just above the
/// desktop wallpaper (below every normal window) on one screen.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true                 // click-through
        level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one overlay window + Metal view + renderer per screen, and keeps the
/// set of windows in sync with connected displays and settings.
final class OverlayController {
    private let stateEngine: StateEngine
    private let settings: SettingsStore
    private var overlays: [CGDirectDisplayID: (window: OverlayWindow, view: MTKView, renderer: Renderer)] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(stateEngine: StateEngine, settings: SettingsStore) {
        self.stateEngine = stateEngine
        self.settings = settings

        rebuildOverlays()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildOverlays() }
            .store(in: &cancellables)

        stateEngine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.overlays.values.forEach { $0.renderer.currentState = state }
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.applySettings() }
            }
            .store(in: &cancellables)
    }

    private func rebuildOverlays() {
        let screens = NSScreen.screens
        let currentIDs = Set(screens.compactMap(Self.displayID(of:)))

        // Drop overlays for disconnected screens.
        for (id, overlay) in overlays where !currentIDs.contains(id) {
            overlay.window.orderOut(nil)
            overlays.removeValue(forKey: id)
        }
        // Add overlays for new screens.
        for screen in screens {
            guard let id = Self.displayID(of: screen), overlays[id] == nil,
                  let device = MTLCreateSystemDefaultDevice() else { continue }
            do {
                let renderer = try Renderer(device: device)
                let view = MTKView(frame: screen.frame, device: device)
                view.delegate = renderer
                view.layer?.isOpaque = false
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                view.framebufferOnly = false
                let window = OverlayWindow(screen: screen)
                window.contentView = view
                overlays[id] = (window, view, renderer)
            } catch {
                NSLog("RAMble: renderer init failed for display \(id): \(error)")
            }
        }
        applySettings()
    }

    func applySettings() {
        let theme = settings.theme
        let plugin = settings.animationName
        for (id, overlay) in overlays {
            let enabled = settings.overlayEnabled &&
                (settings.enabledDisplayIDs.isEmpty || settings.enabledDisplayIDs.contains(id))
            if enabled {
                overlay.window.orderFront(nil)
                overlay.view.isPaused = false
            } else {
                overlay.window.orderOut(nil)
                overlay.view.isPaused = true
                continue
            }
            overlay.view.preferredFramesPerSecond = settings.fpsLimit
            overlay.renderer.theme = theme
            overlay.renderer.globalAlpha = Float(settings.opacity)
            overlay.renderer.sceneScale = Float(settings.scale)
            if overlay.renderer.activePlugin?.name != plugin {
                overlay.renderer.activePlugin = PluginRegistry.shared.makePlugin(named: plugin)
            }
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
