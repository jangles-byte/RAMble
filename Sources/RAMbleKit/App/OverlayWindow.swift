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
                                               renderer: Renderer, hud: NSHostingView<MeterHUDView>)] = [:]
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
                let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                let view = MTKView(frame: container.bounds, device: device)
                view.delegate = renderer
                view.layer?.isOpaque = false
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                view.framebufferOnly = false
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)

                let hud = NSHostingView(rootView: MeterHUDView(
                    stateEngine: stateEngine, settings: settings))
                hud.isHidden = true
                container.addSubview(hud)

                let window = OverlayWindow(screen: screen)
                window.contentView = container
                overlays[id] = (window, view, renderer, hud)
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
            layoutHUD(overlay.hud, in: overlay.window)
        }
    }

    private func layoutHUD(_ hud: NSHostingView<MeterHUDView>, in window: OverlayWindow) {
        hud.isHidden = !settings.showMeters
        guard settings.showMeters, let container = window.contentView else { return }
        let size = hud.fittingSize
        let margin: CGFloat = 28
        let bounds = container.bounds
        let origin: NSPoint
        switch settings.metersCorner {
        case .topLeft:
            origin = NSPoint(x: margin, y: bounds.height - size.height - margin)
        case .topRight:
            origin = NSPoint(x: bounds.width - size.width - margin,
                             y: bounds.height - size.height - margin)
        case .bottomLeft:
            origin = NSPoint(x: margin, y: margin)
        case .bottomRight:
            origin = NSPoint(x: bounds.width - size.width - margin, y: margin)
        }
        hud.frame = NSRect(origin: origin, size: size)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
