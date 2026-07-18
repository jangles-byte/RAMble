import AppKit

/// The RAMble logo: a white ram's head with curled horns (bundled artwork,
/// `Resources/ram-logo.png` — white on transparent, detail lines cut out).
/// Falls back to a drawn glyph if the resource is ever missing.
public enum RamHeadIcon {
    /// The raw logo artwork (white on transparent).
    public static let artwork: NSImage? = {
        guard let url = Bundle.module.url(forResource: "ram-logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()

    /// Template image for the status bar. Template rendering uses only the
    /// alpha channel, so the cutout eyes/horn details read perfectly in both
    /// light and dark menu bars.
    public static func menuBarImage() -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let img = NSImage(size: size)
        img.lockFocus()
        if let artwork {
            artwork.draw(in: fitRect(artwork.size, into: NSRect(origin: .zero, size: size)),
                         from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            fallbackGlyph(in: NSRect(origin: .zero, size: size), color: .black)
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// The ram on a transparent canvas at an arbitrary square size.
    public static func image(size: CGFloat, color: NSColor = .white) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let artwork {
            artwork.draw(in: fitRect(artwork.size,
                                     into: NSRect(x: 0, y: 0, width: size, height: size)),
                         from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            fallbackGlyph(in: NSRect(x: 0, y: 0, width: size, height: size), color: color)
        }
        img.unlockFocus()
        return img
    }

    /// App-icon tile: the white ram centered on a dark rounded square, so it
    /// reads in Finder, the Dock, and light backgrounds.
    public static func appIconImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        // macOS icon grid: content sits inside ~10% margins.
        let inset = size * 0.05
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = tile.width * 0.225
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGradient(colors: [
            NSColor(deviceRed: 0.13, green: 0.12, blue: 0.24, alpha: 1),
            NSColor(deviceRed: 0.05, green: 0.05, blue: 0.11, alpha: 1),
        ])?.draw(in: path, angle: -90)

        let content = tile.insetBy(dx: tile.width * 0.12, dy: tile.height * 0.12)
        if let artwork {
            artwork.draw(in: fitRect(artwork.size, into: content),
                         from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            fallbackGlyph(in: content, color: .white)
        }
        img.unlockFocus()
        return img
    }

    /// Write an app-icon PNG (used by scripts/make-app.sh via --render-icon).
    public static func writePNG(size: Int, to url: URL) throws {
        let img = appIconImage(size: CGFloat(size))
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RamHeadIcon", code: 1)
        }
        try png.write(to: url)
    }

    // MARK: - Helpers

    /// Aspect-fit `content` inside `box`, centered.
    private static func fitRect(_ content: NSSize, into box: NSRect) -> NSRect {
        guard content.width > 0, content.height > 0 else { return box }
        let scale = min(box.width / content.width, box.height / content.height)
        let w = content.width * scale, h = content.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Minimal drawn stand-in (circle head + horn curls) if the artwork
    /// resource is unavailable — keeps the app functional, never blank.
    private static func fallbackGlyph(in rect: NSRect, color: NSColor) {
        color.setFill()
        let s = min(rect.width, rect.height)
        let head = NSRect(x: rect.midX - s * 0.22, y: rect.minY + s * 0.15,
                          width: s * 0.44, height: s * 0.62)
        NSBezierPath(ovalIn: head).fill()
        for sign: CGFloat in [-1, 1] {
            let horn = NSRect(x: rect.midX + sign * s * 0.36 - s * 0.18,
                              y: rect.minY + s * 0.38, width: s * 0.36, height: s * 0.36)
            NSBezierPath(ovalIn: horn).fill()
        }
    }
}
