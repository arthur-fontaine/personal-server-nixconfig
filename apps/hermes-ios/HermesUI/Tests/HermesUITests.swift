@testable import HermesUI
import SwiftUI
import Testing

/// The rules HermesUI encodes, proved on its own values (design-rules 9.3, 9.5).
struct PetAccentTests {
    /// Pets of every hue, saturated and dull, dark and light.
    static let pets: [RGB] = stride(from: 0.0, to: 1.0, by: 1.0 / 24).flatMap { h in
        [RGB(h: h, s: 0.8, l: 0.5), RGB(h: h, s: 0.3, l: 0.75), RGB(h: h, s: 0.9, l: 0.2)]
    } + [RGB(hex: 0xF2A43A) /* Pip's amber */, RGB(hex: 0xFFE500), RGB(hex: 0x00FF66)]

    @Test(arguments: pets)
    func accentReadsOnEveryBackground(_ pet: RGB) {
        let accent = PetAccent(base: pet)
        for appearance in PetAccent.Appearance.allCases {
            let shade = accent.shades[appearance]!
            for (i, bg) in appearance.backgrounds.enumerated() {
                let ratio = shade.accent.contrast(with: bg)
                // Text needs 4.5:1 (7:1 on the screen's background with Increase Contrast); controls
                // need 3:1, so text's bar covers them.
                #expect(ratio >= appearance.required(onBackgroundAt: i),
                        "\(pet.hex) \(appearance): \(shade.accent.hex) on \(bg.hex) = \(ratio)")
                #expect(ratio >= 3)
            }
            #expect(shade.accent.contrast(with: shade.label) >= 4.5, "\(pet.hex) \(appearance): label on accent")
        }
    }

    @Test func keepsThePetsHue() {
        let amber = PetAccent(base: RGB(hex: 0xF2A43A))
        for a in PetAccent.Appearance.allCases {
            let h = amber.shades[a]!.accent.hsl.h
            #expect(abs(h - RGB(hex: 0xF2A43A).hsl.h) < 0.02, "\(a): hue moved to \(h)")
        }
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

    @Test func oneLineBubbleIsACapsule() {
        #expect(Radius.bubble * 2 == Metric.bodyLine + 2 * Bubble.vertical.points)
    }

    @Test func rhythmSeparatesTurnsMoreThanItemsOfATurn() {
        #expect(TranscriptRow<EmptyView>.gap(.hermes, after: nil) == nil)
        #expect(TranscriptRow<EmptyView>.gap(.hermes, after: .hermes) == Rhythm.withinTurn.spacing)
        #expect(TranscriptRow<EmptyView>.gap(.owner, after: .hermes) == Rhythm.turn.spacing)
        #expect(Rhythm.turn.spacing.points > Rhythm.withinTurn.spacing.points)
        #expect(Rhythm.withinTurn.spacing.points >= Spacing.xs.points, "items never touch (design-rules 2.4)")
    }
}
