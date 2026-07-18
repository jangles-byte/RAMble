import Foundation
import simd

/// A theme drives every visual decision an animation makes: palette, glow
/// strength, particle sizing, and background tinting.
public struct Theme: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String

    /// Ordered palette; plugins index into it for variety (peg colors,
    /// packet colors, orbit bands, …). RGBA, linear space, 0…1.
    public var palette: [SIMD4<Float>]
    /// Color used for calm/healthy states.
    public var calmColor: SIMD4<Float>
    /// Color used for stressed/warning states (swap, backpressure).
    public var warningColor: SIMD4<Float>
    /// Bloom/glow intensity multiplier (0 disables the bloom pass).
    public var glowIntensity: Float
    /// Base particle size multiplier.
    public var particleScale: Float
    /// Trail persistence 0…1 (how slowly the previous frame fades).
    public var trailPersistence: Float
    /// Optional faint background tint (alpha 0 keeps the overlay fully clear).
    public var backgroundTint: SIMD4<Float>

    public func color(_ index: Int) -> SIMD4<Float> {
        palette.isEmpty ? SIMD4(1, 1, 1, 1) : palette[abs(index) % palette.count]
    }

    /// Blend between calm and warning color by a 0…1 stress factor.
    public func stressColor(_ t: Float) -> SIMD4<Float> {
        let t = t.clamped01
        if t <= 0 { return calmColor }
        if t >= 1 { return warningColor }
        return simd_mix(calmColor, warningColor, SIMD4(repeating: t))
    }
}

public enum Themes {
    public static let glass = Theme(
        name: "Glass",
        palette: [SIMD4(0.65, 0.85, 1.0, 0.9), SIMD4(0.8, 0.9, 1.0, 0.8),
                  SIMD4(0.55, 0.75, 0.95, 0.85), SIMD4(0.9, 0.95, 1.0, 0.7)],
        calmColor: SIMD4(0.7, 0.88, 1.0, 0.9),
        warningColor: SIMD4(1.0, 0.55, 0.4, 0.95),
        glowIntensity: 0.9, particleScale: 1.0, trailPersistence: 0.82,
        backgroundTint: SIMD4(0, 0, 0, 0))

    public static let cyberpunk = Theme(
        name: "Cyberpunk",
        palette: [SIMD4(1.0, 0.1, 0.55, 1), SIMD4(0.1, 0.95, 1.0, 1),
                  SIMD4(0.95, 0.85, 0.1, 1), SIMD4(0.6, 0.2, 1.0, 1)],
        calmColor: SIMD4(0.1, 0.95, 1.0, 1),
        warningColor: SIMD4(1.0, 0.15, 0.35, 1),
        glowIntensity: 1.5, particleScale: 1.1, trailPersistence: 0.88,
        backgroundTint: SIMD4(0.02, 0.0, 0.05, 0.15))

    public static let minimal = Theme(
        name: "Minimal",
        palette: [SIMD4(0.85, 0.85, 0.85, 0.8), SIMD4(0.65, 0.65, 0.65, 0.7)],
        calmColor: SIMD4(0.8, 0.8, 0.8, 0.75),
        warningColor: SIMD4(0.95, 0.45, 0.35, 0.9),
        glowIntensity: 0.2, particleScale: 0.8, trailPersistence: 0.6,
        backgroundTint: SIMD4(0, 0, 0, 0))

    public static let synthwave = Theme(
        name: "Synthwave",
        palette: [SIMD4(1.0, 0.25, 0.75, 1), SIMD4(0.35, 0.35, 1.0, 1),
                  SIMD4(0.15, 0.9, 0.95, 1), SIMD4(1.0, 0.6, 0.2, 1)],
        calmColor: SIMD4(0.55, 0.35, 1.0, 1),
        warningColor: SIMD4(1.0, 0.3, 0.4, 1),
        glowIntensity: 1.8, particleScale: 1.15, trailPersistence: 0.9,
        backgroundTint: SIMD4(0.05, 0.0, 0.1, 0.12))

    public static let terminal = Theme(
        name: "Terminal",
        palette: [SIMD4(0.2, 1.0, 0.35, 1), SIMD4(0.1, 0.8, 0.25, 0.9),
                  SIMD4(0.5, 1.0, 0.6, 0.8)],
        calmColor: SIMD4(0.2, 1.0, 0.35, 0.95),
        warningColor: SIMD4(1.0, 0.75, 0.1, 1),
        glowIntensity: 1.1, particleScale: 0.9, trailPersistence: 0.85,
        backgroundTint: SIMD4(0, 0.02, 0, 0.1))

    public static let dark = Theme(
        name: "Dark",
        palette: [SIMD4(0.45, 0.55, 0.85, 0.9), SIMD4(0.35, 0.4, 0.6, 0.85),
                  SIMD4(0.6, 0.65, 0.9, 0.8)],
        calmColor: SIMD4(0.5, 0.6, 0.9, 0.9),
        warningColor: SIMD4(0.9, 0.4, 0.35, 0.95),
        glowIntensity: 0.7, particleScale: 1.0, trailPersistence: 0.8,
        backgroundTint: SIMD4(0, 0, 0, 0.1))

    public static let light = Theme(
        name: "Light",
        palette: [SIMD4(0.25, 0.45, 0.85, 0.85), SIMD4(0.15, 0.6, 0.6, 0.8),
                  SIMD4(0.55, 0.35, 0.75, 0.8)],
        calmColor: SIMD4(0.25, 0.5, 0.85, 0.85),
        warningColor: SIMD4(0.9, 0.35, 0.25, 0.95),
        glowIntensity: 0.4, particleScale: 0.95, trailPersistence: 0.7,
        backgroundTint: SIMD4(1, 1, 1, 0.04))

    public static let all: [Theme] = [glass, cyberpunk, minimal, synthwave, terminal, dark, light]

    public static func named(_ name: String) -> Theme {
        all.first { $0.name == name } ?? glass
    }
}
