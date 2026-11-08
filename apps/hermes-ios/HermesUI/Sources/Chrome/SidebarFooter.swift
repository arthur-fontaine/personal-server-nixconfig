import SwiftUI

/// Rows pinned at the bottom of a sidebar (design-rules 11.4: Dashboard and Settings at the
/// sidebar's foot, in a `safeAreaBar`): the sidebar's own row metrics (52-pt rows, the list's
/// insets) and its selection (the neutral fill, the accent label), so they read as its rows.
public struct SidebarFooter<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) { content }
            .inset(.horizontal, .m)
            .inset(.bottom, .s)
    }
}

public struct SidebarFooterRow: View {
    let title: Text
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    public init(_ title: Text, systemImage: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        Button(action: action) {
            // The list's own row layout: an icon column, then the label; monochrome, the accent when
            // selected (as the sidebar's rows above).
            HStack(spacing: Spacing.xs.points) {
                // The sidebar's symbol scale (its folder measures ≈ 24 pt wide at the default size).
                Image(systemName: systemImage).imageScale(.large).frame(width: Metric.sidebarIconColumn)
                    .accessibilityHidden(true)
                title
            }
            .tone(.primary)
            .textRole(.body)
            .frame(maxWidth: .infinity, minHeight: Metric.sidebarRow, alignment: .leading)
                .inset(.horizontal, .s)
                // Selected: a light tint of the pet's colour behind primary text (15.2–15.3).
                .background(selected ? AnyShapeStyle(AccentTintStyle()) : AnyShapeStyle(Color.clear), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A sidebar row: the system row's metrics, selected with a light tint of the pet's colour behind
/// primary text (15.2) — not accent text on a grey pill.
public struct SidebarRow<Badge: View>: View {
    let title: Text
    let systemImage: String
    let selected: Bool
    let badge: Badge
    let action: () -> Void

    public init(_ title: Text, systemImage: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder badge: () -> Badge) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.badge = badge()
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        Button(action: action) {
            HStack {
                Label { title } icon: { Image(systemName: systemImage).accessibilityHidden(true) }
                Spacer(minLength: Spacing.xs.points)
                badge
            }
            .tone(.primary)
            // The list's own row height and insets, as the system's sidebar rows.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row's own frame, as the system's selection pill.
        .listRowBackground(selected ? shape.fill(AccentTintStyle()) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An unread count, as the system's list badge.
public struct UnreadBadge: View {
    let count: Text?
    /// A count, not a measure: nil or zero shows nothing.
    public init(_ count: Text?) { self.count = count }
    public var body: some View {
        if let count { count.textRole(.subheadline).tone(.secondary).monospacedDigit() }
    }
}
