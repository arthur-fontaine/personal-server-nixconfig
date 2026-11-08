import SwiftUI

/// Dynamic Type text styles only (design-rules 3.1): no size, no weight but the style's own.
public enum TextRole: CaseIterable, Sendable {
    /// `title`: a first-run step's title — Apple's welcome screens set it in bold `.title`.
    case title, body, headline, subheadline, footnote, caption, code

    var font: Font {
        switch self {
        case .title: .title.bold()
        case .body: .body
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        // Monospaced only for code (3.1); `.callout` keeps a code line close to the prose's size.
        case .code: .callout.monospaced()
        }
    }
}

/// Foreground colours: semantic only (design-rules 4.1). `accent` is the pet's tint.
public enum Tone: CaseIterable, Sendable {
    /// `warning`: a status that needs attention soon (system orange, design-rules 4: status colours).
    case primary, secondary, tertiary, accent, destructive, warning

    var style: AnyShapeStyle {
        switch self {
        case .primary: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        case .accent: AnyShapeStyle(AccentTextStyle())
        case .destructive: AnyShapeStyle(.red)
        case .warning: AnyShapeStyle(.orange)
        }
    }
}

/// Content-layer fills, from the system's tiers (design-rules 4.1, 5.2: separation by fill, not
/// strokes).
public enum Surface: CaseIterable, Sendable {
    /// The screen's own background.
    case content
    /// A card or a code block on the content background.
    case grouped
    /// Something on a grouped surface.
    case elevated
    /// A neutral fill (the owner's bubble, as Messages' other-party bubbles).
    case fill

    var style: AnyShapeStyle {
        switch self {
        case .content: AnyShapeStyle(Color(uiColor: .systemBackground))
        case .grouped: AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        case .elevated: AnyShapeStyle(Color(uiColor: .tertiarySystemBackground))
        case .fill: AnyShapeStyle(Color(uiColor: .secondarySystemFill))
        }
    }
}

/// What a button means (HIG Buttons, "Roles").
public enum Emphasis: Sendable {
    /// The most likely choice: prominent, the accent. Never destructive (HIG Buttons).
    case primary
    case secondary
    /// System red, never prominent.
    case destructive
}

public extension View {
    /// A system grouped list (Form, inset-grouped List) in a readable column on wide screens, its
    /// grouped background running edge to edge (as Settings on iPad; design-rules 2.2, 6.3).
    /// A screen on the grouped background, as a list's (the review gallery).
    func groupedBackground() -> some View { background(Color(uiColor: .systemGroupedBackground)) }

    func readableGroupedList() -> some View {
        groupedRows()
            .frame(maxWidth: Metric.readableWidth)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }

    func textRole(_ role: TextRole) -> some View { font(role.font) }

    /// A full-screen page's horizontal margins: the system's.
    func scenePaddingHorizontal() -> some View { scenePadding(.horizontal) }

    /// The live caption under the call's pet: a readable width, a few lines tall.
    func captionArea() -> some View { frame(maxWidth: Metric.readableWidth, maxHeight: Metric.captionHeight) }
    func tone(_ tone: Tone) -> some View { foregroundStyle(tone.style) }

    /// Padding from the scale only.
    func inset(_ edges: Edge.Set = .all, _ spacing: Spacing) -> some View { padding(edges, spacing.points) }
}

public extension Text {
    func textRole(_ role: TextRole) -> Text { font(role.font) }
}

/// A stack whose spacing comes from the scale.
public struct VGroup<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: Spacing
    let content: Content

    public init(alignment: HorizontalAlignment = .leading, spacing: Spacing, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View { VStack(alignment: alignment, spacing: spacing.points) { content } }
}

public struct HGroup<Content: View>: View {
    let alignment: VerticalAlignment
    let spacing: Spacing
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: Spacing, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View { HStack(alignment: alignment, spacing: spacing.points) { content } }
}
