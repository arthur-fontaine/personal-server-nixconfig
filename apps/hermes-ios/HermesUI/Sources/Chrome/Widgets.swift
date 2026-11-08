import SwiftUI
import WidgetKit

public extension View {
    /// A widget's background: the system's (no tint, no gradient).
    func widgetSystemBackground() -> some View {
        containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    /// The pet at one of its sizes, in a square (its optical centring inside).
    func petSquare(_ size: PetSize) -> some View { frame(width: size.width, height: size.width) }

    /// An answer button on the lock screen or in the Dynamic Island (App Intent buttons): bordered,
    /// the system red for a refusal (HIG Buttons, roles), the pet's fill otherwise.
    @ViewBuilder func answerButton(destructive: Bool) -> some View {
        if destructive {
            buttonStyle(.bordered).tint(.red)
        } else {
            buttonStyle(.bordered).accentFillTint()
        }
    }

    /// Spacing inside a widget or a Live Activity: the system's content margins.
    func widgetInset() -> some View { inset(.all, .m) }
}

/// An answer's label: one line, sharing the row's width.
public struct AnswerLabel: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(verbatim: title).textRole(.caption).fontWeight(.semibold).lineLimit(1).frame(maxWidth: .infinity)
    }
}
