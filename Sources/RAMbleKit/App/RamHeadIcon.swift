import AppKit

/// The RAMble logo: a minimal white ram's head — rounded face, two thick
/// curled horns — drawn in code so it scales to any size (menu bar, app
/// icon, about panel) without shipping assets.
public enum RamHeadIcon {
    /// Draw the ram head filling a square canvas of `size` points.
    /// Monochrome white; use `menuBarImage` for template (auto-tinting) use.
    public static func image(size: CGFloat, color: NSColor = .white) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        draw(in: NSRect(x: 0, y: 0, width: size, height: size), color: color)
        return image
    }

    /// Template image for the status bar (system tints it for the menu bar).
    public static func menuBarImage() -> NSImage {
        let img = image(size: 18, color: .black)
        img.isTemplate = true
        return img
    }

    /// Core drawing, in a normalized 0…1 square mapped to `rect`.
    public static func draw(in rect: NSRect, color: NSColor) {
        let s = min(rect.width, rect.height)
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        func R(_ v: CGFloat) -> CGFloat { v * s }

        color.setFill()

        // --- Face: narrow rounded wedge — wide brow, tapered muzzle.
        let face = NSBezierPath()
        face.move(to: P(0.500, 0.840))                       // forehead
        face.curve(to: P(0.640, 0.580),                      // right brow → cheek
                   controlPoint1: P(0.600, 0.840), controlPoint2: P(0.640, 0.720))
        face.curve(to: P(0.556, 0.180),                      // right jaw → chin
                   controlPoint1: P(0.640, 0.420), controlPoint2: P(0.610, 0.250))
        face.curve(to: P(0.444, 0.180),                      // rounded chin
                   controlPoint1: P(0.525, 0.130), controlPoint2: P(0.475, 0.130))
        face.curve(to: P(0.360, 0.580),                      // left jaw → cheek
                   controlPoint1: P(0.390, 0.250), controlPoint2: P(0.360, 0.420))
        face.curve(to: P(0.500, 0.840),                      // left brow
                   controlPoint1: P(0.360, 0.720), controlPoint2: P(0.400, 0.840))
        face.close()
        face.fill()

        // --- Horns: tapered spirals curling from the brow, out over the
        // top, down around, and forward under the cheek.
        func horn(mirrored: Bool) -> NSBezierPath {
            let sign: CGFloat = mirrored ? -1 : 1
            let curl = (x: 0.5 + sign * 0.205, y: CGFloat(0.600))
            let steps = 64
            let startDeg: CGFloat = 38           // base hidden behind the cheek
            let sweepDeg: CGFloat = -430         // well past a full turn so
                                                 // the tip spirals inside
            var outer: [NSPoint] = []
            var inner: [NSPoint] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let deg = startDeg + sweepDeg * t
                let rad = deg * .pi / 180
                let rho: CGFloat = 0.160 * (1 - 0.62 * t)    // curl tightens hard
                var w: CGFloat = 0.050 * (1 - 0.85 * t) + 0.006  // tip tapers
                w *= 0.40 + 0.60 * min(1, t * 4)             // base tapers too
                let dir = (x: sign * cos(rad), y: sin(rad))
                outer.append(P(curl.x + dir.x * (rho + w), curl.y + dir.y * (rho + w)))
                inner.append(P(curl.x + dir.x * (rho - w), curl.y + dir.y * (rho - w)))
            }
            let path = NSBezierPath()
            path.move(to: outer[0])
            for p in outer.dropFirst() { path.line(to: p) }
            for p in inner.reversed() { path.line(to: p) }
            path.close()
            return path
        }
        horn(mirrored: false).fill()
        horn(mirrored: true).fill()

        // --- Eyes: cut out of the face so they read at any size.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let eyeR = R(0.036)
        for ex: CGFloat in [0.443, 0.557] {
            NSBezierPath(ovalIn: NSRect(x: P(ex, 0.500).x - eyeR,
                                        y: P(ex, 0.500).y - eyeR,
                                        width: eyeR * 2, height: eyeR * 2)).fill()
        }
        // Nostrils: two small slits at the muzzle.
        let nR = R(0.015)
        for nx: CGFloat in [0.472, 0.528] {
            NSBezierPath(ovalIn: NSRect(x: P(nx, 0.215).x - nR,
                                        y: P(nx, 0.215).y - nR * 1.9,
                                        width: nR * 2, height: nR * 3.8)).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Write PNGs for icon generation (used by scripts/make-app.sh).
    public static func writePNG(size: Int, to url: URL) throws {
        let img = image(size: CGFloat(size))
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RamHeadIcon", code: 1)
        }
        try png.write(to: url)
    }
}
