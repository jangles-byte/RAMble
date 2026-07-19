import SwiftUI
import AppKit

/// First-run welcome. RAMble is an `LSUIElement` agent — no Dock icon, no
/// window — so without this a successful launch looks identical to a failed
/// one. This is the only visible confirmation that the app is running and a
/// pointer to where its controls live.
struct WelcomeView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let art = RamHeadIcon.artwork {
                Image(nsImage: art)
                    .resizable().scaledToFit()
                    .frame(width: 78, height: 78)
            }
            Text("RAMble is running").font(.title2).bold()
            Text("Look for the ram in your menu bar — that's RAMble's whole interface. It has no Dock icon and no window of its own.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                row("menubar.rectangle", "Menu bar ram icon",
                    "Switch animations, toggle the overlay, open Settings, quit.")
                row("rectangle.on.rectangle", "The overlay draws behind your windows",
                    "Hide a window or press F11 to see your desktop.")
                row("gauge.with.dots.needle.67percent", "Desktop meters are optional",
                    "Settings → Monitoring turns them on; click any bar for details.")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            HStack {
                Button("Open Settings") { onOpenSettings() }
                Button("Got it") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

public final class WelcomeWindowController: NSWindowController {
    private var onOpenSettings: () -> Void = {}

    public convenience init(onOpenSettings: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to RAMble"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.onOpenSettings = onOpenSettings
        let view = WelcomeView(
            onOpenSettings: { [weak self] in self?.close(); self?.onOpenSettings() },
            onDismiss: { [weak self] in self?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(window.contentViewController!.view.fittingSize)
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
