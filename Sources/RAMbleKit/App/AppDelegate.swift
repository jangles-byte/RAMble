import AppKit
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private var stateEngine: StateEngine!
    private var overlayController: OverlayController!
    private var settingsController: SettingsWindowController!
    private var welcomeController: WelcomeWindowController?
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()

        stateEngine = StateEngine(watchList: settings.watchList)
        stateEngine.start()

        overlayController = OverlayController(stateEngine: stateEngine, settings: settings)
        settingsController = SettingsWindowController(settings: settings,
                                                      stateEngine: stateEngine)
        setUpStatusItem()

        // RAMble has no Dock icon and no window, so a first launch with no
        // feedback is indistinguishable from a failed one. Show the welcome
        // once so people know it's running and where the controls are.
        if !settings.hasSeenWelcome {
            settings.hasSeenWelcome = true
            showWelcome()
        }

        settings.$customProcesses
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.stateEngine.updateWatchList(self.settings.watchList)
            }
            .store(in: &cancellables)
        settings.$hideDockIcon
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyActivationPolicy() }
            .store(in: &cancellables)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = RamHeadIcon.menuBarImage()
        statusItem.button?.image?.accessibilityDescription = "RAMble"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show Overlay", action: #selector(toggleOverlay),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let animations = NSMenu()
        for name in PluginRegistry.shared.availableNames {
            let item = NSMenuItem(title: name, action: #selector(selectAnimation(_:)),
                                  keyEquivalent: "")
            item.target = self
            animations.addItem(item)
        }
        let animationsItem = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        animationsItem.submenu = animations
        menu.addItem(animationsItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let welcomeItem = NSMenuItem(title: "Welcome / Help",
                                     action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit RAMble", action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleOverlay() {
        settings.overlayEnabled.toggle()
    }

    @objc private func selectAnimation(_ sender: NSMenuItem) {
        settings.animationName = sender.title
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func showWelcome() {
        if welcomeController == nil {
            welcomeController = WelcomeWindowController(onOpenSettings: { [weak self] in
                self?.settingsController.show()
            })
        }
        welcomeController?.show()
    }

    @objc private func checkForUpdates() {
        settingsController.show()
        DispatchQueue.main.async { UpdateChecker.shared.check() }
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.title == "Show Overlay" {
                item.state = settings.overlayEnabled ? .on : .off
            }
            if let submenu = item.submenu, item.title == "Animation" {
                for sub in submenu.items {
                    sub.state = sub.title == settings.animationName ? .on : .off
                }
            }
        }
    }
}
