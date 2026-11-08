import CoreGraphics
import SwiftUI
import UIKit

/// The app's one accent: the pet's colour (design-rules 4.2, 9.3, 14.1, 15).
///
/// Computed in OKLCH from the pet's dominant colour (opaque pixels weighted by area × chroma;
/// outlines, near-black, near-white and greys ignored):
/// - the **fill** (Allow Once, send/stop, toggles, bars, selection) is **the pet's colour as it is**
///   (15.1): its only constraint is its label — black or white, whichever reads better — at
///   ≥ 4.5:1; only if neither does, the lightness moves the least needed (hue and chroma kept).
///   No fill-vs-background ratio: the label and the system shape identify a filled control, as
///   with Apple's own orange and yellow buttons.
/// - the **text** shade is rare (15.2: links in messages): the colour closest to the pet that
///   reads at ≥ 4.5:1 on every background (7:1 on the screen's own with Increase Contrast).
/// `PetAccentTests`: contrast met, hue kept, the pet's own colour whenever it passes, no nearer
/// lightness passing, for Pip, the violet pet and synthetic extremes.
public struct PetAccent: Equatable, Sendable {
    let base: RGB
    let shades: [Appearance: Shade]
    let fills: [Appearance: Shade]

    public init(sprite: CGImage) {
        self.init(base: PetAccent.dominant(in: sprite) ?? PetAccent.fallbackBase)
    }

    /// When there's no sprite yet: a neutral blue, checked like any pet's.
    public static let fallback = PetAccent(base: fallbackBase)
    static let fallbackBase = RGB(r: 0.0, g: 0.48, b: 1.0)

    init(base: RGB) {
        self.base = base
        var s: [Appearance: Shade] = [:], f: [Appearance: Shade] = [:]
        for a in Appearance.allCases {
            s[a] = Self.closest(to: base, role: .text, appearance: a)
            f[a] = Self.closest(to: base, role: .fill, appearance: a)
        }
        shades = s
        fills = f
    }

    struct Shade: Equatable, Sendable {
        let accent: RGB
        let labelIsWhite: Bool
        var label: RGB { labelIsWhite ? .white : .black }
    }

    enum Role: Sendable { case text, fill }

    enum Appearance: CaseIterable, Sendable {
        case light, dark, lightHighContrast, darkHighContrast

        var isDark: Bool { self == .dark || self == .darkHighContrast }
        var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }

        /// What the accent is drawn on: systemBackground, then the grouped and card fills.
        var backgrounds: [RGB] {
            switch self {
            case .light: [.white, RGB(hex: 0xF2F2F7)]
            case .lightHighContrast: [.white, RGB(hex: 0xEBEBF0)]
            case .dark: [.black, RGB(hex: 0x1C1C1E), RGB(hex: 0x2C2C2E)]
            case .darkHighContrast: [.black, RGB(hex: 0x242426), RGB(hex: 0x363638)]
            }
        }

        /// Text: 4.5:1 on every background; 7:1 on the screen's own with Increase Contrast.
        func required(onBackgroundAt index: Int) -> Double { isHighContrast && index == 0 ? 7 : 4.5 }

        init(_ traits: UITraitCollection) {
            let dark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            self = dark ? (high ? .darkHighContrast : .dark) : (high ? .lightHighContrast : .light)
        }
    }

    /// Does `c` meet `role`'s targets in `appearance`? The shade (with its label) if so.
    static func passes(_ c: RGB, role: Role, appearance a: Appearance) -> Shade? {
        let white = c.contrast(with: .white), black = c.contrast(with: .black)
        switch role {
        case .text:
            for (i, bg) in a.backgrounds.enumerated() where c.contrast(with: bg) < a.required(onBackgroundAt: i) { return nil }
            return Shade(accent: c, labelIsWhite: white >= black)
        case .fill:
            guard max(white, black) >= 4.5 else { return nil }
            return Shade(accent: c, labelIsWhite: white > black)
        }
    }

    /// The colour of the pet's hue (chroma kept within gamut) at OKLab lightness `l`.
    static func candidate(_ base: OKLCH, l: Double) -> RGB {
        OKLCH(l: l, c: base.c, h: base.h).inGamut()
    }

    /// The passing colour nearest to `base`: its own colour if it passes; else, of the lightnesses
    /// above and below it, the nearest one where the targets start to hold, found by bisection.
    static func closest(to base: RGB, role: Role, appearance a: Appearance) -> Shade {
        if let ok = passes(base, role: role, appearance: a) { return ok }
        let lch = OKLCH(base)
        var best: (dl: Double, shade: Shade)?
        for direction in [-1.0, 1.0] {
            // Step out to the first passing lightness, then bisect the boundary.
            var outside = lch.l, inside: Double?
            var l = lch.l
            while (direction < 0 ? l > 0 : l < 1) {
                l = min(max(l + direction * 0.01, 0), 1)
                if passes(candidate(lch, l: l), role: role, appearance: a) != nil { inside = l; break }
                outside = l
            }
            guard var hi = inside else { continue }
            var lo = outside
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if passes(candidate(lch, l: mid), role: role, appearance: a) != nil { hi = mid } else { lo = mid }
            }
            let shade = passes(candidate(lch, l: hi), role: role, appearance: a)!
            let dl = abs(hi - lch.l)
            if best == nil || dl < best!.dl { best = (dl, shade) }
        }
        if let best { return best.shade }
        let c: RGB = a.isDark ? .white : .black
        return Shade(accent: c, labelIsWhite: !a.isDark)
    }

    /// A light tint of the pet's colour behind primary text (15.3: selection, the owner's bubble).
    /// In dark mode, the neutral fill instead: a bright colour at 20 % over black turns to mud
    /// (Pip's amber reads #31210C, brown — round 6's U1), as Messages' dark bubbles are neutral.
    var tintColor: Color {
        Color(uiColor: UIColor { [fills] t in
            t.userInterfaceStyle == .dark ? .secondarySystemFill
                : fills[Appearance(t)]!.accent.uiColor.withAlphaComponent(PetAccent.lightTint)
        })
    }
    static let lightTint = 0.2

    /// Accent text (AA on every background).
    var color: Color { Color(uiColor: UIColor { [shades] t in shades[Appearance(t)]!.accent.uiColor }) }
    /// The fill of filled controls, and the label that goes on it.
    var fillColor: Color { Color(uiColor: UIColor { [fills] t in fills[Appearance(t)]!.accent.uiColor }) }
    var fillLabelColor: Color { Color(uiColor: UIColor { [fills] t in fills[Appearance(t)]!.label.uiColor }) }

    // MARK: Dominant colour

    /// Opaque pixels, weighted by chroma (area counts through the number of pixels), bucketed by
    /// OKLCH hue; outlines and near-black (L < 0.3), near-white (L > 0.93), greys (C < 0.04) and
    /// translucent pixels don't vote. The heaviest bucket (with its neighbours when a gradient
    /// straddles the edge) is averaged in OKLab.
    static func dominant(in image: CGImage) -> RGB? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bins = 36
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 230 {
            let lab = OKLab(RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255))
            let lch = OKLCH(lab)
            guard lch.l > 0.3, lch.l < 0.93, lch.c > 0.04 else { continue }
            let bin = min(Int(lch.h / 360 * Double(bins)), bins - 1)
            weight[bin] += lch.c
            sum[bin].0 += lab.l * lch.c; sum[bin].1 += lab.a * lch.c; sum[bin].2 += lab.b * lch.c
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return nil }
        var t = (0.0, 0.0, 0.0), wt = 0.0
        for d in -1...1 {
            let b = (best + d + bins) % bins
            guard d == 0 || weight[b] > weight[best] * 0.25 else { continue }
            t.0 += sum[b].0; t.1 += sum[b].1; t.2 += sum[b].2; wt += weight[b]
        }
        return OKLab(l: t.0 / wt, a: t.1 / wt, b: t.2 / wt).rgb.clamped()
    }
}

// MARK: - OKLab / OKLCH (Björn Ottosson, 2020)

struct OKLab: Equatable, Sendable {
    var l, a, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(_ c: RGB) {
        let r = c.linear(c.r), g = c.linear(c.g), b = c.linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Linear-light sRGB components, possibly out of [0, 1].
    var linearRGB: (Double, Double, Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    var rgb: RGB {
        let (r, g, b) = linearRGB
        return RGB(r: RGB.gamma(r), g: RGB.gamma(g), b: RGB.gamma(b))
    }

    /// Euclidean distance in OKLab (ΔE_OK).
    func distance(to o: OKLab) -> Double { ((l - o.l) * (l - o.l) + (a - o.a) * (a - o.a) + (b - o.b) * (b - o.b)).squareRoot() }
}

struct OKLCH: Equatable, Sendable {
    var l, c, h: Double

    init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = h }
    init(_ lab: OKLab) {
        l = lab.l
        c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let deg = atan2(lab.b, lab.a) * 180 / .pi
        h = deg < 0 ? deg + 360 : deg
    }
    init(_ rgb: RGB) { self.init(OKLab(rgb)) }

    var lab: OKLab { OKLab(l: l, a: c * cos(h * .pi / 180), b: c * sin(h * .pi / 180)) }

    /// This colour, its chroma reduced (by bisection, hue and lightness kept) until it is in sRGB.
    func inGamut() -> RGB {
        func fits(_ c: Double) -> Bool {
            let (r, g, b) = OKLCH(l: l, c: c, h: h).lab.linearRGB
            let e = 1e-6
            return [r, g, b].allSatisfy { $0 >= -e && $0 <= 1 + e }
        }
        if fits(c) { return lab.rgb.clamped() }
        var lo = 0.0, hi = c
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return OKLCH(l: l, c: lo, h: h).lab.rgb.clamped()
    }
}

public extension View {
    /// The app's tint and the label colour for what's filled with it.
    /// The app's tint is the label colour: menus' glyphs, checkmarks, chevrons, the caret stay
    /// monochrome (15.2). The pet's colour goes only where it fills — prominent buttons, switches,
    /// bars, charts — which read it from `accentFill`; links read `accentText`.
    func petAccent(_ accent: PetAccent) -> some View {
        tint(.primary)
            .environment(\.accentFill, accent.fillColor)
            .environment(\.onAccent, accent.fillLabelColor)
            .environment(\.accentText, accent.color)
            .environment(\.accentTint, accent.tintColor)
    }
}

extension EnvironmentValues {
    @Entry var onAccent: Color = .white
    // Outside `petAccent(_:)` (previews, a view shown before the pet loads): the default pet's.
    // Not `.accentColor`: the app's asset is the label colour (15.2).
    @Entry var accentFill: Color = PetAccent.fallback.fillColor
    @Entry var accentText: Color = PetAccent.fallback.color
    @Entry var accentTint: Color = .clear
}

/// The label on an accent fill: black or white, whichever reads at ≥ 4.5:1 on it.
struct OnAccentStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.onAccent }
}

/// The fill of a filled control: the pet's own colour (15.1).
struct AccentFillStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.accentFill }
}

/// Accent text (links): the readable shade of the pet's colour.
struct AccentTextStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.accentText }
}

/// A light tint of the pet's colour behind primary text.
struct AccentTintStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.accentTint }
}

public extension View {
    /// Links inside this text in the readable shade of the pet's colour (15.2).
    func accentLinks() -> some View { modifier(AccentLinks()) }
}

struct AccentLinks: ViewModifier {
    @Environment(\.accentText) private var text
    func body(content: Content) -> some View { content.tint(text) }
}

extension View {
    /// Filled controls in this subtree take the pet's own hue rather than the text shade.
    func accentFillTint() -> some View { modifier(AccentFillTint()) }
}

struct AccentFillTint: ViewModifier {
    @Environment(\.accentFill) private var fill
    func body(content: Content) -> some View { content.tint(fill) }
}

// MARK: - Colour maths (WCAG 2.x)

struct RGB: Equatable, Hashable, Sendable {
    func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }
    func clamped() -> RGB { RGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1)) }

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

/// Demo and tests: another pet from Pip's sprite — its colours moved so the dominant one becomes
/// `hex` ("6B4CE6"). Linear in OKLab (hue turned, lightness and chroma scaled), so the dominant
/// colour moves with them; outlines and whites barely move (low chroma, scaled lightness).
public enum PetRecolour {
    public static func image(_ image: CGImage, toHex hex: String) -> CGImage? {
        guard let target = Int(hex, radix: 16).map(RGB.init(hex:)), let source = PetAccent.dominant(in: image) else { return nil }
        let from = OKLCH(source), to = OKLCH(target)
        let lScale = to.l / from.l, cScale = to.c / from.c, turn = (to.h - from.h) * .pi / 180
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var cache: [UInt32: (UInt8, UInt8, UInt8)] = [:]
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 0 {
            let alpha = Double(data[i + 3]) / 255
            let key = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
            let out = cache[key] ?? {
                let lab = OKLab(RGB(r: Double(data[i]) / 255 / alpha, g: Double(data[i + 1]) / 255 / alpha,
                                    b: Double(data[i + 2]) / 255 / alpha).clamped())
                let a = (lab.a * cos(turn) - lab.b * sin(turn)) * cScale
                let b = (lab.a * sin(turn) + lab.b * cos(turn)) * cScale
                let c = OKLab(l: min(lab.l * lScale, 1), a: a, b: b).rgb.clamped()
                func byte(_ v: Double) -> UInt8 { UInt8(min(max(v * alpha * 255 + 0.5, 0), 255)) }
                let v = (byte(c.r), byte(c.g), byte(c.b))
                cache[key] = v
                return v
            }()
            data[i] = out.0; data[i + 1] = out.1; data[i + 2] = out.2
        }
        return ctx.makeImage()
    }
}
