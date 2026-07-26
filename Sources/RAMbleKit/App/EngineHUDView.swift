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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            EngineBody(state: stateEngine.state,
                       time: timeline.date.timeIntervalSinceReferenceDate,
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

/// Pure function of (state, time) → the full panel. Also rendered headlessly
/// by `RAMble --render-widget` for the design critique loop.
public struct EngineBody: View {
    let state: SystemState
    let time: TimeInterval
    var showHint = false

    public init(state: SystemState, time: TimeInterval, showHint: Bool = false) {
        self.state = state
        self.time = time
        self.showHint = showHint
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
        let s = state
        let t = CGFloat(time)
        let stress = CGFloat(s.stress.clamped01)

        // The press: a heavy slab that descends with stress and crushes the
        // room below it. Everything else lives in `room`, which shrinks.
        let pressH: CGFloat = 11
        let pressTravel: CGFloat = 30
        let pressY = 2 + stress * pressTravel
        let rattle: CGFloat = stress > 0.65
            ? sin(t * 47) * (stress - 0.65) * 6 : 0

        var room = CGRect(x: rattle, y: pressY + pressH + 4,
                          width: size.width,
                          height: size.height - pressY - pressH - 6)

        drawPress(&ctx, size: size, y: pressY, h: pressH, stress: stress, t: t)

        // Unit-coordinate helper: everything is placed in room space, so the
        // descending press genuinely compresses the whole diagram.
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: room.minX + x * room.width, y: room.minY + y * room.height,
                   width: w * room.width, height: h * room.height)
        }

        drawReservoir(&ctx, rect(0.02, 0.00, 0.42, 0.60), t: t)
        drawSump(&ctx, rect(0.02, 0.76, 0.42, 0.24),
                 pipeFrom: rect(0.02, 0.00, 0.42, 0.60), t: t)
        drawPistons(&ctx, rect(0.54, 0.00, 0.44, 0.26), t: t)
        drawTurbine(&ctx, rect(0.54, 0.32, 0.44, 0.36), t: t)
        drawPlatter(&ctx, rect(0.58, 0.76, 0.36, 0.24), t: t)
    }

    private func drawPress(_ ctx: inout GraphicsContext, size: CGSize,
                           y: CGFloat, h: CGFloat, stress: CGFloat, t: CGFloat) {
        // Rods from the ceiling.
        let rodColor = Color.white.opacity(0.22)
        for rx in [size.width * 0.25, size.width * 0.75] {
            ctx.fill(Path(CGRect(x: rx - 1.5, y: 0, width: 3, height: y + 2)),
                     with: .color(rodColor))
        }
        // The slab, warming with stress.
        let slab = CGRect(x: 4, y: y, width: size.width - 8, height: h)
        let c = severity(Float(stress))
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

    private func drawReservoir(_ ctx: inout GraphicsContext, _ r: CGRect, t: CGFloat) {
        let s = state
        let pressure = CGFloat(s.memoryPressure.clamped01)
        let wired = CGFloat(s.wiredPercent.clamped01)
        let compressed = CGFloat(s.compressedPercent.clamped01)
        let ram = CGFloat(s.ramPercent.clamped01)
        let liquid = max(ram - wired - compressed, 0)

        // Layers rise from the floor of the vessel.
        let floorY = r.maxY
        let wiredH = wired * r.height
        let compH = compressed * r.height
        let liquidH = liquid * r.height

        // Bedrock (wired): solid.
        ctx.fill(Path(CGRect(x: r.minX, y: floorY - wiredH, width: r.width, height: wiredH)),
                 with: .color(Color(white: 0.45).opacity(0.55)))
        // Sediment (compressed): dense speckle.
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
        // Liquid (app memory): live surface, tinted by pressure.
        let liquidTop = floorY - wiredH - compH - liquidH
        let tint = blend(Color(red: 0.55, green: 0.75, blue: 0.9), severity(Float(pressure)),
                         CGFloat(pressure) * 0.8)
        var surface = Path()
        surface.move(to: CGPoint(x: r.minX, y: floorY - wiredH - compH))
        surface.addLine(to: CGPoint(x: r.minX, y: liquidTop + sin(t * 2.1) * 1.6))
        let steps = 8
        for i in 1...steps {
            let x = r.minX + CGFloat(i) / CGFloat(steps) * r.width
            let y = liquidTop + sin(t * 2.1 + CGFloat(i) * 0.9) * 1.6
            surface.addLine(to: CGPoint(x: x, y: y))
        }
        surface.addLine(to: CGPoint(x: r.maxX, y: floorY - wiredH - compH))
        surface.closeSubpath()
        ctx.fill(surface, with: .color(tint.opacity(0.35)))

        // Pressure bubbles rise through the liquid.
        if pressure > 0.35, liquidH > 8 {
            for i in 0..<4 {
                let u = (t * (0.25 + pressure * 0.5) + CGFloat(i) * 0.27)
                    .truncatingRemainder(dividingBy: 1)
                let bx = r.minX + (0.2 + CGFloat((i * 53) % 60) / 100) * r.width
                let by = (floorY - wiredH - compH) - u * liquidH
                ctx.stroke(Path(ellipseIn: CGRect(x: bx, y: by, width: 3, height: 3)),
                           with: .color(.white.opacity(Double((1 - u) * 0.5))), lineWidth: 0.7)
            }
        }

        // Glass, warming with pressure.
        ctx.stroke(Path(roundedRect: r, cornerRadius: 3),
                   with: .color(blend(Color.white.opacity(0.35),
                                      severity(Float(pressure)), pressure * 0.7)),
                   lineWidth: 1)
        label(&ctx, "RAM", at: CGPoint(x: r.midX, y: r.minY + 7), anchor: .center)
    }

    private func drawSump(_ ctx: inout GraphicsContext, _ r: CGRect,
                          pipeFrom vessel: CGRect, t: CGFloat) {
        let swap = CGFloat(state.swapPercent.clamped01)
        let warning = Color(red: 1.0, green: 0.32, blue: 0.28)

        // Overflow pipe: vessel wall → down into the sump.
        let px = vessel.maxX - 4
        var pipe = Path()
        pipe.move(to: CGPoint(x: px, y: vessel.maxY - 2))
        pipe.addLine(to: CGPoint(x: px, y: r.minY - 2))
        pipe.addLine(to: CGPoint(x: r.midX, y: r.minY - 2))
        ctx.stroke(pipe, with: .color(.white.opacity(0.25)), lineWidth: 2)

        // Drops flow while swap is in play.
        if swap > 0.02 {
            for i in 0..<3 {
                let u = (t * 0.55 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let dy = (vessel.maxY - 2) + u * (r.minY - vessel.maxY + 2)
                ctx.fill(Path(ellipseIn: CGRect(x: px - 1.5, y: dy, width: 3, height: 3.6)),
                         with: .color(warning.opacity(0.85)))
            }
        }

        // The sump itself: the one standing red in the room.
        let level = swap * (r.height - 3)
        ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - level, width: r.width, height: level)),
                 with: .color(warning.opacity(0.30 + swap * 0.45)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 3),
                   with: .color(swap > 0.02 ? warning.opacity(0.5) : .white.opacity(0.30)),
                   lineWidth: 1)
        label(&ctx, "SWAP", at: CGPoint(x: r.midX, y: r.minY - 6), anchor: .center)
    }

    private func drawPistons(_ ctx: inout GraphicsContext, _ r: CGRect, t: CGFloat) {
        let cores = state.perCoreUsage.isEmpty
            ? [Float](repeating: state.cpuPercent, count: 8)
            : state.perCoreUsage
        let n = min(cores.count, 10)
        let gap: CGFloat = 2.5
        let w = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)

        for i in 0..<n {
            let usage = CGFloat(cores[i].clamped01)
            let x = r.minX + CGFloat(i) * (w + gap)
            let cyl = CGRect(x: x, y: r.minY, width: w, height: r.height)
            ctx.stroke(Path(roundedRect: cyl, cornerRadius: 1.5),
                       with: .color(.white.opacity(0.22)), lineWidth: 0.8)
            // The head pumps at the core's true pace; idle cores rest low.
            let speed = 0.6 + usage * 11
            let phase = (sin(t * speed + CGFloat(i) * 1.7) + 1) / 2
            let travel = (r.height - 7) * (0.25 + usage * 0.75)
            let headY = cyl.maxY - 5 - phase * travel
            let c = severity(Float(usage))
            var headCtx = ctx
            if usage > 0.55 { headCtx.addFilter(.shadow(color: c.opacity(0.8), radius: 2.5)) }
            headCtx.fill(Path(roundedRect: CGRect(x: x + 1, y: headY, width: w - 2, height: 4),
                              cornerRadius: 1),
                         with: .color(c.opacity(0.5 + usage * 0.5)))
        }
        label(&ctx, "CPU", at: CGPoint(x: r.midX, y: r.maxY + 6), anchor: .center)
    }

    private func drawTurbine(_ ctx: inout GraphicsContext, _ r: CGRect, t: CGFloat) {
        let gpu = CGFloat(state.gpuPercent.clamped01)
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) * 0.34
        let c = severity(Float(gpu))
        let spin = t * (0.4 + gpu * 7)

        var hub = ctx
        if gpu > 0.4 { hub.addFilter(.shadow(color: c.opacity(0.8), radius: 3 + gpu * 5)) }
        hub.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(.white.opacity(0.3)), lineWidth: 1)
        // Five blades.
        for b in 0..<5 {
            let a = spin + CGFloat(b) / 5 * 2 * .pi
            var blade = Path()
            blade.move(to: center)
            blade.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.9,
                                      y: center.y + sin(a) * radius * 0.9))
            blade.addLine(to: CGPoint(x: center.x + cos(a + 0.5) * radius * 0.55,
                                      y: center.y + sin(a + 0.5) * radius * 0.55))
            blade.closeSubpath()
            hub.fill(blade, with: .color(blend(Color(white: 0.75), c, gpu).opacity(0.25 + gpu * 0.55)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                 with: .color(.white.opacity(0.6)))

        // Token sparks fly off the rim while a model streams.
        if state.inferenceRunning {
            let k = max(Int(min(state.tokensPerSecond / 120, 1) * 6), 2)
            for i in 0..<k {
                let u = (t * 1.3 + CGFloat(i) / CGFloat(k)).truncatingRemainder(dividingBy: 1)
                let a = spin * 0.7 + CGFloat(i) / CGFloat(k) * 2 * .pi
                let d = radius + u * 16
                let p = CGPoint(x: center.x + cos(a) * d, y: center.y + sin(a) * d)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2,
                                                width: 2.4, height: 2.4)),
                         with: .color(Color.cyan.opacity(Double((1 - u) * 0.9))))
            }
        }
        label(&ctx, "GPU", at: CGPoint(x: r.midX, y: r.maxY + 1), anchor: .center)
    }

    private func drawPlatter(_ ctx: inout GraphicsContext, _ r: CGRect, t: CGFloat) {
        let disk = CGFloat(state.diskPressure.clamped01)
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) * 0.36
        let spin = t * (0.3 + disk * 9)

        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(.white.opacity(0.28)), lineWidth: 1)
        for k in 0..<3 {
            let a = spin + CGFloat(k) / 3 * 2 * .pi
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(a) * radius * 0.35,
                                  y: center.y + sin(a) * radius * 0.35))
            tick.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.85,
                                     y: center.y + sin(a) * radius * 0.85))
            ctx.stroke(tick, with: .color(severity(Float(disk))
                        .opacity(0.35 + disk * 0.55)), lineWidth: 1.2)
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

    /// Green → yellow → red, same ramp as the Bars style.
    private func severity(_ v: Float) -> Color {
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
