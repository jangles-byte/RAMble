import SwiftUI

/// Engine Room — the second meters style (docs/engine-widget-design.md).
/// A glass cutaway of the machine: RAM as a filling reservoir (wired
/// bedrock, compressed sediment, live liquid), overflow dripping into a red
/// swap sump, one piston per CPU core, a GPU turbine that throws token
/// sparks, a spinning disk platter — and a stress press that descends and
/// visibly crushes the whole room as the machine strains.
struct EngineHUDView: View {
    @ObservedObject var stateEngine: StateEngine
    @ObservedObject var settings: SettingsStore
    var onSelect: ((MetricKind) -> Void)?

    @State private var motor = EngineMotor()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            EngineBody(motion: motor.tick(timeline.date.timeIntervalSinceReferenceDate,
                                          stateEngine.state),
                       showHint: onSelect != nil)
        }
        .overlay(tapZones)
        .opacity(settings.metersOpacity)
    }

    /// Click targets over the major parts, matching EngineBody's layout.
    private var tapZones: some View {
        GeometryReader { geo in
            if let onSelect {
                let w = geo.size.width, h = geo.size.height
                Group {
                    zone(onSelect, .stress, x: 0.05, y: 0.02, wf: 0.90, hf: 0.14, w, h)
                    zone(onSelect, .ram, x: 0.05, y: 0.17, wf: 0.42, hf: 0.48, w, h)
                    zone(onSelect, .cpu, x: 0.52, y: 0.17, wf: 0.43, hf: 0.22, w, h)
                    zone(onSelect, .gpu, x: 0.52, y: 0.41, wf: 0.43, hf: 0.26, w, h)
                    zone(onSelect, .swap, x: 0.05, y: 0.67, wf: 0.42, hf: 0.28, w, h)
                    zone(onSelect, .disk, x: 0.52, y: 0.69, wf: 0.43, hf: 0.24, w, h)
                }
            }
        }
    }

    private func zone(_ onSelect: @escaping (MetricKind) -> Void, _ kind: MetricKind,
                      x: CGFloat, y: CGFloat, wf: CGFloat, hf: CGFloat,
                      _ w: CGFloat, _ h: CGFloat) -> some View {
        Button { onSelect(kind) } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: w * wf, height: h * hf)
        .position(x: w * (x + wf / 2), y: h * (y + hf / 2))
    }
}

/// Integrated, smoothed animation state. Rotations and piston strokes are
/// phase-integrated (`angle += speed * dt`) rather than derived from
/// absolute time, so a change in system load glides instead of teleporting
/// the whole animation — the "snapping" failure mode of `t * speed`.
struct EngineMotion {
    var gpuAngle: CGFloat = 0.8
    var diskAngle: CGFloat = 0.3
    var pistonPhase: [CGFloat] = (0..<10).map { CGFloat($0) * 1.7 }
    var bubblePhase: CGFloat = 0
    var dropPhase: CGFloat = 0
    var sparkPhase: CGFloat = 0
    var wave: CGFloat = 0
    var rattleT: CGFloat = 0

    // Smoothed signals — levels glide between 1 Hz samples.
    var cores: [CGFloat] = Array(repeating: 0, count: 10)
    var coreCount = 8
    var gpu: CGFloat = 0
    var disk: CGFloat = 0
    var stress: CGFloat = 0
    var ram: CGFloat = 0
    var wired: CGFloat = 0
    var compressed: CGFloat = 0
    var pressure: CGFloat = 0
    var swap: CGFloat = 0
    var tokens: CGFloat = 0      // 0…1, fades sparks in and out
}

/// Persistent frame-to-frame integrator for the Engine Room widget.
final class EngineMotor {
    private var m = EngineMotion()
    private var last: TimeInterval?

    func tick(_ now: TimeInterval, _ s: SystemState) -> EngineMotion {
        let dt = CGFloat(min(max(now - (last ?? now), 0), 0.1))
        last = now
        func glide(_ a: inout CGFloat, _ target: CGFloat, _ rate: CGFloat) {
            a += (target - a) * min(1, dt * rate)
        }

        // Smooth every signal so speeds and levels change gradually.
        glide(&m.gpu, CGFloat(s.gpuPercent.clamped01), 3)
        glide(&m.disk, CGFloat(s.diskPressure.clamped01), 3)
        glide(&m.stress, CGFloat(s.stress.clamped01), 3)
        glide(&m.ram, CGFloat(s.ramPercent.clamped01), 2)
        glide(&m.wired, CGFloat(s.wiredPercent.clamped01), 2)
        glide(&m.compressed, CGFloat(s.compressedPercent.clamped01), 2)
        glide(&m.pressure, CGFloat(s.memoryPressure.clamped01), 2.5)
        glide(&m.swap, CGFloat(s.swapPercent.clamped01), 2)
        let tokTarget: CGFloat = s.inferenceRunning
            ? CGFloat(min(s.tokensPerSecond / 120, 1)) : 0
        glide(&m.tokens, tokTarget, 2.5)
        let usage = s.perCoreUsage
        m.coreCount = usage.isEmpty ? 8 : min(usage.count, 10)
        for i in 0..<10 {
            let target = i < usage.count
                ? CGFloat(usage[i].clamped01) : CGFloat(s.cpuPercent.clamped01)
            glide(&m.cores[i], target, 4)
        }

        // Integrate: continuous rotation whatever the load does.
        m.gpuAngle += (0.4 + m.gpu * 7) * dt
        m.diskAngle += (0.3 + m.disk * 9) * dt
        for i in 0..<10 { m.pistonPhase[i] += (0.6 + m.cores[i] * 11) * dt }
        m.bubblePhase += (0.25 + m.pressure * 0.5) * dt
        m.dropPhase += 0.55 * dt
        m.sparkPhase += 1.3 * dt
        m.wave += 2.1 * dt
        m.rattleT = CGFloat(now)
        return m
    }
}

/// Pure function of a motion snapshot → the full panel. Also rendered
/// headlessly by `RAMble --render-widget` for the design critique loop.
public struct EngineBody: View {
    let motion: EngineMotion
    var showHint = false

    init(motion: EngineMotion, showHint: Bool = false) {
        self.motion = motion
        self.showHint = showHint
    }

    /// Headless preview at a canned state (used by --render-widget).
    public static func preview(state: SystemState, time: TimeInterval,
                               showHint: Bool = false) -> EngineBody {
        var m = EngineMotion()
        let t = CGFloat(time)
        m.gpu = CGFloat(state.gpuPercent.clamped01)
        m.disk = CGFloat(state.diskPressure.clamped01)
        m.stress = CGFloat(state.stress.clamped01)
        m.ram = CGFloat(state.ramPercent.clamped01)
        m.wired = CGFloat(state.wiredPercent.clamped01)
        m.compressed = CGFloat(state.compressedPercent.clamped01)
        m.pressure = CGFloat(state.memoryPressure.clamped01)
        m.swap = CGFloat(state.swapPercent.clamped01)
        m.tokens = state.inferenceRunning ? CGFloat(min(state.tokensPerSecond / 120, 1)) : 0
        m.coreCount = state.perCoreUsage.isEmpty ? 8 : min(state.perCoreUsage.count, 10)
        for i in 0..<10 where i < state.perCoreUsage.count {
            m.cores[i] = CGFloat(state.perCoreUsage[i].clamped01)
        }
        m.gpuAngle = t * (0.4 + m.gpu * 7)
        m.diskAngle = t * (0.3 + m.disk * 9)
        for i in 0..<10 { m.pistonPhase[i] = t * (0.6 + m.cores[i] * 11) + CGFloat(i) * 1.7 }
        m.bubblePhase = t * 0.4
        m.dropPhase = t * 0.55
        m.sparkPhase = t * 1.3
        m.wave = t * 2.1
        m.rattleT = t
        return EngineBody(motion: m, showHint: showHint)
    }

    public var body: some View {
        VStack(spacing: 3) {
            Canvas { ctx, size in
                draw(&ctx, size)
            }
            .frame(width: 168, height: 196)
            if showHint {
                Text("click a part for details")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10)))
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let m = motion
        let stress = m.stress

        // The press: a heavy slab that descends with stress and crushes the
        // room below it. Everything else lives in `room`, which shrinks.
        let pressH: CGFloat = 11
        let pressTravel: CGFloat = 30
        let pressY = 2 + stress * pressTravel
        let rattle: CGFloat = stress > 0.65
            ? sin(m.rattleT * 47) * (stress - 0.65) * 6 : 0

        let room = CGRect(x: rattle, y: pressY + pressH + 4,
                          width: size.width,
                          height: size.height - pressY - pressH - 6)

        drawPress(&ctx, size: size, y: pressY, h: pressH, stress: stress)

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: room.minX + x * room.width, y: room.minY + y * room.height,
                   width: w * room.width, height: h * room.height)
        }

        drawReservoir(&ctx, rect(0.02, 0.00, 0.42, 0.60))
        drawSump(&ctx, rect(0.02, 0.76, 0.42, 0.24),
                 pipeFrom: rect(0.02, 0.00, 0.42, 0.60))
        drawPistons(&ctx, rect(0.54, 0.00, 0.44, 0.26))
        drawTurbine(&ctx, rect(0.54, 0.32, 0.44, 0.36))
        drawPlatter(&ctx, rect(0.58, 0.76, 0.36, 0.24))
    }

    private func drawPress(_ ctx: inout GraphicsContext, size: CGSize,
                           y: CGFloat, h: CGFloat, stress: CGFloat) {
        let rodColor = Color.white.opacity(0.22)
        for rx in [size.width * 0.25, size.width * 0.75] {
            ctx.fill(Path(CGRect(x: rx - 1.5, y: 0, width: 3, height: y + 2)),
                     with: .color(rodColor))
        }
        let slab = CGRect(x: 4, y: y, width: size.width - 8, height: h)
        let c = severity(stress)
        var slabCtx = ctx
        if stress > 0.4 {
            slabCtx.addFilter(.shadow(color: c.opacity(0.7), radius: 4 + stress * 5))
        }
        slabCtx.fill(Path(roundedRect: slab, cornerRadius: 3),
                     with: .color(Color(white: 0.28).opacity(0.9)))
        ctx.fill(Path(roundedRect: CGRect(x: slab.minX, y: slab.maxY - 2.5,
                                          width: slab.width, height: 2.5),
                      cornerRadius: 1),
                 with: .color(c.opacity(0.35 + stress * 0.6)))
        label(&ctx, "STRESS", at: CGPoint(x: slab.midX, y: slab.midY), anchor: .center,
              opacity: 0.55 + stress * 0.4)
    }

    private func drawReservoir(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let m = motion
        let liquid = max(m.ram - m.wired - m.compressed, 0)

        let floorY = r.maxY
        let wiredH = m.wired * r.height
        let compH = m.compressed * r.height
        let liquidH = liquid * r.height

        ctx.fill(Path(CGRect(x: r.minX, y: floorY - wiredH, width: r.width, height: wiredH)),
                 with: .color(Color(white: 0.45).opacity(0.55)))
        let compRect = CGRect(x: r.minX, y: floorY - wiredH - compH,
                              width: r.width, height: compH)
        ctx.fill(Path(compRect), with: .color(Color(white: 0.7).opacity(0.28)))
        if compH > 3 {
            for i in 0..<14 {
                let px = compRect.minX + (CGFloat((i * 37) % 100) / 100) * compRect.width
                let py = compRect.minY + (CGFloat((i * 61) % 100) / 100) * compRect.height
                ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 1.6, height: 1.6)),
                         with: .color(.white.opacity(0.35)))
            }
        }
        let liquidTop = floorY - wiredH - compH - liquidH
        let tint = blend(Color(red: 0.55, green: 0.75, blue: 0.9), severity(m.pressure),
                         m.pressure * 0.8)
        var surface = Path()
        surface.move(to: CGPoint(x: r.minX, y: floorY - wiredH - compH))
        surface.addLine(to: CGPoint(x: r.minX, y: liquidTop + sin(m.wave) * 1.6))
        let steps = 8
        for i in 1...steps {
            let x = r.minX + CGFloat(i) / CGFloat(steps) * r.width
            let y = liquidTop + sin(m.wave + CGFloat(i) * 0.9) * 1.6
            surface.addLine(to: CGPoint(x: x, y: y))
        }
        surface.addLine(to: CGPoint(x: r.maxX, y: floorY - wiredH - compH))
        surface.closeSubpath()
        ctx.fill(surface, with: .color(tint.opacity(0.35)))

        if m.pressure > 0.35, liquidH > 8 {
            for i in 0..<4 {
                let u = (m.bubblePhase + CGFloat(i) * 0.27)
                    .truncatingRemainder(dividingBy: 1)
                let bx = r.minX + (0.2 + CGFloat((i * 53) % 60) / 100) * r.width
                let by = (floorY - wiredH - compH) - u * liquidH
                ctx.stroke(Path(ellipseIn: CGRect(x: bx, y: by, width: 3, height: 3)),
                           with: .color(.white.opacity(Double((1 - u) * 0.5))), lineWidth: 0.7)
            }
        }

        ctx.stroke(Path(roundedRect: r, cornerRadius: 3),
                   with: .color(blend(Color.white.opacity(0.35),
                                      severity(m.pressure), m.pressure * 0.7)),
                   lineWidth: 1)
        label(&ctx, "RAM", at: CGPoint(x: r.midX, y: r.minY + 7), anchor: .center)
    }

    private func drawSump(_ ctx: inout GraphicsContext, _ r: CGRect, pipeFrom vessel: CGRect) {
        let m = motion
        let warning = Color(red: 1.0, green: 0.32, blue: 0.28)

        let px = vessel.maxX - 4
        var pipe = Path()
        pipe.move(to: CGPoint(x: px, y: vessel.maxY - 2))
        pipe.addLine(to: CGPoint(x: px, y: r.minY - 2))
        pipe.addLine(to: CGPoint(x: r.midX, y: r.minY - 2))
        ctx.stroke(pipe, with: .color(.white.opacity(0.25)), lineWidth: 2)

        if m.swap > 0.02 {
            for i in 0..<3 {
                let u = (m.dropPhase + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let dy = (vessel.maxY - 2) + u * (r.minY - vessel.maxY + 2)
                ctx.fill(Path(ellipseIn: CGRect(x: px - 1.5, y: dy, width: 3, height: 3.6)),
                         with: .color(warning.opacity(0.85)))
            }
        }

        let level = m.swap * (r.height - 3)
        ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - level, width: r.width, height: level)),
                 with: .color(warning.opacity(0.30 + m.swap * 0.45)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 3),
                   with: .color(m.swap > 0.02 ? warning.opacity(0.5) : .white.opacity(0.30)),
                   lineWidth: 1)
        label(&ctx, "SWAP", at: CGPoint(x: r.midX, y: r.minY - 6), anchor: .center)
    }

    private func drawPistons(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let m = motion
        let n = m.coreCount
        let gap: CGFloat = 2.5
        let w = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)

        for i in 0..<n {
            let usage = m.cores[i]
            let x = r.minX + CGFloat(i) * (w + gap)
            let cyl = CGRect(x: x, y: r.minY, width: w, height: r.height)
            ctx.stroke(Path(roundedRect: cyl, cornerRadius: 1.5),
                       with: .color(.white.opacity(0.22)), lineWidth: 0.8)
            let phase = (sin(m.pistonPhase[i]) + 1) / 2
            let travel = (r.height - 7) * (0.25 + usage * 0.75)
            let headY = cyl.maxY - 5 - phase * travel
            let c = severity(usage)
            var headCtx = ctx
            if usage > 0.55 { headCtx.addFilter(.shadow(color: c.opacity(0.8), radius: 2.5)) }
            headCtx.fill(Path(roundedRect: CGRect(x: x + 1, y: headY, width: w - 2, height: 4),
                              cornerRadius: 1),
                         with: .color(c.opacity(0.5 + usage * 0.5)))
        }
        label(&ctx, "CPU", at: CGPoint(x: r.midX, y: r.maxY + 6), anchor: .center)
    }

    private func drawTurbine(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let m = motion
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) * 0.34
        let c = severity(m.gpu)

        var hub = ctx
        if m.gpu > 0.4 { hub.addFilter(.shadow(color: c.opacity(0.8), radius: 3 + m.gpu * 5)) }
        hub.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(.white.opacity(0.3)), lineWidth: 1)
        for b in 0..<5 {
            let a = m.gpuAngle + CGFloat(b) / 5 * 2 * .pi
            var blade = Path()
            blade.move(to: center)
            blade.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.9,
                                      y: center.y + sin(a) * radius * 0.9))
            blade.addLine(to: CGPoint(x: center.x + cos(a + 0.5) * radius * 0.55,
                                      y: center.y + sin(a + 0.5) * radius * 0.55))
            blade.closeSubpath()
            hub.fill(blade, with: .color(blend(Color(white: 0.75), c, m.gpu)
                        .opacity(0.25 + m.gpu * 0.55)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                 with: .color(.white.opacity(0.6)))

        // Token sparks fade in with token rate — fixed population, so the
        // count never pops; only brightness changes.
        if m.tokens > 0.02 {
            let k = 6
            for i in 0..<k {
                let u = (m.sparkPhase + CGFloat(i) / CGFloat(k))
                    .truncatingRemainder(dividingBy: 1)
                let a = m.gpuAngle * 0.7 + CGFloat(i) / CGFloat(k) * 2 * .pi
                let d = radius + u * 16
                let p = CGPoint(x: center.x + cos(a) * d, y: center.y + sin(a) * d)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2,
                                                width: 2.4, height: 2.4)),
                         with: .color(Color.cyan.opacity(
                            Double((1 - u) * (0.25 + m.tokens * 0.65)))))
            }
        }
        label(&ctx, "GPU", at: CGPoint(x: r.midX, y: r.maxY + 1), anchor: .center)
    }

    private func drawPlatter(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let m = motion
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) * 0.36

        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(.white.opacity(0.28)), lineWidth: 1)
        for k in 0..<3 {
            let a = m.diskAngle + CGFloat(k) / 3 * 2 * .pi
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(a) * radius * 0.35,
                                  y: center.y + sin(a) * radius * 0.35))
            tick.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.85,
                                     y: center.y + sin(a) * radius * 0.85))
            ctx.stroke(tick, with: .color(severity(m.disk)
                        .opacity(0.35 + m.disk * 0.55)), lineWidth: 1.2)
        }
        label(&ctx, "DISK", at: CGPoint(x: r.midX, y: r.maxY + 1), anchor: .center)
    }

    // MARK: - Helpers

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint,
                       anchor: UnitPoint, opacity: Double = 0.45) {
        ctx.draw(Text(text).font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity)),
                 at: p, anchor: anchor)
    }

    private func severity(_ v: CGFloat) -> Color {
        switch v {
        case ..<0.5: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case ..<0.75: return Color(red: 0.95, green: 0.75, blue: 0.25)
        default: return Color(red: 1.0, green: 0.35, blue: 0.30)
        }
    }

    private func blend(_ a: Color, _ b: Color, _ f: CGFloat) -> Color {
        let fa = max(0, min(1, f))
        let ca = NSColor(a).usingColorSpace(.deviceRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.deviceRGB) ?? .white
        return Color(red: Double(ca.redComponent * (1 - fa) + cb.redComponent * fa),
                     green: Double(ca.greenComponent * (1 - fa) + cb.greenComponent * fa),
                     blue: Double(ca.blueComponent * (1 - fa) + cb.blueComponent * fa))
    }
}

/// Chooses the meters style; the panel's hosting view roots here.
struct MetersRootView: View {
    @ObservedObject var stateEngine: StateEngine
    @ObservedObject var settings: SettingsStore
    var onSelect: ((MetricKind) -> Void)?

    var body: some View {
        if settings.metersStyle == "engine" {
            EngineHUDView(stateEngine: stateEngine, settings: settings, onSelect: onSelect)
        } else {
            MeterHUDView(stateEngine: stateEngine, settings: settings, onSelect: onSelect)
        }
    }
}
