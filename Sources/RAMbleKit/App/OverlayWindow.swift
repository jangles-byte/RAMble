import AppKit
import MetalKit
import SwiftUI
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
    private var overlays: [CGDirectDisplayID: (window: OverlayWindow, view: MTKView,
                                               renderer: Renderer, meters: MeterPanel)] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private lazy var detailController = MeterDetailWindowController(stateEngine: stateEngine)

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
                guard let self else { return }
                var s = state
                s.intensity = Float(self.settings.intensity)
                self.overlays.values.forEach { $0.renderer.currentState = s }
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
            overlay.meters.orderOut(nil)
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

                // Meters live in their own tiny draggable window so the main
                // overlay can stay fully click-through.
                let hosting = NSHostingView(rootView: MeterHUDView(
                    stateEngine: stateEngine, settings: settings,
                    onSelect: { [weak self] kind in self?.detailController.show(kind) }))
                let meters = MeterPanel(content: hosting)
                meters.onMoved = { [weak self] origin in
                    self?.settings.metersPositions["\(id)"] =
                        [Double(origin.x), Double(origin.y)]
                }
                overlays[id] = (window, view, renderer, meters)
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
                overlay.meters.orderOut(nil)
                overlay.view.isPaused = true
                continue
            }
            // Bring-to-front: float over everything (still click-through);
            // otherwise sit just above the wallpaper, below all windows.
            overlay.window.level = settings.overlayOnTop
                ? .screenSaver
                : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            overlay.view.preferredFramesPerSecond = settings.fpsLimit
            overlay.renderer.theme = theme
            overlay.renderer.globalAlpha = Float(settings.opacity)
            overlay.renderer.sceneScale = Float(settings.scale)
            if overlay.renderer.activePlugin?.name != plugin {
                overlay.renderer.activePlugin = PluginRegistry.shared.makePlugin(named: plugin)
            }
            layoutMeters(overlay.meters, id: id, overlayLevel: overlay.window.level)
        }
    }

    private func layoutMeters(_ panel: MeterPanel, id: CGDirectDisplayID,
                              overlayLevel: NSWindow.Level) {
        guard settings.showMeters else { panel.orderOut(nil); return }
        guard let screen = NSScreen.screens.first(where: {
            Self.displayID(of: $0) == id
        }) else { return }

        panel.level = NSWindow.Level(rawValue: overlayLevel.rawValue + 1)
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setContentSize(size)

        let origin: NSPoint
        if let saved = settings.metersPositions["\(id)"], saved.count == 2 {
            origin = NSPoint(x: saved[0], y: saved[1])
        } else {
            let margin: CGFloat = 28
            let f = screen.frame
            switch settings.metersCorner {
            case .topLeft:
                origin = NSPoint(x: f.minX + margin, y: f.maxY - size.height - margin)
            case .topRight:
                origin = NSPoint(x: f.maxX - size.width - margin,
                                 y: f.maxY - size.height - margin)
            case .bottomLeft:
                origin = NSPoint(x: f.minX + margin, y: f.minY + margin)
            case .bottomRight:
                origin = NSPoint(x: f.maxX - size.width - margin, y: f.minY + margin)
            }
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
