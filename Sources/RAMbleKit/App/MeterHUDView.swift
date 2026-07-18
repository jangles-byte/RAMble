import SwiftUI

/// The on-desktop monitoring panel: labeled meters, no numbers.
/// Lives inside the click-through overlay window, so it's purely visual.
struct MeterHUDView: View {
    @ObservedObject var stateEngine: StateEngine
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let s = stateEngine.state
        VStack(alignment: .leading, spacing: 7) {
            meter("RAM", value: s.ramPercent)
            meter("PRESS", value: s.memoryPressure)
            meter("SWAP", value: s.swapPercent)
            meter("CPU", value: s.cpuPercent)
            meter("GPU", value: s.gpuPercent)
            meter("DISK", value: s.diskPressure)
            Divider().overlay(.white.opacity(0.15))
            meter("STRESS", value: s.stress, emphasized: true)
            // Always present so the panel keeps a stable size; dims when idle.
            meter("TOK/S", value: min(s.tokensPerSecond / 120, 1), accent: .cyan)
                .opacity(s.inferenceRunning ? 1 : 0.3)
        }
        .padding(12)
        .frame(width: 170)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10)))
        .opacity(settings.opacity)
        .animation(.easeOut(duration: 0.5), value: s.stress)
    }

    private func meter(_ label: String, value: Float,
                       emphasized: Bool = false, accent: Color? = nil) -> some View {
        let v = CGFloat(min(max(value, 0), 1))
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: emphasized ? .bold : .medium,
                              design: .monospaced))
                .foregroundStyle(.white.opacity(emphasized ? 0.95 : 0.7))
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(accent ?? severityColor(value))
                        .frame(width: max(geo.size.width * v, v > 0 ? 4 : 0))
                        .shadow(color: (accent ?? severityColor(value)).opacity(0.8),
                                radius: emphasized ? 4 : 2)
                }
            }
            .frame(height: emphasized ? 7 : 5)
        }
    }

    /// Green → yellow → red as the signal climbs.
    private func severityColor(_ v: Float) -> Color {
        switch v {
        case ..<0.5:
            return Color(hue: 0.36, saturation: 0.75, brightness: 0.85)
        case ..<0.75:
            return Color(hue: 0.36 - 0.22 * Double((v - 0.5) / 0.25),
                         saturation: 0.85, brightness: 0.95)
        default:
            return Color(hue: 0.14 - 0.14 * Double(min((v - 0.75) / 0.25, 1)),
                         saturation: 0.9, brightness: 1.0)
        }
    }
}

/// Where the meters panel sits on each display.
public enum MeterCorner: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"
    public var id: String { rawValue }
}

/// A small draggable window hosting the meters panel. Click-and-hold anywhere
/// on it to drag; it clamps itself to the screen so it can never be lost
/// off-screen. Non-activating, so dragging never steals focus from your work.
final class MeterPanel: NSPanel, NSWindowDelegate {
    /// Called after every (clamped) move with the new origin.
    var onMoved: ((NSPoint) -> Void)?
    private var clamping = false

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true      // click-hold-drag anywhere on it
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = content
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func windowDidMove(_ notification: Notification) {
        guard !clamping, let screen = screen ?? NSScreen.main else { return }
        let limit = screen.frame
        var origin = frame.origin
        origin.x = min(max(origin.x, limit.minX), limit.maxX - frame.width)
        origin.y = min(max(origin.y, limit.minY), limit.maxY - frame.height)
        if origin != frame.origin {
            clamping = true
            setFrameOrigin(origin)
            clamping = false
        }
        onMoved?(origin)
    }
}
