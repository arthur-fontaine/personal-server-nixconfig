import CoreGraphics
import SwiftUI
import UIKit

/// The app's one accent: the pet's colour (design-rules 4.2–4.3, 9.3).
///
/// Read from the sprite (opaque, saturated pixels bucketed by hue; outlines, highlights and greys
/// excluded), then one shade per appearance: the hue kept, the lightness moved until the accent
/// reads at ≥ 4.5:1 against every background it sits on (text) — so ≥ 3:1 for controls too — and
/// its label, black or white, reads at ≥ 4.5:1 on it. With Increase Contrast it is pushed to
/// ≥ 7:1 on the screen's background. Unit-tested on several hues (`PetAccentTests`).
public struct PetAccent: Equatable, Sendable {
    let base: RGB
    let shades: [Appearance: Shade]

    public init(sprite: CGImage) {
        self.init(base: PetAccent.dominant(in: sprite) ?? PetAccent.fallbackBase)
    }

    /// When there's no sprite yet: a neutral blue, checked like any pet's.
    public static let fallback = PetAccent(base: fallbackBase)
    static let fallbackBase = RGB(r: 0.0, g: 0.48, b: 1.0)

    init(base: RGB) {
        self.base = base
        var s: [Appearance: Shade] = [:]
        for a in Appearance.allCases { s[a] = Self.shade(for: base, appearance: a) }
        shades = s
    }

    struct Shade: Equatable, Sendable {
        let accent: RGB
        let labelIsWhite: Bool
        var label: RGB { labelIsWhite ? .white : .black }
    }

    enum Appearance: CaseIterable, Sendable {
        case light, dark, lightHighContrast, darkHighContrast

        var isDark: Bool { self == .dark || self == .darkHighContrast }
        var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }

        /// What the accent is drawn on: systemBackground, secondarySystemBackground (cards, the
        /// approval card's buttons), tertiarySystemBackground and the grouped background.
        var backgrounds: [RGB] {
            switch self {
            case .light: [.white, RGB(hex: 0xF2F2F7)]
            case .lightHighContrast: [.white, RGB(hex: 0xEBEBF0)]
            case .dark: [.black, RGB(hex: 0x1C1C1E), RGB(hex: 0x2C2C2E)]
            case .darkHighContrast: [.black, RGB(hex: 0x242426), RGB(hex: 0x363638)]
            }
        }

        /// 4.5:1 for text on every background; 7:1 on the screen's own with Increase Contrast.
        func required(onBackgroundAt index: Int) -> Double { isHighContrast && index == 0 ? 7 : 4.5 }

        init(_ traits: UITraitCollection) {
            let dark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            self = dark ? (high ? .darkHighContrast : .dark) : (high ? .lightHighContrast : .light)
        }
    }

    static func shade(for c: RGB, appearance: Appearance) -> Shade {
        let (h, s0, l0) = c.hsl
        let s = min(max(s0, 0.45), 0.85)
        var l = l0
        let step = appearance.isDark ? 0.005 : -0.005
        for _ in 0..<400 {
            let a = RGB(h: h, s: s, l: l)
            if let shade = acceptable(a, appearance) { return shade }
            l = min(max(l + step, 0), 1)
        }
        // Black or white always pass; unreachable for any real hue, kept total.
        let a = appearance.isDark ? RGB.white : RGB.black
        return Shade(accent: a, labelIsWhite: !appearance.isDark)
    }

    static func acceptable(_ a: RGB, _ appearance: Appearance) -> Shade? {
        for (i, bg) in appearance.backgrounds.enumerated() where a.contrast(with: bg) < appearance.required(onBackgroundAt: i) {
            return nil
        }
        let white = a.contrast(with: .white), black = a.contrast(with: .black)
        guard max(white, black) >= 4.5 else { return nil }
        return Shade(accent: a, labelIsWhite: white >= black)
    }

    var color: Color { Color(uiColor: UIColor { [shades] t in shades[Appearance(t)]!.accent.uiColor }) }
    var labelColor: Color { Color(uiColor: UIColor { [shades] t in shades[Appearance(t)]!.label.uiColor }) }

    // MARK: Dominant colour

    static func dominant(in image: CGImage) -> RGB? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 200 {
            let c = RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255)
            let (hue, s, l) = c.hsl
            // Outlines, highlights and greys are the drawing, not the character's colour.
            guard s > 0.25, l > 0.15, l < 0.82 else { continue }
            let bin = min(Int(hue * Double(bins)), bins - 1)
            let wgt = s * s
            weight[bin] += wgt
            sum[bin].0 += c.r * wgt; sum[bin].1 += c.g * wgt; sum[bin].2 += c.b * wgt
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return nil }
        // A gradient straddling a bin edge is one colour.
        var t = (0.0, 0.0, 0.0), wt = 0.0
        for d in -1...1 {
            let b = (best + d + bins) % bins
            guard d == 0 || weight[b] > weight[best] * 0.25 else { continue }
            t.0 += sum[b].0; t.1 += sum[b].1; t.2 += sum[b].2; wt += weight[b]
        }
        return RGB(r: t.0 / wt, g: t.1 / wt, b: t.2 / wt)
    }
}

public extension View {
    /// The app's tint and the label colour for what's filled with it.
    func petAccent(_ accent: PetAccent) -> some View {
        tint(accent.color).environment(\.onAccent, accent.labelColor)
    }
}

extension EnvironmentValues {
    @Entry var onAccent: Color = .white
}

/// The label on an accent fill: black or white, whichever the accent was checked against.
struct OnAccentStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.onAccent }
}

// MARK: - Colour maths (WCAG 2.x)

struct RGB: Equatable, Hashable, Sendable {
    var r, g, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: Int) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5)) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h / 6, s, l)
    }

    init(h: Double, s: Double, l: Double) {
        func f(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        if s == 0 { self.init(r: l, g: l, b: l); return }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        self.init(r: f(p, q, h + 1 / 3), g: f(p, q, h), b: f(p, q, h - 1 / 3))
    }
}
