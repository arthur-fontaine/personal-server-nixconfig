import SwiftUI

/// What a caress does around the pet (design-rules 11.3): a soft haptic and a tiny heart that
/// rises and fades above it, nothing else — no counter. With Reduce Motion, the haptic alone.
/// `trigger` is the store's `caressedAt`.
public struct CaressFeedback: ViewModifier {
    let trigger: Date?
    let onCaress: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hearts: [Date] = []

    public init(trigger: Date?, onCaress: @escaping () -> Void) {
        self.trigger = trigger
        self.onCaress = onCaress
    }

    public func body(content: Content) -> some View {
        content
            // A stroke across the pet, or a long press: both are a caress.
            .gesture(DragGesture(minimumDistance: Spacing.m.points).onEnded { _ in onCaress() })
            .simultaneousGesture(LongPressGesture(minimumDuration: Caress.pressDuration).onEnded { _ in onCaress() })
            .sensoryFeedback(.impact(flexibility: .soft, intensity: Caress.hapticIntensity), trigger: trigger)
            .overlay(alignment: .top) {
                ZStack {
                    ForEach(hearts, id: \.self) { HeartRise(id: $0) }
                }
            }
            .onChange(of: trigger) { _, t in
                guard let t, !reduceMotion else { return }
                hearts.append(t)
                Task {
                    try? await Task.sleep(for: .seconds(Caress.heartDuration))
                    hearts.removeAll { $0 == t }
                }
            }
            .accessibilityAction(named: Text("Caress"), onCaress)
    }
}

enum Caress {
    static let pressDuration = 0.35
    static let hapticIntensity = 0.6
    static let heartDuration = 1.0
    static let heartStartScale: CGFloat = 0.4
    static let heartFullScale: CGFloat = 1
}

/// One heart: appears small, rises a row and fades.
struct HeartRise: View {
    let id: Date
    @State private var shown = false

    var body: some View {
        Image(systemName: "heart.fill")
            .textRole(.footnote)
            .tone(.accent)
            .scaleEffect(shown ? Caress.heartFullScale : Caress.heartStartScale)
            .offset(y: shown ? -Spacing.xl.points : 0)
            .opacity(shown ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: Caress.heartDuration)) { shown = true } }
            .accessibilityHidden(true)
    }
}

public extension View {
    func caressable(trigger: Date?, onCaress: @escaping () -> Void) -> some View {
        modifier(CaressFeedback(trigger: trigger, onCaress: onCaress))
    }
}
