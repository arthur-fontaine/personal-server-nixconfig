import SwiftUI
import WidgetKit

public extension View {
    /// A widget's background: the system's (no tint, no gradient).
    func widgetSystemBackground() -> some View {
        containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    /// The pet at one of its sizes, in a square (its optical centring inside).
    func petSquare(_ size: PetSize) -> some View { frame(width: size.width, height: size.width) }

    /// The pet filling the room its container leaves it (the small widget), square.
    func petFill() -> some View { frame(maxWidth: .infinity, maxHeight: .infinity).aspectRatio(Metric.square, contentMode: .fit) }

    /// An answer button on the lock screen or in the Dynamic Island (App Intent buttons): bordered,
    /// the system red for a refusal (HIG Buttons, roles), the pet's fill otherwise.
    @ViewBuilder func answerButton(destructive: Bool) -> some View {
        if destructive {
            buttonStyle(.bordered).tint(.red)
        } else {
            // The pet's colour as a fill with its black or white label (15.1), as Allow Once in the app.
            foregroundStyle(OnAccentStyle()).buttonStyle(.borderedProminent).accentFillTint()
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

// The review gallery's canvases: the real widget and activity views at the size and in the shape
// the system gives them on a 6.3-inch iPhone (HIG Widgets, "Specifications"; Live Activities).
// A stand-in for the Home and Lock Screens, which a script can't arrange (design-rules 7.2).

public enum IslandPresentation: Sendable { case compact, expanded }

public extension View {
    /// A Home or Lock Screen widget of `family`: its size, the system's corner, the content margins.
    func widgetCanvas(_ family: WidgetFamily) -> some View {
        let size = WidgetCanvas.size(family)
        let accessory = [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        return Group { if accessory { self } else { inset(.all, .m) } }
            .frame(width: size.width, height: size.height)
            .background(accessory ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color(uiColor: .systemBackground)),
                        in: RoundedRectangle(cornerRadius: WidgetCanvas.corner, style: .continuous))
    }

    /// A Live Activity on the Lock Screen: the banner's width and corner, on the system's material.
    func activityCanvas() -> some View {
        frame(width: WidgetCanvas.wide)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WidgetCanvas.corner, style: .continuous))
    }

    /// The Dynamic Island around its content: black, a capsule when compact, its rounded expanded
    /// shape otherwise; dark content as in the Island.
    func islandCanvas(_ presentation: IslandPresentation) -> some View {
        Group {
            switch presentation {
            case .compact:
                frame(width: WidgetCanvas.islandCompact.width, height: WidgetCanvas.islandCompact.height)
                    .background(Color.black, in: Capsule())
            case .expanded:
                inset(.all, .m)
                    .frame(width: WidgetCanvas.wide)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: WidgetCanvas.islandCorner, style: .continuous))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
