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
                title
            }
            .tone(selected ? .accent : .primary)
            .textRole(.body)
            .frame(maxWidth: .infinity, minHeight: Metric.sidebarRow, alignment: .leading)
                .inset(.horizontal, .s)
                .background(selected ? Surface.fill.style : AnyShapeStyle(Color.clear), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
