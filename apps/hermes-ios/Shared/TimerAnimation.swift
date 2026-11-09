import CoreText
import SwiftUI

// Outside HermesUI on purpose: a mechanism, not styling. Its fonts are images (bitmap glyphs,
// scripts/make-timer-fonts.py), never text, and its numbers are the trick's geometry.

/// A loop a Live Activity plays without the app, one image a second: iOS redraws only timers
/// there, so a single `Text(timerInterval:)` draws its seconds digit in a font whose digits are
/// the images, clipped to that last character.
struct TimerFrames: View {
    let font: String
    let side: CGFloat
    /// A fixed start: every redraw keeps the phase, and the text stays short.
    var start = Calendar.current.startOfDay(for: .now)

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
            .font(.custom(font, fixedSize: side))
            .lineLimit(1)
            // A timer's text takes the whole width offered and starts at its leading edge: the
            // seconds digit must sit at the trailing one, where the clip keeps it.
            .multilineTextAlignment(.trailing)
            .frame(width: side * 12, height: side, alignment: .trailing)
            .frame(width: side, height: side, alignment: .trailing)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// The first image of a timer font, still: plain text, so Always On (which blanks timers) keeps
/// it, at exactly the size the animation has.
struct StillGlyph: View {
    let font: String
    let side: CGFloat

    var body: some View {
        Text(verbatim: "0")
            .font(.custom(font, fixedSize: side))
            .lineLimit(1)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// The activity indicator, about a turn a second without the app: 8 spokes, 8 steps a second.
/// A step shows during its eighth of a second: masked by two timers an eighth apart, one in the
/// even-digit font and one in the odd one, opaque together only in that eighth of every other
/// second; a second pair, parities swapped, covers the other seconds.
struct TimerSpinner: View {
    let side: CGFloat
    static let steps = 8

    var body: some View {
        TimerFonts.registerBundled("HermesMaskEven")
        TimerFonts.registerBundled("HermesMaskOdd")
        let base = Calendar.current.startOfDay(for: .now)
        let slot = 1 / Double(Self.steps)
        return ZStack {
            // Always there, every spoke dim: where two timers flip a frame apart and no step shows
            // for that frame, the spinner dims a moment instead of vanishing.
            Spokes(lit: nil, side: side)
            ForEach(0..<Self.steps, id: \.self) { j in
                let start = base.addingTimeInterval(Double(j) * slot)
                ForEach([("HermesMaskEven", "HermesMaskOdd"), ("HermesMaskOdd", "HermesMaskEven")], id: \.0) { first, second in
                    Spokes(lit: j, side: side)
                        .mask { TimerDigit(font: first, start: start, side: side) }
                        .mask { TimerDigit(font: second, start: start.addingTimeInterval(slot), side: side) }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(Text("In progress"))
    }

    struct Spokes: View {
        /// nil: the base, every spoke at the dimmest.
        let lit: Int?
        let side: CGFloat
        static let dimmest = 0.3

        var body: some View {
            ZStack {
                ForEach(0..<TimerSpinner.steps, id: \.self) { k in
                    // The lit spoke full, the ones behind it fading, as UIActivityIndicatorView;
                    // over the base, a step draws only what's brighter than it.
                    let age = lit.map { Double(($0 - k + TimerSpinner.steps) % TimerSpinner.steps) }
                    let opacity = age.map { max(Self.dimmest, 1 - $0 * 0.15) } ?? Self.dimmest
                    Capsule()
                        .fill(.primary.opacity(lit != nil && opacity <= Self.dimmest ? 0 : opacity))
                        .frame(width: side * 0.14, height: side * 0.3)
                        .offset(y: -side * 0.32)
                        .rotationEffect(.degrees(Double(k) * 360 / Double(TimerSpinner.steps)))
                }
            }
            .frame(width: side, height: side)
        }
    }
}

/// A timer's last character (the seconds digit) filling a square: a mask.
struct TimerDigit: View {
    let font: String
    let start: Date
    let side: CGFloat

    var body: some View {
        TimerFrames(font: font, side: side, start: start)
    }
}

/// A timer's elapsed time, as wide as its text and no wider (a bare timer takes all the width
/// it's offered, squeezing what's beside it).
struct ElapsedTimer: View {
    let since: Date

    var body: some View {
        Text(verbatim: "00:00").monospacedDigit().hidden()
            .overlay(alignment: .trailing) {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .monospacedDigit().multilineTextAlignment(.trailing)
            }
    }
}

enum TimerFonts {
    nonisolated(unsafe) private static var registered: Set<String> = []
    private static let lock = NSLock()

    /// A font of the extension's bundle, by file name; false if it isn't there.
    @discardableResult
    static func registerBundled(_ name: String) -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return false }
        return register(url)
    }

    /// Registers a font file once for this process; false if it can't be.
    @discardableResult
    static func register(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if registered.contains(url.path) { return true }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Already registered by an earlier render of this process.
            || (error?.takeRetainedValue()).map { CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue } == true
        if ok { registered.insert(url.path) }
        return ok
    }
}
