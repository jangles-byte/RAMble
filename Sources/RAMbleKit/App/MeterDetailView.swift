import SwiftUI
import AppKit

/// The "what's driving this bar" window: an explanation of the metric plus a
/// live, sorted list of the contributing processes, each with a Quit control.
struct MeterDetailView: View {
    let kind: MetricKind
    @ObservedObject var stateEngine: StateEngine
    @ObservedObject var inspector: ProcessInspector

    @State private var confirmingKill: ProcInfo?
    @State private var forceKill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if kind.attributable {
                processList
            } else {
                unavailableNote
            }
        }
        .padding(18)
        .frame(width: 460, height: 520)
        .onAppear { inspector.start() }
        .onDisappear { inspector.stop() }
        .alert(item: $confirmingKill) { proc in
            Alert(
                title: Text("\(forceKill ? "Force Quit" : "Quit") \(proc.name)?"),
                message: Text(forceKill
                    ? "This sends SIGKILL — the process ends immediately and unsaved work is lost."
                    : "This asks \(proc.name) (PID \(proc.id)) to quit. Unsaved work may be lost."),
                primaryButton: .destructive(Text(forceKill ? "Force Quit" : "Quit")) {
                    inspector.terminate(pid: proc.id, force: forceKill)
                },
                secondaryButton: .cancel())
        }
    }

    private var header: some View {
        let value = currentValue
        return HStack(alignment: .firstTextBaseline) {
            Text(kind.rawValue).font(.title2).bold()
            Spacer()
            Text(value).font(.title2).monospacedDigit()
                .foregroundStyle(severityColor)
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kind.sortByCPU ? "Top processes by CPU" : "Top processes by memory")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if inspector.refreshing {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(inspector.top(for: kind)) { proc in
                        row(proc)
                    }
                }
            }
            Text("Updates live. Hold ⌥ and click Quit to Force Quit.")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
    }

    private func row(_ proc: ProcInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.name).lineLimit(1)
                Text("PID \(proc.id)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(kind.sortByCPU
                 ? String(format: "%.0f%% CPU", proc.cpuPercent)
                 : ByteFormat.string(proc.rssBytes))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Button(role: .destructive) {
                forceKill = NSEvent.modifierFlags.contains(.option)
                confirmingKill = proc
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help(proc.isSelf ? "This is RAMble" : "Quit this process")
            .disabled(proc.isSelf)
            .opacity(proc.isSelf ? 0.3 : 1)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private var unavailableNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Per-process breakdown isn't available for this metric",
                  systemImage: "info.circle")
                .font(.callout)
            if kind == .gpu, !stateEngine.state.watchedProcesses.filter({ $0.isRunning }).isEmpty {
                Text("Running AI processes:").font(.caption).foregroundStyle(.secondary)
                ForEach(stateEngine.state.watchedProcesses.filter { $0.isRunning }) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        if p.isInferring { Text("inferring").font(.caption)
                            .foregroundStyle(.green) }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
            Spacer()
        }
    }

    private var currentValue: String {
        let s = stateEngine.state
        switch kind {
        case .ram: return "\(Int(s.ramPercent * 100))%"
        case .pressure: return "\(Int(s.memoryPressure * 100))%"
        case .swap: return ByteFormat.string(s.swapUsedBytes)
        case .cpu: return "\(Int(s.cpuPercent * 100))%"
        case .gpu: return "\(Int(s.gpuPercent * 100))%"
        case .disk: return "\(Int(s.diskPressure * 100))%"
        case .stress: return "\(Int(s.stress * 100))%"
        case .tokens: return s.inferenceRunning ? "\(Int(s.tokensPerSecond)) tok/s" : "idle"
        }
    }

    private var severityColor: Color {
        let v: Float
        switch kind {
        case .ram: v = stateEngine.state.ramPercent
        case .pressure: v = stateEngine.state.memoryPressure
        case .swap: v = stateEngine.state.swapPercent
        case .cpu: v = stateEngine.state.cpuPercent
        case .gpu: v = stateEngine.state.gpuPercent
        case .disk: v = stateEngine.state.diskPressure
        case .stress: v = stateEngine.state.stress
        case .tokens: v = stateEngine.state.inferenceRunning ? 0.6 : 0
        }
        if v < 0.5 { return .green }
        if v < 0.8 { return .yellow }
        return .red
    }
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .memory
        return f.string(fromByteCount: Int64(bytes))
    }
}

/// Hosts one metric-detail view in a normal, activating window.
public final class MeterDetailWindowController: NSWindowController {
    private let stateEngine: StateEngine
    private let inspector = ProcessInspector()

    public init(stateEngine: StateEngine) {
        self.stateEngine = stateEngine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show(_ kind: MetricKind) {
        let view = MeterDetailView(kind: kind, stateEngine: stateEngine, inspector: inspector)
        window?.contentViewController = NSHostingController(rootView: view)
        window?.title = "\(kind.rawValue) — what's using it"
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
