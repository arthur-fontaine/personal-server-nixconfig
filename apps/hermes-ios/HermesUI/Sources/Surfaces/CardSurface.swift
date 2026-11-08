import SwiftUI

extension View {
    /// Fill, clip and hit-testing from one shape value (design-rules 5.2): there is no way to draw
    /// a fill on one shape and an outline on another, because there is no outline at all.
    func surface<S: Shape>(_ surface: Surface, in shape: S) -> some View {
        background(surface.style, in: shape)
            .clipShape(shape)
            .contentShape(shape)
    }
}

/// A content-layer card (design-rules 5.2, 5.5, 6.1): a system fill tier, no stroke, no shadow,
/// no glass. Its corner is concentric with what it holds: `inset` plus the inner controls'
/// radius, and it publishes itself as the container shape so a `ConcentricRectangle` inside gets
/// `radius − inset` from the system.
public struct CardSurface<Content: View>: View {
    let surface: Surface
    let inset: Spacing
    let innerControlHeight: CGFloat
    let content: Content

    /// A card whose inner controls are `.large` buttons (the approval card's row).
    public init(_ surface: Surface = .grouped, inset: Spacing = .m, @ViewBuilder content: () -> Content) {
        self.init(surface: surface, inset: inset, innerControlHeight: Metric.largeControl, content: content)
    }

    init(surface: Surface, inset: Spacing, innerControlHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.surface = surface
        self.inset = inset
        self.innerControlHeight = innerControlHeight
        self.content = content()
    }

    var radius: CGFloat { Radius.card(inset: inset, innerControlHeight: innerControlHeight) }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .environment(\.containerCornerRadius, radius)
            .environment(\.containerInset, inset.points)
            .inset(.all, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerShape(shape)
            .surface(surface, in: shape)
            .geometryProbe(radius: radius, inset: inset.points)
    }
}

/// UI tests read a surface's declared corner and inset (9.5, concentricity) from its
/// accessibility value; only under `-geometryProbe`, so VoiceOver never hears it.
struct GeometryProbe: ViewModifier {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-geometryProbe")
    let radius: CGFloat
    let inset: CGFloat

    func body(content: Content) -> some View {
        if Self.enabled {
            content.accessibilityElement(children: .contain)
                .accessibilityValue(Text(verbatim: "radius=\(radius);inset=\(inset)"))
        } else {
            content
        }
    }
}

extension View {
    func geometryProbe(radius: CGFloat, inset: CGFloat) -> some View {
        modifier(GeometryProbe(radius: radius, inset: inset))
    }
}
