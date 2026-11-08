import SwiftUI

/// A step of a first-run flow, as Apple's own welcome screens (the "Shared with You" sheet in the
/// reference captures): the pet, a bold title, a secondary message, the step's fields; the primary
/// action full width, pinned at the bottom with any secondary ones under it. A readable column on
/// iPad. No decoration: no gradient, no glass on content.
public struct OnboardingPage<Hero: View, Fields: View, Actions: View>: View {
    let title: Text
    let message: Text
    let hero: Hero
    let fields: Fields
    let actions: Actions

    public init(title: Text, message: Text, @ViewBuilder hero: () -> Hero, @ViewBuilder fields: () -> Fields,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.hero = hero()
        self.fields = fields()
        self.actions = actions()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l.points) {
                hero
                VStack(spacing: Spacing.xs.points) {
                    title.textRole(.title).multilineTextAlignment(.center)
                    message.textRole(.body).tone(.secondary).multilineTextAlignment(.center)
                }
                .fixedSize(horizontal: false, vertical: true)
                fields
            }
            .inset(.vertical, .xxl)
            .onboardingColumn()
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            // Its top inset keeps scrolled content ≥ 8 pt off the buttons (design-rules 2.4).
            VStack(spacing: Spacing.s.points) { actions }
                .inset(.top, .s)
                .inset(.bottom, .m)
                .onboardingColumn()
        }
    }
}

extension View {
    /// The onboarding's column: the system margins, at most a readable width for one field.
    func onboardingColumn() -> some View {
        frame(maxWidth: Metric.onboardingWidth)
            .frame(maxWidth: .infinity)
            .scenePadding(.horizontal)
    }
}

public extension View {
    /// A text field of a first-run step: 52 pt, the neutral fill, its corner half of it — as tall
    /// and as round as the large buttons around it.
    func inputField() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        return textRole(.body)
            .inset(.horizontal, .m)
            .frame(minHeight: Metric.fieldHeight)
            .surface(.fill, in: shape)
    }

    /// A small horizontal shake when `trigger` changes (a wrong code); nothing with Reduce Motion.
    func shake<T: Equatable>(on trigger: T) -> some View { modifier(Shake(trigger: trigger)) }
}

struct Shake<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    for (x, t) in ShakeCurve.steps { SpringKeyframe(x, duration: t) }
                }
            }
        }
    }
}

enum ShakeCurve {
    /// Offsets (pt) and durations (s) of the shake: right, left, smaller right, rest.
    static let steps: [(CGFloat, Double)] = [(Spacing.s.points, 0.08), (-Spacing.xs.points, 0.08), (Spacing.xxs.points, 0.08), (0, 0.1)]
}
