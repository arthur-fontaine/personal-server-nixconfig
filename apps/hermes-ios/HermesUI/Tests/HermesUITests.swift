@testable import HermesUI
import SwiftUI
import Testing

/// The rules HermesUI encodes, proved on its own values (design-rules 9.3, 9.5, 14.1).
struct PetAccentTests {
    static let pip = RGB(hex: 0xF3A73E)
    static let violet = RGB(hex: 0x7B61FF)
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

    /// Pip's fill is its own amber in dark mode and the nearest passing amber in light; the violet
    /// pet's fill is its own colour in light (its label whichever of black or white reads better).
    @Test func pipAndViolet() {
        let pip = PetAccent(base: Self.pip), violet = PetAccent(base: Self.violet)
        #expect(pip.fills[.dark]!.accent == Self.pip)
        #expect(OKLCH(pip.fills[.light]!.accent).l < OKLCH(Self.pip).l)
        #expect(violet.fills[.light]!.accent == Self.violet)
        let v = violet.fills[.light]!
        #expect(v.accent.contrast(with: v.label) >= v.accent.contrast(with: v.labelIsWhite ? .black : .white))
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
