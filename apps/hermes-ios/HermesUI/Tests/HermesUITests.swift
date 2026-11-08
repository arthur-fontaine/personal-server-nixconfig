@testable import HermesUI
import ImageIO
import SwiftUI
import Testing

/// The rules HermesUI encodes, proved on its own values (design-rules 9.3, 9.5, 14.1).
struct PetAccentTests {
    static let pip = RGB(hex: 0xF3A73E)
    static let violet = RGB(hex: 0x6B4CE6)
    /// Synthetic extremes: pure primaries, a neon, a near-black navy, a pastel near white, a grey.
    static let extremes: [RGB] = [RGB(hex: 0xFFFF00), RGB(hex: 0x0000FF), RGB(hex: 0xFF0000), RGB(hex: 0x00FF66),
                                  RGB(hex: 0x0A0A40), RGB(hex: 0xFFF0F5), RGB(hex: 0x888899)]
    static let hues: [RGB] = stride(from: 0.0, to: 1.0, by: 1.0 / 12).map { RGB(h: $0, s: 0.8, l: 0.55) }
    static let pets: [RGB] = [pip, violet] + extremes + hues

    static func check(_ pet: RGB, role: PetAccent.Role) -> [String] {
        var issues: [String] = []
        let accent = PetAccent(base: pet)
        let base = OKLCH(pet)
        for a in PetAccent.Appearance.allCases {
            let shade = role == .text ? accent.shades[a]! : accent.fills[a]!
            // Contrast met.
            if PetAccent.passes(shade.accent, role: role, appearance: a) == nil { issues.append("\(a) \(role): \(shade.accent.hex) fails its targets") }
            if role == .fill, shade.accent.contrast(with: shade.label) < 4.5 { issues.append("\(a): label on fill < 4.5") }
            // The pet's own colour when it already passes.
            if PetAccent.passes(pet, role: role, appearance: a) != nil, shade.accent != pet { issues.append("\(a) \(role): moved although the pet passes") }
            // Hue kept (unless the gamut took the chroma).
            let got = OKLCH(shade.accent)
            if base.c > 0.04, got.c > 0.02 {
                let dh = min(abs(got.h - base.h), 360 - abs(got.h - base.h))
                if dh > 2 { issues.append("\(a) \(role): hue moved \(dh)°") }
            }
            // Closest: a lightness 0.005 nearer the pet doesn't pass.
            if shade.accent != pet, base.c > 0.04 {
                let dl = got.l - base.l
                if abs(dl) > 0.006 {
                    let nearer = PetAccent.candidate(base, l: got.l - (dl > 0 ? 0.005 : -0.005))
                    if PetAccent.passes(nearer, role: role, appearance: a) != nil { issues.append("\(a) \(role): a nearer lightness passes") }
                }
            }
        }
        return issues
    }

    @Test(arguments: pets)
    func textShade(_ pet: RGB) { #expect(Self.check(pet, role: .text).isEmpty, "\(pet.hex): \(Self.check(pet, role: .text))") }

    @Test(arguments: pets)
    func fill(_ pet: RGB) { #expect(Self.check(pet, role: .fill).isEmpty, "\(pet.hex): \(Self.check(pet, role: .fill))") }

    /// 15.4: the fill is the pet's own colour (ΔE 0) in every appearance — Pip's amber with a black
    /// label, the violet pet's with a white one.
    @Test func fillsAreThePetsColour() {
        for (pet, white) in [(Self.pip, false), (Self.violet, true)] {
            let accent = PetAccent(base: pet)
            for a in PetAccent.Appearance.allCases {
                let fill = accent.fills[a]!
                #expect(OKLab(fill.accent).distance(to: OKLab(pet)) < 1e-9, "\(pet.hex) \(a): fill \(fill.accent.hex)")
                #expect(fill.labelIsWhite == white, "\(pet.hex) \(a): label")
                #expect(fill.accent.contrast(with: fill.label) >= 4.5)
            }
        }
    }

    /// The violet pet of the review tour (`-petColor 6B4CE6`): Pip recoloured; its dominant colour is
    /// the violet, so its fill is the violet with a white label (15.4).
    @Test func violetPetIsPipRecoloured() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Pet/spritesheet.webp")
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let violet = try #require(PetRecolour.image(src, toHex: "6B4CE6"))
        let dominant = try #require(PetAccent.dominant(in: violet))
        #expect(OKLab(dominant).distance(to: OKLab(Self.violet)) < 0.02, "dominant \(dominant.hex)")
        let fill = PetAccent(sprite: violet).fills[.light]!
        #expect(fill.labelIsWhite)
    }

    @Test func oklabRoundTrips() {
        for c in Self.pets { #expect(OKLab(c).rgb.clamped().contrast(with: c) < 1.01) }
    }
}

@MainActor
struct ActionRowTests {
    func a(_ e: Emphasis) -> Action { Action(id: "\(e)", "x", emphasis: e) {} }

    @Test func refusesADestructivePrimary() {
        #expect(throws: ActionRowError.destructivePrimary) {
            try ActionRow.validate(primary: a(.destructive), others: [], more: [])
        }
    }

    @Test func refusesASecondPrimary() {
        #expect(throws: ActionRowError.secondPrimary) {
            try ActionRow.validate(primary: a(.primary), others: [a(.primary)], more: [])
        }
        #expect(throws: ActionRowError.secondPrimary) {
            try ActionRow.validate(primary: nil, others: [], more: [a(.primary)])
        }
    }

    @Test func refusesANonPrimaryInThePrimarySlot() {
        #expect(throws: ActionRowError.notPrimary) { try ActionRow.validate(primary: a(.secondary), others: [], more: []) }
    }

    @Test func refusesNothing() {
        #expect(throws: ActionRowError.empty) { try ActionRow.validate(primary: nil, others: [], more: []) }
    }

    @Test func acceptsTheApprovalLayout() throws {
        try ActionRow.validate(primary: a(.primary), others: [a(.destructive)], more: [a(.secondary), a(.secondary)])
    }
}

struct TokenTests {
    @Test func spacingIsOnTheFourPointGrid() {
        let values = Spacing.allCases.map(\.points)
        #expect(values == [4, 8, 12, 16, 20, 24, 32])
        for v in values { #expect(v.truncatingRemainder(dividingBy: 4) == 0) }
    }

    @Test func cardsAreConcentricWithTheirControls() {
        for inset in Spacing.allCases {
            for height in [44.0, 52, 60, 88] {
                let r = Radius.card(inset: inset, innerControlHeight: height)
                // Inner radius (a capsule's, half its height) = outer radius − inset.
                #expect(r - inset.points == CGFloat(height) / 2, "inset \(inset) h \(height) r \(r)")
            }
        }
    }

    @Test func composerSendButtonIsConcentricWithTheField() {
        #expect(Radius.composerField - Spacing.xxs.points == Metric.sendButton / 2)
        #expect(Metric.composerControl >= Metric.hitTarget)
    }

    /// The corner is half the one-line height (a capsule), and that height holds a padded line.
    /// The rendered height is checked by GeometryTests (46–48).
    @Test func oneLineBubbleIsACapsule() {
        #expect(Radius.bubble * 2 == Metric.oneLineBubble)
        #expect(Metric.oneLineBubble >= Metric.bodyLine + 2 * Bubble.vertical.points)
    }

    /// 2.4, 12.3: 24 between turns, 8 between the owner's bubbles, 16 between a reply's blocks.
    @Test func rhythm() {
        #expect(TranscriptRow<EmptyView>.gap(.hermes, after: nil) == nil)
        #expect(TranscriptRow<EmptyView>.gap(.hermes, after: .hermes)?.points == 16)
        #expect(TranscriptRow<EmptyView>.gap(.owner, after: .owner)?.points == 8)
        #expect(TranscriptRow<EmptyView>.gap(.owner, after: .hermes)?.points == 24)
        #expect(TranscriptRow<EmptyView>.gap(.hermes, after: .owner)?.points == 24)
    }

    /// 12.1–12.2: surfaces breathe — never below 16 × 10 for the bubble, 16 for code, 20 for the card.
    @Test func chatSurfacesBreathe() {
        #expect(Bubble.horizontal.points >= 16 && Bubble.vertical.points >= 10)
        #expect(Radius.bubble * 2 >= 46 && Radius.bubble * 2 <= 48, "one-line bubble ≈ 46–48 pt")
        #expect(Block.padding.points >= 16)
        #expect(Block.card.points >= 20)
    }
}

struct FileNameBreakTests {
    @Test func breaksAtSeparatorsAndDigitsFirst() {
        let z = "\u{200B}"
        #expect(FileCard.breakableAnywhere("Statements-2025.pdf") == "Statements-\(z)2025.\(z)pdf")
        #expect(FileCard.breakableAnywhere("Saturday.mov") == "Saturday.\(z)mov")
        #expect(FileCard.breakableAnywhere("photoBackup") == "photo\(z)Backup")
        // A segment longer than a line at AX5 may break anywhere.
        #expect(FileCard.breakableAnywhere("Supercalifragilistic.txt").hasPrefix("S\(z)u\(z)p"))
    }
}

/// 14.2: the pet centred optically in its circle.
struct PetCenteringTests {
    /// A transparent `size` image with opaque `rects` (top-left origin).
    static func sprite(_ size: Int, _ rects: [CGRect]) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 1))
        for r in rects { ctx.fill(CGRect(x: r.minX, y: CGFloat(size) - r.maxY, width: r.width, height: r.height)) }
        return ctx.makeImage()!
    }

    /// The box as drawn in a `canvas` with a `circle` (both pt).
    static func drawnBox(_ c: PetCentering, cell: CGFloat, canvas: CGFloat, circle: CGFloat?) -> CGRect {
        let r = c.drawRect(cell: CGSize(width: cell, height: cell), canvas: canvas, circle: circle)
        return CGRect(x: r.minX + c.box.minX * r.width, y: r.minY + c.box.minY * r.height,
                      width: c.box.width * r.width, height: c.box.height * r.height)
    }

    @Test func offCentreBlobIsCentredAndFillsTheInscribedSquare() {
        let c = PetCentering(frames: [Self.sprite(100, [CGRect(x: 10, y: 10, width: 20, height: 20)])])
        #expect(abs(c.box.minX - 0.1) < 1e-9 && abs(c.box.width - 0.2) < 1e-9)
        let b = Self.drawnBox(c, cell: 100, canvas: 36, circle: 36)
        #expect(abs(b.width - 36 / 2.squareRoot()) < 1e-6, "fills the inscribed square: \(b.width)")
        #expect(abs(b.midX - 18) < 1e-6 && abs(b.midY - 18) < 1e-6, "centred: \(b)")
    }

    @Test func unionOfFramesSpansThemAll() {
        let c = PetCentering(frames: [Self.sprite(100, [CGRect(x: 10, y: 40, width: 20, height: 20)]),
                                      Self.sprite(100, [CGRect(x: 70, y: 40, width: 20, height: 20)])])
        #expect(abs(c.box.minX - 0.1) < 1e-9 && abs(c.box.maxX - 0.9) < 1e-9)
    }

    @Test func anchorLeansTowardTheCentroid() {
        // A thin mast on a heavy base: the centroid sits low in the box.
        let c = PetCentering(frames: [Self.sprite(100, [CGRect(x: 48, y: 10, width: 4, height: 60), CGRect(x: 20, y: 70, width: 60, height: 20)])])
        #expect(c.centroid.y > c.box.midY)
        let expected = c.box.midY + (c.centroid.y - c.box.midY) * PetCentering.opticalBias
        #expect(abs(c.anchor.y - expected) < 1e-9)
        #expect(c.anchor.y > c.box.midY && c.anchor.y < c.centroid.y)
        let b = Self.drawnBox(c, cell: 100, canvas: 36, circle: 36)
        #expect(abs(b.midX - 18) < 1e-6, "horizontally centred")
        #expect(b.maxY <= 18 + 36 / 2.squareRoot() / 2 + 1e-6 || b.height <= 36 / 2.squareRoot() + 1e-6)
    }

    /// Pip, from the repository's sprite sheet: every row's first frame (the bar's stills).
    @Test func pipSitsCentredInTheBarCircle() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Pet/spritesheet.webp")
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let sheet = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let cellW = sheet.width / 8, cellH = sheet.height / 9
        let stills = (0..<9).compactMap { sheet.cropping(to: CGRect(x: 0, y: $0 * cellH, width: cellW, height: cellH)) }
        let c = PetCentering(frames: stills)
        let r = c.drawRect(cell: CGSize(width: cellW, height: cellH), canvas: 28, circle: 36)
        let box = CGRect(x: r.minX + c.box.minX * r.width, y: r.minY + c.box.minY * r.height,
                         width: c.box.width * r.width, height: c.box.height * r.height)
        let inscribed = 36 / 2.squareRoot()
        #expect(max(box.width, box.height) <= inscribed + 1e-6, "fits the circle's inscribed square: \(box.size)")
        #expect(abs(box.midX - 14) < 0.25, "horizontally centred: \(box.midX)")
        #expect(abs(box.midY - 14) < inscribed * PetCentering.opticalBias, "vertically centred, give or take the bias: \(box.midY)")
    }
}
